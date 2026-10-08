import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_map/flutter_map.dart' show LatLngBounds;
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// AI-sharpened aerial base map: NLSC z19 tiles (~27 cm/px) upscaled x4 by a
/// super-resolution model fine-tuned on NLSC imagery around the site
/// (tools/sr/). Display only: the extra detail is model output, not survey
/// data, so mow boundaries must not be traced from it.
///
/// A tile comes either from [CloudSrLoader] (precomputed in R2, served through
/// Cloudflare's CDN) or from [OnDeviceSrLoader] (fetch the NLSC tile and run
/// the TFLite model on the phone). integration_test/ai_basemap_benchmark_test
/// times the two against each other.

/// One NLSC z19 tile, ~70 m square in Taiwan: the unit both loaders work on.
@immutable
class SrTile {
  const SrTile(this.x, this.y);

  static const int zoom = 19;
  static const int sourcePx = 256;
  static const int scale = 4;
  static const int outputPx = sourcePx * scale;

  final int x;
  final int y;

  static SrTile containing(LatLng p) {
    final n = 1 << zoom;
    final latRad = p.latitude * math.pi / 180;
    final x = ((p.longitude + 180) / 360 * n).floor();
    final y =
        ((1 - math.log(math.tan(latRad) + 1 / math.cos(latRad)) / math.pi) /
                2 *
                n)
            .floor();
    return SrTile(x, y);
  }

  /// The tiles overlapping [bounds], nearest to its centre first, capped at
  /// [maxTiles] so a zoomed-out site can't queue hundreds of inferences.
  static List<SrTile> covering(LatLngBounds bounds, {int maxTiles = 25}) {
    final nw = containing(bounds.northWest);
    final se = containing(bounds.southEast);
    final c = containing(bounds.center);
    final tiles = [
      for (var y = nw.y; y <= se.y; y++)
        for (var x = nw.x; x <= se.x; x++) SrTile(x, y),
    ];
    int d(SrTile t) => (t.x - c.x) * (t.x - c.x) + (t.y - c.y) * (t.y - c.y);
    tiles.sort((a, b) => d(a).compareTo(d(b)));
    return tiles.take(maxTiles).toList();
  }

  LatLngBounds get bounds =>
      LatLngBounds(_corner(x, y), _corner(x + 1, y + 1));

  static LatLng _corner(int x, int y) {
    final n = 1 << zoom;
    final t = math.pi * (1 - 2 * y / n);
    final lat = math.atan((math.exp(t) - math.exp(-t)) / 2) * 180 / math.pi;
    return LatLng(lat, x / n * 360 - 180);
  }

  @override
  bool operator ==(Object other) =>
      other is SrTile && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'SrTile($zoom/$x/$y)';
}

/// Where the time for one tile went.
class SrTiming {
  SrTiming(this.source);

  /// `cloud` or `device`.
  final String source;

  /// Network: the AI tile (cloud) or the NLSC source tile (device).
  Duration fetch = Duration.zero;

  /// Image decode (plus the RGBA read-back the model needs, on device).
  Duration decode = Duration.zero;

  /// Model pre-process + inference + post-process (device only).
  Duration infer = Duration.zero;

  /// Handing the model's pixels to the engine as a ui.Image (device only).
  Duration toImage = Duration.zero;

  int bytes = 0;

  /// Cloudflare's cf-cache-status (HIT / MISS) for cloud tiles.
  String? cacheStatus;

  Duration get total => fetch + decode + infer + toImage;

  Map<String, Object?> toJson() => {
    'source': source,
    'fetch_ms': fetch.inMicroseconds / 1000,
    'decode_ms': decode.inMicroseconds / 1000,
    'infer_ms': infer.inMicroseconds / 1000,
    'to_image_ms': toImage.inMicroseconds / 1000,
    'total_ms': total.inMicroseconds / 1000,
    'bytes': bytes,
    if (cacheStatus != null) 'cache': cacheStatus,
  };
}

class SrResult {
  SrResult(this.image, this.timing);

  final ui.Image image;
  final SrTiming timing;
}

abstract class SrLoader {
  /// The enhanced tile, or null when this loader has none for [tile].
  Future<SrResult?> load(SrTile tile);

  Future<void> close();
}

/// Precomputed tiles from the `mower-sr-tiles` R2 bucket.
class CloudSrLoader implements SrLoader {
  CloudSrLoader({
    http.Client? client,
    this.model = 'rrdb',
    this.baseUrl = defaultBaseUrl,
  }) : _client = client ?? http.Client();

