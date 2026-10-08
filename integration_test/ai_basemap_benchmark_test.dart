// Times the two ways the app can get an AI-sharpened tile, on a real phone:
//   cloud  = precomputed tile from R2 through Cloudflare's CDN
//   device = fetch the NLSC tile and run the TFLite model on the phone
//
// Run in profile mode (debug-mode Dart is far slower at the pixel loops):
//   flutter drive --profile --driver=test_driver/integration_test.dart \
//     --target=integration_test/ai_basemap_benchmark_test.dart -d <device id>
// Each case prints one `SRBENCH {json}` line; the same data lands in
// build/integration_response_data.json.

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:integration_test/integration_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:mower_stdio/services/ai_basemap_service.dart';

/// The site datum (map_datum_fallback in flutter_adapter_node.py); R2 holds
/// the 11x11 z19 tiles around it.
const _site = LatLng(23.6939508, 120.5376539);
const _rrdbModelUrl =
    '${CloudSrLoader.defaultBaseUrl}/models/v1/rrdb_nlsc_x4.tflite';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  final results = <Map<String, Object?>>[];

  void report(String name, Map<String, Object?> data) {
    final row = {'case': name, ...data};
    results.add(row);
    // ignore: avoid_print
    print('SRBENCH ${jsonEncode(row)}');
  }

  double ms(Duration d) => d.inMicroseconds / 1000;

  Map<String, Object?> summarise(List<SrTiming> t, Duration wall) {
    final totals = t.map((e) => ms(e.total)).toList()..sort();
    double avg(double Function(SrTiming) f) =>
        t.isEmpty ? 0 : t.map(f).reduce((a, b) => a + b) / t.length;
    return {
      'tiles': t.length,
      'wall_ms': ms(wall),
      'median_ms': totals.isEmpty ? null : totals[totals.length ~/ 2],
      'min_ms': totals.isEmpty ? null : totals.first,
      'max_ms': totals.isEmpty ? null : totals.last,
      'avg_fetch_ms': avg((e) => ms(e.fetch)),
      'avg_decode_ms': avg((e) => ms(e.decode)),
      'avg_infer_ms': avg((e) => ms(e.infer)),
      'avg_to_image_ms': avg((e) => ms(e.toImage)),
      'avg_kib': avg((e) => e.bytes / 1024),
      'cache': {
        for (final s in t.map((e) => e.cacheStatus).whereType<String>().toSet())
          s: t.where((e) => e.cacheStatus == s).length,
      },
    };
  }

  testWidgets('AI basemap: cloud vs on-device', (tester) async {
    final c = SrTile.containing(_site);
    // 3x3 tiles ~ one phone screen of lawn at z20-21.
    final tiles = [
      for (var dy = -1; dy <= 1; dy++)
        for (var dx = -1; dx <= 1; dx++) SrTile(c.x + dx, c.y + dy),
    ];
    report('device_info', {
      'os': Platform.operatingSystem,
      'os_version': Platform.operatingSystemVersion,
      'cpus': Platform.numberOfProcessors,
    });

    // ---- cloud ----------------------------------------------------------
    Future<void> cloudCase(String name, {bool bust = false, bool parallel = false}) async {
      final client = http.Client();
      final salt = math.Random().nextInt(1 << 30);
      final loader = _BustingCloudLoader(client, bust ? salt : null);
      final sw = Stopwatch()..start();
      final timings = <SrTiming>[];
      if (parallel) {
        final rs = await Future.wait(tiles.map(loader.load));
        for (final r in rs) {
          timings.add(r!.timing);
          r.image.dispose();
        }
      } else {
        for (final t in tiles) {
          final r = (await loader.load(t))!;
          timings.add(r.timing);
          r.image.dispose();
        }
      }
      report(name, summarise(timings, sw.elapsed));
      client.close();
    }

    // Cache-busting query => the CDN misses and R2 itself answers ("cold").
    await cloudCase('cloud_rrdb_cold_sequential', bust: true);
    await cloudCase('cloud_rrdb_warm_sequential');
    await cloudCase('cloud_rrdb_cold_parallel', bust: true, parallel: true);
    await cloudCase('cloud_rrdb_warm_parallel', parallel: true);

    // ---- on device -------------------------------------------------------
    Future<void> deviceCase(
      String name,
      Future<OnDeviceSrLoader> Function() build, {
      int maxTiles = 9,
    }) async {
      final sw = Stopwatch()..start();
      OnDeviceSrLoader loader;
      try {
        loader = await build();
      } catch (e) {
        report(name, {'error': '$e'});
        return;
      }
      final loadMs = ms(sw.elapsed);
      final timings = <SrTiming>[];
      sw.reset();
      try {
        for (final t in tiles.take(maxTiles)) {
          final r = (await loader.load(t))!;
          timings.add(r.timing);
          r.image.dispose();
        }
      } catch (e) {
        report(name, {'error': '$e', 'model_load_ms': loadMs});
        await loader.close();
        return;
      }
      final wall = sw.elapsed;
      await loader.close();
      report(name, {
        'model_load_ms': loadMs,
        // The first inference includes GPU shader compilation / ANE warm-up.
        'first_tile_ms': ms(timings.first.total),
        ...summarise(timings.skip(1).toList(), wall),
      });
    }

    for (final acc in SrAccelerator.values) {
      if (acc == SrAccelerator.coreml && !Platform.isIOS) continue;
      await deviceCase(
        'device_compact_${acc.name}',
        () => OnDeviceSrLoader.fromAsset(
          OnDeviceSrLoader.compactAsset,
          accelerator: acc,
        ),
      );
    }

    final dl = Stopwatch()..start();
    final model = await http.get(Uri.parse(_rrdbModelUrl));
    report('rrdb_model_download', {
      'status': model.statusCode,
      'mib': model.bodyBytes.length / (1 << 20),
      'ms': ms(dl.elapsed),
    });
    if (model.statusCode == 200) {
      for (final acc in [SrAccelerator.gpu, SrAccelerator.coreml, SrAccelerator.cpu]) {
        if (acc == SrAccelerator.coreml && !Platform.isIOS) continue;
        await deviceCase(
          'device_rrdb_${acc.name}',
          () async => OnDeviceSrLoader.fromBuffer(model.bodyBytes, accelerator: acc),
          // The big model on CPU takes tens of seconds per tile.
          maxTiles: acc == SrAccelerator.cpu ? 3 : 9,
        );
      }
    }

    binding.reportData = {'srbench': results};
  }, timeout: const Timeout(Duration(minutes: 45)));
}

/// [CloudSrLoader] with an optional cache-busting query string.
class _BustingCloudLoader extends CloudSrLoader {
  _BustingCloudLoader(http.Client client, this.salt) : super(client: client);

  final int? salt;

  @override
  Uri url(SrTile t) {
    final u = super.url(t);
    return salt == null ? u : u.replace(queryParameters: {'b': '$salt'});
  }
}
