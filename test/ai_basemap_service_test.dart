import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:mower_stdio/services/ai_basemap_service.dart';

/// The site datum (map_datum_fallback in flutter_adapter_node.py).
const _datum = LatLng(23.6939508, 120.5376539);

class _FakeLoader implements SrLoader {
  _FakeLoader(this.result);

  final SrResult? Function() result;
  final calls = <SrTile>[];
  bool closed = false;

  @override
  Future<SrResult?> load(SrTile tile) async {
    calls.add(tile);
    return result();
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  group('SrTile', () {
    test('finds the z19 tile holding the site datum', () {
      // Same index the R2 build script (tools/sr) centres the site on.
      expect(SrTile.containing(_datum), const SrTile(437689, 226609));
    });

    test('bounds contain their own tile and nothing else', () {
      const tile = SrTile(437689, 226609);
      final b = tile.bounds;
      expect(b.contains(_datum), isTrue);
      expect(SrTile.containing(b.center), tile);
      // ~70 m on a side at this latitude.
      final d = const Distance();
      expect(d(b.northWest, b.northEast), closeTo(70, 1));
      expect(d(b.northWest, b.southWest), closeTo(70, 1));
    });

    test('covering lists the area nearest-first and honours the cap', () {
      const c = SrTile(437689, 226609);
      final area = LatLngBounds(
        const SrTile(437688, 226608).bounds.center,
        const SrTile(437690, 226610).bounds.center,
      );
      final tiles = SrTile.covering(area);
      expect(tiles, hasLength(9));
      expect(tiles.first, c);
      expect(SrTile.covering(area, maxTiles: 4), hasLength(4));
    });
  });

  group('CloudSrLoader', () {
    test('uses the versioned R2 layout and treats 404 as "no tile"', () async {
      final seen = <Uri>[];
      final loader = CloudSrLoader(
        client: MockClient((req) async {
          seen.add(req.url);
          return http.Response('', 404);
        }),
      );
      expect(await loader.load(const SrTile(437689, 226609)), isNull);
      expect(
        seen.single.toString(),
        'https://sr.mower.fxrbindi.com/v1/rrdb/19/437689/226609.webp',
      );
    });

    test('throws on server errors so the caller can fall back', () async {
      final loader = CloudSrLoader(
        client: MockClient((_) async => http.Response('', 503)),
      );
      expect(
        loader.load(const SrTile(1, 2)),
        throwsA(isA<http.ClientException>()),
      );
    });
  });

  group('AiBaseMapService', () {
    testWidgets('uses the cloud tile and never builds the on-device model',
        (tester) async {
      final image = await tester.runAsync(() => createTestImage());
      final cloud = _FakeLoader(() => SrResult(image!, SrTiming('cloud')));
      var deviceBuilt = false;
      final service = AiBaseMapService(
        cloud: cloud,
        device: () async {
          deviceBuilt = true;
          return _FakeLoader(() => null);
        },
      );
      final r = await service.load(const SrTile(1, 2));
      expect(r?.timing.source, 'cloud');
      expect(deviceBuilt, isFalse);
    });

    test('falls back to the phone when the cloud has no tile or fails',
        () async {
      final device = _FakeLoader(() => null);
      var builds = 0;
      final missing = AiBaseMapService(
        cloud: _FakeLoader(() => null),
        device: () async {
          builds++;
          return device;
        },
      );
      await missing.load(const SrTile(1, 2));
      await missing.load(const SrTile(3, 4));
      expect(device.calls, const [SrTile(1, 2), SrTile(3, 4)]);
      expect(builds, 1, reason: 'the interpreter is built once');

      final failing = AiBaseMapService(
        cloud: _FakeLoader(() => throw http.ClientException('offline')),
        device: () async => device,
      );
      await failing.load(const SrTile(5, 6));
      expect(device.calls.last, const SrTile(5, 6));

      await missing.close();
      expect(device.closed, isTrue);
    });
  });
}