  static const String defaultBaseUrl = 'https://sr.mower.fxrbindi.com';

  /// Model key in the bucket layout (`v1/<model>/19/<x>/<y>.webp`).
  final String model;
  final String baseUrl;
  final http.Client _client;

  Uri url(SrTile t) =>
      Uri.parse('$baseUrl/v1/$model/${SrTile.zoom}/${t.x}/${t.y}.webp');

  @override
  Future<SrResult?> load(SrTile tile) async {
    final timing = SrTiming('cloud');
    final sw = Stopwatch()..start();
    final res = await _client.get(url(tile));
    timing.fetch = sw.elapsed;
    if (res.statusCode == 404) return null;
    if (res.statusCode != 200) {
      throw http.ClientException('AI tile HTTP ${res.statusCode}', url(tile));
    }
    timing.bytes = res.bodyBytes.length;
    timing.cacheStatus = res.headers['cf-cache-status'];
    sw.reset();
    final image = await _decode(res.bodyBytes);
    timing.decode = sw.elapsed;
    return SrResult(image, timing);
  }

  @override
  Future<void> close() async => _client.close();
}

enum SrAccelerator { cpu, gpu, coreml }

/// Runs the x4 TFLite model on the phone. Calls are serialised (one
/// interpreter); inference runs on a background isolate so the map keeps
/// rendering.
class OnDeviceSrLoader implements SrLoader {
  OnDeviceSrLoader._(
    this._interpreter,
    this._delegate,
    this._planar,
    this.accelerator,
    this._client,
  );

  /// The compact model (SRVGGNetCompact, ~1.2 M params) bundled with the app.
  static const String compactAsset = 'assets/models/sr_compact_nlsc_x4.tflite';

  static const String nlscTileUrl =
      'https://wmts.nlsc.gov.tw/wmts/PHOTO2/default/GoogleMapsCompatible';

  final Interpreter _interpreter;
  final Delegate? _delegate;

  /// Output is [1,3,H,W] (onnx2tf keeps PixelShuffle models planar) rather
  /// than [1,H,W,3].
  final bool _planar;
  final SrAccelerator accelerator;
  final http.Client _client;
  Future<void> _queue = Future.value();

  static Future<OnDeviceSrLoader> fromAsset(
    String asset, {
    SrAccelerator accelerator = SrAccelerator.gpu,
    http.Client? client,
  }) async {
    final data = await rootBundle.load(asset);
    return fromBuffer(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      accelerator: accelerator,
      client: client,
    );
  }

  static OnDeviceSrLoader fromBuffer(
    Uint8List model, {
    SrAccelerator accelerator = SrAccelerator.gpu,
    http.Client? client,
  }) {
    final options = InterpreterOptions();
    Delegate? delegate;
    switch (accelerator) {
      case SrAccelerator.cpu:
        options.threads = math.min(4, Platform.numberOfProcessors);
      case SrAccelerator.gpu:
        delegate = Platform.isIOS
            ? GpuDelegate(options: GpuDelegateOptions(allowPrecisionLoss: true))
            : GpuDelegateV2(
                options: GpuDelegateOptionsV2(isPrecisionLossAllowed: true),
              );
      case SrAccelerator.coreml:
        delegate = CoreMlDelegate();
    }
    if (delegate != null) options.addDelegate(delegate);
    final interpreter = Interpreter.fromBuffer(model, options: options);
    interpreter.allocateTensors();
    final inShape = interpreter.getInputTensor(0).shape.join(',');
    final outShape = interpreter.getOutputTensor(0).shape.join(',');
    const s = SrTile.sourcePx, o = SrTile.outputPx;
    final ok =
        inShape == '1,$s,$s,3' &&
        (outShape == '1,$o,$o,3' || outShape == '1,3,$o,$o');
    if (!ok) {
      interpreter.close();
      delegate?.delete();
      throw StateError(
        'SR model shape [$inShape] -> [$outShape], want [1,$s,$s,3] -> [1,$o,$o,3]',
      );
    }
    return OnDeviceSrLoader._(
      interpreter,
      delegate,
      outShape == '1,3,$o,$o',
      accelerator,
      client ?? http.Client(),
    );
  }

