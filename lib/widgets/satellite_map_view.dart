import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show SynchronousFuture, setEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../models/geo_anchor.dart';
import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../services/ai_basemap_service.dart';
import 'breathing_marker.dart';

/// Satellite base-map view: NLSC aerial orthophoto tiles with the mission overlays
/// (freespace / risk / channel grids, zones, coverage path, robot) projected
/// from the local map frame onto real-world lat/lon via [GeoAnchor]. The
/// alternative to the schematic [MissionMapCanvas] when satellite mode is on.
class SatelliteMapView extends StatefulWidget {
  const SatelliteMapView({
    super.key,
    required this.mission,
    required this.anchor,
    this.phonePosition,
    this.phoneAccuracyM,
    this.followRobot = false,
    this.onFollowRobotChanged,
    this.aiEnhance = false,
    this.aiService,
  });

  final MissionMockProvider mission;
  final GeoAnchor anchor;

  /// The phone's own GPS fix (blue dot), when location display is on.
  final LatLng? phonePosition;
  final double? phoneAccuracyM;

  /// Keep the camera centred on the robot as it moves. Zoom gestures keep
  /// following; a one-finger drag reports `false` to [onFollowRobotChanged].
  final bool followRobot;
  final ValueChanged<bool>? onFollowRobotChanged;

  /// Overlay the content area with AI-sharpened (x4) tiles.
  final bool aiEnhance;

  /// Injected for tests; by default one is created on first use.
  final AiBaseMapService? aiService;

  /// NLSC (內政部國土測繪中心) PHOTO2 orthophoto: free under the Open
  /// Government Data License (attribution required), no token, Taiwan only.
  /// Note the {y}/{x} order.
  static const String nlscTileUrl =
      'https://wmts.nlsc.gov.tw/wmts/PHOTO2/default/GoogleMapsCompatible/{z}/{y}/{x}';

  /// The imagery is ~27 cm/px, i.e. native up to z19. Deeper zooms scale the
  /// z19 tiles up instead of fetching server-upscaled tiles with no extra
  /// detail.
  static const int nlscMaxNativeZoom = 19;

  @override
  State<SatelliteMapView> createState() => _SatelliteMapViewState();
}

class _SatelliteMapViewState extends State<SatelliteMapView> {
  final _mapController = MapController();

  /// A pinch or double-tap zoom is running; recentring now would fight it.
  bool _zooming = false;
  bool _recentreScheduled = false;

  AiBaseMapService? _ownAi;
  AiBaseMapService get _ai =>
      widget.aiService ?? (_ownAi ??= AiBaseMapService());

  /// AI tiles for the current content area, the ones still loading, and the
  /// area they were computed for.
  final Map<SrTile, ui.Image> _aiTiles = {};
  final Set<SrTile> _aiLoading = {};
  Set<SrTile> _aiWanted = const {};

  MissionMockProvider get mission => widget.mission;
  GeoAnchor get anchor => widget.anchor;

