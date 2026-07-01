import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/geo_anchor.dart';
import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import 'breathing_marker.dart';

/// Satellite base-map view: Mapbox satellite tiles with the mission overlays
/// (freespace / risk / channel grids, zones, coverage path, robot) projected
/// from the local map frame onto real-world lat/lon via [GeoAnchor]. The
/// alternative to the schematic [MissionMapCanvas] when satellite mode is on.
class SatelliteMapView extends StatelessWidget {
  const SatelliteMapView({
    super.key,
    required this.mission,
    required this.anchor,
  });

  final MissionMockProvider mission;
  final GeoAnchor anchor;

  /// Provided at run time via `--dart-define-from-file=.env` (MAPBOX_TOKEN).
  static const String _mapboxToken = String.fromEnvironment('MAPBOX_TOKEN');

  LatLng _ll(MapPoint p) => anchor.worldToLatLng(p.x, p.y);

  /// Bounded viewing area (so the satellite view can't pan off to arbitrary
  /// places on Earth): the map content extent — freespace grid + zones + robot
  /// — squared, expanded by a margin, with a sensible minimum size.
  LatLngBounds _contentBounds() {
    double? minX, minY, maxX, maxY;
    void add(double x, double y) {
      minX = (minX == null || x < minX!) ? x : minX;
      maxX = (maxX == null || x > maxX!) ? x : maxX;
      minY = (minY == null || y < minY!) ? y : minY;
      maxY = (maxY == null || y > maxY!) ? y : maxY;
    }

    final fs = mission.freeSpaceLayer;
    if (fs != null) {
      add(fs.originX, fs.originY);
      add(fs.originX + fs.width * fs.resolution,
          fs.originY + fs.height * fs.resolution);
    }
    for (final z in mission.zones) {
      for (final p in z.points) {
        add(p.x, p.y);
      }
    }
    add(mission.robotPosition.x, mission.robotPosition.y);

    final cx = (minX! + maxX!) / 2;
    final cy = (minY! + maxY!) / 2;
    // Square half-extent: at least 10 m, plus a 20% + 2 m margin.
    final half = math.max(
              math.max((maxX! - minX!) / 2, (maxY! - minY!) / 2),
              10.0,
            ) *
            1.2 +
        2.0;
    return LatLngBounds.fromPoints([
      anchor.worldToLatLng(cx - half, cy - half),
      anchor.worldToLatLng(cx + half, cy - half),
      anchor.worldToLatLng(cx - half, cy + half),
      anchor.worldToLatLng(cx + half, cy + half),
    ]);
  }

  /// A raster grid layer placed by its world-frame corners (image top-left =
  /// (originX, originY), matching the schematic canvas' drawImageRect).
  RotatedOverlayImage? _gridOverlay(MapGridLayer? layer, double opacity) {
    if (layer == null) {
      return null;
    }
    final worldW = layer.width * layer.resolution;
    final worldH = layer.height * layer.resolution;
    return RotatedOverlayImage(
      imageProvider: _UiImageProvider(layer.image),
      topLeftCorner: anchor.worldToLatLng(layer.originX, layer.originY),
      bottomLeftCorner: anchor.worldToLatLng(layer.originX, layer.originY + worldH),
      bottomRightCorner:
          anchor.worldToLatLng(layer.originX + worldW, layer.originY + worldH),
      opacity: opacity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final gridOverlays = <RotatedOverlayImage?>[
      // Drawn bottom→top: freespace, then channel, then risk on top.
      _gridOverlay(mission.freeSpaceLayer, 0.55),
      _gridOverlay(mission.channelMapLayer, 0.6),
      _gridOverlay(mission.riskMapLayer, 0.6),
    ].whereType<RotatedOverlayImage>().toList();

    final coveragePolylines = <Polyline>[
      for (final row in mission.coverageRows)
        if (row.length >= 2)
          Polyline(
            points: row.map(_ll).toList(),
            strokeWidth: 2.5,
            color: const Color(0xFF2EC86E),
          ),
    ];

    final zonePolygons = <Polygon>[
      for (final z in mission.zones)
        if (z.points.length >= 3)
          Polygon(
            points: z.points.map(_ll).toList(),
            color: const Color(0x332DA653),
            borderColor: const Color(0xFF2DA653),
            borderStrokeWidth: 2,
          ),
    ];

    final bounds = _contentBounds();

    return Stack(
      children: [
        FlutterMap(
          options: MapOptions(
            // Open framed on the content; keep the map CENTRE locked to it (so
            // you can't pan away to arbitrary places), but allow zooming out to
            // see the surroundings (z16–z22, ~6 levels).
            initialCameraFit: CameraFit.bounds(
              bounds: bounds,
              padding: const EdgeInsets.all(24),
            ),
            cameraConstraint: CameraConstraint.containCenter(bounds: bounds),
            minZoom: 16,
            maxZoom: 22,
            // Enable all gestures incl. mouse-wheel / trackpad zoom (works in
            // the desktop-run iOS sim); rotation off to keep north up.
            interactionOptions: const InteractionOptions(
              flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
            ),
          ),
          children: [
            if (_mapboxToken.isNotEmpty)
              TileLayer(
                urlTemplate:
                    'https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg90'
                    '?access_token=$_mapboxToken',
                userAgentPackageName: 'com.example.mower_stdio',
                maxNativeZoom: 22,
              ),
            if (gridOverlays.isNotEmpty)
              OverlayImageLayer(overlayImages: gridOverlays),
            if (zonePolygons.isNotEmpty) PolygonLayer(polygons: zonePolygons),
            if (coveragePolylines.isNotEmpty)
              PolylineLayer(polylines: coveragePolylines),
            MarkerLayer(
              markers: [
                Marker(
                  point: _ll(mission.robotPosition),
                  width: 40,
                  height: 40,
                  child: const BreathingMarker(),
                ),
              ],
            ),
            const RichAttributionWidget(
              attributions: [TextSourceAttribution('© Mapbox © Maxar')],
            ),
          ],
        ),
        if (_mapboxToken.isEmpty)
          const Positioned(
            left: 16,
            right: 16,
            top: 16,
            child: _NoTokenBanner(),
          ),
      ],
    );
  }
}

/// Wraps a decoded [ui.Image] as an [ImageProvider] with no PNG encode/decode
/// round-trip, so the pre-rendered grid images can feed flutter_map's
/// [OverlayImageLayer] directly. Keyed by image identity so the layer is only
/// re-uploaded when the underlying grid changes.
class _UiImageProvider extends ImageProvider<_UiImageProvider> {
  const _UiImageProvider(this.image);

  final ui.Image image;

  @override
  Future<_UiImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_UiImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _UiImageProvider key,
    ImageDecoderCallback decode,
  ) {
    return OneFrameImageStreamCompleter(
      Future<ImageInfo>.value(ImageInfo(image: image.clone(), scale: 1.0)),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is _UiImageProvider && other.image == image;

  @override
  int get hashCode => image.hashCode;
}

class _NoTokenBanner extends StatelessWidget {
  const _NoTokenBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Text(
        '缺少 Mapbox token：請用 flutter run --dart-define-from-file=.env 啟動',
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
      ),
    );
  }
}