  Uri nlscUrl(SrTile t) => Uri.parse('$nlscTileUrl/${SrTile.zoom}/${t.y}/${t.x}');

  @override
  Future<SrResult?> load(SrTile tile) {
    final run = _queue.then((_) => _load(tile));
    _queue = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<SrResult?> _load(SrTile tile) async {
    final timing = SrTiming('device');
    final sw = Stopwatch()..start();
    final res = await _client.get(nlscUrl(tile));
    timing.fetch = sw.elapsed;
    if (res.statusCode != 200) return null;
    timing.bytes = res.bodyBytes.length;

    sw.reset();
    final src = await _decode(res.bodyBytes);
    final data = await src.toByteData(format: ui.ImageByteFormat.rawRgba);
    final w = src.width;
    src.dispose();
    timing.decode = sw.elapsed;
    if (data == null || w != SrTile.sourcePx) return null;

    sw.reset();
    final pixels = await _inferInIsolate(
      _interpreter.address,
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      _planar,
    );
    timing.infer = sw.elapsed;

    sw.reset();
    final completer = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      SrTile.outputPx,
      SrTile.outputPx,
      ui.PixelFormat.rgba8888,
      completer.complete,
    );
    final image = await completer.future;
    timing.toImage = sw.elapsed;
    return SrResult(image, timing);
  }

  // Static so the isolate closure captures only these values.
  static Future<Uint8List> _inferInIsolate(
    int address,
    Uint8List rgba,
    bool planar,
  ) => Isolate.run(() => _infer(address, rgba, planar));

  @override
  Future<void> close() async {
    await _queue;
    _interpreter.close();
    _delegate?.delete();
    _client.close();
  }
}

/// RGBA source tile -> model -> RGBA output, all on the calling isolate.
Uint8List _infer(int address, Uint8List rgba, bool planar) {
  final interpreter = Interpreter.fromAddress(address, allocated: true);
  final input = Float32List(SrTile.sourcePx * SrTile.sourcePx * 3);
  for (var i = 0, j = 0; i < rgba.length; i += 4) {
    input[j++] = rgba[i] / 255;
    input[j++] = rgba[i + 1] / 255;
    input[j++] = rgba[i + 2] / 255;
  }
  interpreter.getInputTensor(0).data = input.buffer.asUint8List();
  interpreter.invoke();
  final raw = interpreter.getOutputTensor(0).data;
  final out = raw.buffer.asFloat32List(raw.offsetInBytes, raw.lengthInBytes ~/ 4);
  const n = SrTile.outputPx * SrTile.outputPx;
  final px = Uint8List(n * 4);
  // Not clamped in-graph (see tools/sr/export_tflite.py), so clamp here.
  int u8(double v) => v <= 0 ? 0 : (v >= 1 ? 255 : (v * 255 + 0.5).toInt());
  if (planar) {
    for (var p = 0, i = 0; p < n; p++, i += 4) {
      px[i] = u8(out[p]);
      px[i + 1] = u8(out[n + p]);
      px[i + 2] = u8(out[2 * n + p]);
      px[i + 3] = 255;
    }
  } else {
    for (var i = 0, j = 0; j < out.length; i += 4, j += 3) {
      px[i] = u8(out[j]);
      px[i + 1] = u8(out[j + 1]);
      px[i + 2] = u8(out[j + 2]);
      px[i + 3] = 255;
    }
  }
  return px;
}

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

/// What the map uses: the cloud tile when R2 has it, otherwise the bundled
/// compact model on the phone (outside the precomputed area, or offline from
/// R2 while NLSC is reachable).
class AiBaseMapService {
  AiBaseMapService({
    SrLoader? cloud,
    Future<SrLoader> Function()? device,
  }) : _cloud = cloud ?? CloudSrLoader(),
       _deviceFactory =
           device ?? (() => OnDeviceSrLoader.fromAsset(OnDeviceSrLoader.compactAsset));

  final SrLoader _cloud;
  final Future<SrLoader> Function() _deviceFactory;
  Future<SrLoader>? _device;

  Future<SrResult?> load(SrTile tile) async {
    try {
      final cloud = await _cloud.load(tile);
      if (cloud != null) return cloud;
    } on Exception {
      // Fall through to the phone.
    }
    final device = await (_device ??= _deviceFactory());
    return device.load(tile);
  }

  Future<void> close() async {
    await _cloud.close();
    final device = _device;
    if (device != null) await (await device).close();
  }
}