  @override
  void didUpdateWidget(SatelliteMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.followRobot) _scheduleRecentre();
  }

  @override
  void dispose() {
    _mapController.dispose();
    for (final image in _aiTiles.values) {
      image.dispose();
    }
    _ownAi?.close();
    super.dispose();
  }

  /// Brings the AI tiles in line with [bounds]: drops the ones that left it
  /// and starts loading the missing ones (after this frame; never mid-build).
  void _syncAiTiles(LatLngBounds bounds) {
    final wanted = widget.aiEnhance
        ? SrTile.covering(bounds).toSet()
        : const <SrTile>{};
    if (setEquals(wanted, _aiWanted)) return;
    _aiWanted = wanted;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !setEquals(wanted, _aiWanted)) return;
      final gone = _aiTiles.keys.where((t) => !wanted.contains(t)).toList();
      if (gone.isNotEmpty) {
        setState(() {
          for (final t in gone) {
            _aiTiles.remove(t)?.dispose();
          }
        });
      }
      for (final t in wanted) {
        if (!_aiTiles.containsKey(t) && !_aiLoading.contains(t)) {
          _loadAiTile(t);
        }
      }
    });
  }

  Future<void> _loadAiTile(SrTile tile) async {
    setState(() => _aiLoading.add(tile));
    try {
      final result = await _ai.load(tile);
      if (result == null) return;
      if (!mounted || !_aiWanted.contains(tile)) {
        result.image.dispose();
        return;
      }
      setState(() {
        _aiTiles.remove(tile)?.dispose();
        _aiTiles[tile] = result.image;
      });
    } catch (e) {
      debugPrint('AI tile $tile failed: $e');
    } finally {
      if (mounted) setState(() => _aiLoading.remove(tile));
    }
  }

  /// Puts the robot at the centre of the map, keeping the zoom. Runs after the
  /// frame: the map controller must not be driven mid-build.
  void _scheduleRecentre() {
    if (_recentreScheduled) return;
    _recentreScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _recentreScheduled = false;
      if (!mounted || !widget.followRobot || _zooming) return;
      _mapController.move(
        _ll(mission.robotPosition),
        _mapController.camera.zoom,
      );
    });
  }

  void _onMapEvent(MapEvent event) {
    switch (event) {
      case MapEventMoveStart(source: MapEventSource.multiFingerGestureStart) ||
          MapEventDoubleTapZoomStart():
        _zooming = true;
      case MapEventMoveEnd(source: MapEventSource.multiFingerEnd) ||
          MapEventDoubleTapZoomEnd():
        _zooming = false;
        if (widget.followRobot) _scheduleRecentre();
      case MapEventScrollWheelZoom():
        if (widget.followRobot) _scheduleRecentre();
      case MapEventMoveStart(source: MapEventSource.dragStart):
        // A one-finger pan means the user wants to look somewhere else.
        if (widget.followRobot) widget.onFollowRobotChanged?.call(false);
    }
  }

  LatLng _ll(MapPoint p) => anchor.worldToLatLng(p.x, p.y);

  /// Bounded viewing area (so the satellite view can't pan off to arbitrary
  /// places on Earth): the map content extent — freespace grid + zones + robot
  /// — squared, expanded by a margin, with a sensible minimum size. With
  /// [centreOnRobot] the square is centred on the robot instead, still
  /// covering all the content.
  LatLngBounds _contentBounds({bool centreOnRobot = false}) {
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
      add(
        fs.originX + fs.width * fs.resolution,
        fs.originY + fs.height * fs.resolution,
      );
    }
    for (final z in mission.zones) {
      for (final p in z.points) {
        add(p.x, p.y);
      }
    }
    add(mission.robotPosition.x, mission.robotPosition.y);

    final robot = mission.robotPosition;
    final cx = centreOnRobot ? robot.x : (minX! + maxX!) / 2;
    final cy = centreOnRobot ? robot.y : (minY! + maxY!) / 2;
    final halfX = math.max(cx - minX!, maxX! - cx);
    final halfY = math.max(cy - minY!, maxY! - cy);
    // Square half-extent: at least 10 m, plus a 20% + 2 m margin.
    final half = math.max(math.max(halfX, halfY), 10.0) * 1.2 + 2.0;
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
      bottomLeftCorner: anchor.worldToLatLng(
        layer.originX,
        layer.originY + worldH,
      ),
      bottomRightCorner: anchor.worldToLatLng(
        layer.originX + worldW,
        layer.originY + worldH,
      ),
      opacity: opacity,
    );
  }

  @override
  Widget build(BuildContext context) {
    final phonePosition = widget.phonePosition;
    final phoneAccuracyM = widget.phoneAccuracyM;
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
    _syncAiTiles(bounds);
    final aiOverlays = [
      for (final e in _aiTiles.entries)
        if (_aiWanted.contains(e.key))
          OverlayImage(
            bounds: e.key.bounds,
            imageProvider: _UiImageProvider(e.value),
          ),
    ];

    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        // Open framed on the content; keep the map CENTRE locked to it (so
        // you can't pan away to arbitrary places), but allow zooming out to
        // see the surroundings (z16–z22, ~6 levels).
        initialCameraFit: CameraFit.bounds(
          bounds: widget.followRobot
              ? _contentBounds(centreOnRobot: true)
              : bounds,
          padding: const EdgeInsets.all(24),
        ),
        // Until the fit applies, start inside the constraint (the
        // controller asserts this when it is handed the options).
        initialCenter: bounds.center,
        cameraConstraint: CameraConstraint.containCenter(bounds: bounds),
        onMapEvent: _onMapEvent,
        minZoom: 16,
        maxZoom: 22,
        // Enable all gestures incl. mouse-wheel / trackpad zoom (works in
        // the desktop-run iOS sim); rotation off to keep north up.
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          urlTemplate: SatelliteMapView.nlscTileUrl,
          userAgentPackageName: 'com.example.mower_stdio',
          maxNativeZoom: SatelliteMapView.nlscMaxNativeZoom,
        ),
        if (aiOverlays.isNotEmpty) OverlayImageLayer(overlayImages: aiOverlays),
        if (gridOverlays.isNotEmpty)
          OverlayImageLayer(overlayImages: gridOverlays),
        if (zonePolygons.isNotEmpty) PolygonLayer(polygons: zonePolygons),
        if (coveragePolylines.isNotEmpty)
          PolylineLayer(polylines: coveragePolylines),
        if (phonePosition != null && (phoneAccuracyM ?? 0) > 0)
          CircleLayer(
            circles: [
              CircleMarker(
                point: phonePosition,
                radius: phoneAccuracyM!,
                useRadiusInMeter: true,
                color: const Color(0x261A73E8),
                borderColor: const Color(0x661A73E8),
                borderStrokeWidth: 1,
              ),
            ],
          ),
        MarkerLayer(
          markers: [
            Marker(
              point: _ll(mission.robotPosition),
              width: 40,
              height: 40,
              child: const BreathingMarker(),
            ),
            if (phonePosition != null)
              Marker(
                point: phonePosition,
                width: 22,
                height: 22,
                child: const PhoneLocationDot(),
              ),
          ],
        ),
        if (widget.aiEnhance && _aiLoading.isNotEmpty)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: _AiLoadingChip(
                done: _aiWanted.where(_aiTiles.containsKey).length,
                total: _aiWanted.length,
              ),
            ),
          ),
        RichAttributionWidget(
          attributions: [
            const TextSourceAttribution('© 內政部國土測繪中心'),
            if (widget.aiEnhance)
              const TextSourceAttribution('AI 強化影像，細節僅供參考'),
          ],
        ),
      ],
    );
  }
}

class _AiLoadingChip extends StatelessWidget {
  const _AiLoadingChip({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          ),
          const SizedBox(width: 8),
          Text(
            'AI 強化中 $done/$total',
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
        ],
      ),
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

/// "You are here" marker for the phone's own position: a blue dot with a white
/// ring, the convention users know from phone map apps.
class PhoneLocationDot extends StatelessWidget {
  const PhoneLocationDot({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1A73E8),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [
          BoxShadow(color: Color(0x55000000), blurRadius: 4),
        ],
      ),
    );
  }
}
