import 'dart:async';
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
import '../services/google_map_tiles.dart';
import '../services/imagery_offset_store.dart';
import 'base_station_marker.dart';
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
    this.resumeFollowAfter,
    this.lockPan = false,
    this.bottomInset = 0,
    this.animateMarker = true,
    this.aiEnhance = false,
    this.aiService,
    this.googleTiles,
    this.googleOffset,
    this.nlscCompare = 0,
    this.offsetStore,
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

  /// How long the map stays where a drag left it before it reports `true`
  /// to [onFollowRobotChanged] again (timed from the last drag or fling, so
  /// it never pulls away under a finger). Null: a drag ends following for
  /// good.
  final Duration? resumeFollowAfter;

  /// Zoom only: no one-finger pan, so a thumb brushing the map while driving
  /// cannot pull it off the robot.
  final bool lockPan;

  /// Height of the controls drawn over the map's bottom edge (the manual
  /// joysticks). The attribution and the AI progress chip sit above it, where
  /// a thumb is not on them.
  final double bottomInset;

  /// Whether the robot marker pulses. A pulse repaints the map every frame, so
  /// it is off while driving, when the controls and a video are what matter.
  final bool animateMarker;

  /// Overlay the content area with AI-sharpened (x4) tiles.
  final bool aiEnhance;

  /// Injected for tests; by default one is created on first use.
  final AiBaseMapService? aiService;

  /// Google's satellite tiles, used in place of NLSC's when the build has a
  /// key. Injected for tests; by default [GoogleMapTiles.shared].
  final GoogleMapTiles? googleTiles;

  /// Where Google's photo is moved to; by default the one saved for the site
  /// in [offsetStore]. The alignment page passes the one being set.
  final ImageryOffset? googleOffset;

  /// The NLSC photo laid over Google's at this opacity (0: not at all), to
  /// align one with the other. Only while Google's tiles are up.
  final double nlscCompare;

  /// Injected for tests; by default [ImageryOffsetStore.shared].
  final ImageryOffsetStore? offsetStore;

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

  /// Counts down to following again after the user panned away.
  Timer? _resumeFollow;

  /// Google's tiles once a session is open; NLSC's until then (and for good
  /// with no key, or when Google refuses).
  GoogleTileSource? _google;
  TileProvider? _googleProvider;

  /// Google has not answered yet.
  bool _googlePending = false;

  /// The alignment saved for this site.
  ImageryOffset _savedOffset = ImageryOffset.zero;
  ImageryOffsetStore get _offsets =>
      widget.offsetStore ?? ImageryOffsetStore.shared;

  /// The AI tiles sharpen NLSC's photo; over Google's they would only hide
  /// it, so they wait until Google has said no.
  bool get _aiOn => widget.aiEnhance && _google == null && !_googlePending;

  AiBaseMapService? _ownAi;
  AiBaseMapService get _ai =>
      widget.aiService ?? (_ownAi ??= AiBaseMapService());

  /// AI tiles for the current content area, the ones still loading, and the
  /// area they were computed for.
  final Map<SrTile, ui.Image> _aiTiles = {};
  final Set<SrTile> _aiLoading = {};
  Set<SrTile> _aiWanted = const {};

  // The mission layers are kept as built widgets. A pose tick then hands
  // flutter_map the very same instances, which it skips: it drops a layer's
  // projection and simplification caches whenever the layer *widget* is
  // replaced, whatever lists that holds. Each layer is rebuilt only when its
  // own data was replaced (the provider assigns new lists / layers, it never
  // edits them in place); zones are compared by their points, since a zone
  // summary swaps in equal copies twice a second.
  GeoAnchor? _layersAnchor;
  MapGridLayer? _freeLayer, _channelLayer, _riskLayer;
  Widget? _gridLayer;
  List<List<MapPoint>>? _coverageSrc;
  Widget? _coverageLayer;
  List<List<MapPoint>> _zonePoints = const [];
  Widget? _zoneLayer;

  MissionMockProvider get mission => widget.mission;
  GeoAnchor get anchor => widget.anchor;

  @override
  void initState() {
    super.initState();
    _loadGoogle();
    _offsets.addListener(_loadOffset);
    _loadOffset();
  }

  /// The site's saved alignment; again whenever one is saved.
  Future<void> _loadOffset() async {
    final anchor = widget.anchor;
    final offset = await _offsets.load(anchor);
    if (!mounted || _otherSite(widget.anchor, anchor)) return;
    if (offset != _savedOffset) setState(() => _savedOffset = offset);
  }

  @override
  void didUpdateWidget(SatelliteMapView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.followRobot) _scheduleRecentre();
    if (_otherSite(widget.anchor, oldWidget.anchor)) {
      _loadGoogle();
      _loadOffset();
    }
  }

  /// The datum is re-sent as a new object; only a move to another place
  /// (more than ~100 m) changes Google's copyright and depth.
  static bool _otherSite(GeoAnchor a, GeoAnchor b) =>
      (a.originLat - b.originLat).abs() > 1e-3 ||
      (a.originLon - b.originLon).abs() > 1e-3;

  /// Opens Google's tiles for this site (its copyright and depth are per
  /// place). The NLSC photo stays up meanwhile, and if it fails.
  Future<void> _loadGoogle() async {
    final tiles = widget.googleTiles ?? GoogleMapTiles.shared;
    if (!tiles.configured) return;
    final anchor = widget.anchor;
    _googlePending = true;
    final source = await tiles.sourceFor(_contentBounds());
    if (!mounted || _otherSite(widget.anchor, anchor)) return;
    setState(() {
      _googlePending = false;
      if (source != null) {
        _google = source;
        // A copy: flutter_map writes its User-Agent into the map it gets.
        _googleProvider = NetworkTileProvider(headers: {...source.headers});
      }
    });
  }

  @override
  void dispose() {
    _offsets.removeListener(_loadOffset);
    _resumeFollow?.cancel();
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
    final wanted = _aiOn ? SrTile.covering(bounds).toSet() : const <SrTile>{};
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
        _resumeFollow?.cancel();
        if (widget.followRobot) widget.onFollowRobotChanged?.call(false);
      case MapEventMoveEnd(source: MapEventSource.dragEnd) ||
          MapEventFlingAnimationEnd():
        _scheduleResumeFollow();
    }
  }

  void _scheduleResumeFollow() {
    final after = widget.resumeFollowAfter;
    _resumeFollow?.cancel();
    if (after == null) return;
    _resumeFollow = Timer(after, () {
      if (mounted && !widget.followRobot) {
        widget.onFollowRobotChanged?.call(true);
      }
    });
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
    final base = mission.baseStationPosition;
    if (base != null) add(base.x, base.y);

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

  /// Rebuilds the mission layers whose data was replaced since the last build
  /// (all of them when the geo anchor was).
  void _syncLayers() {
    final anchorChanged = !identical(_layersAnchor, anchor);
    _layersAnchor = anchor;

    if (anchorChanged ||
        !identical(_freeLayer, mission.freeSpaceLayer) ||
        !identical(_channelLayer, mission.channelMapLayer) ||
        !identical(_riskLayer, mission.riskMapLayer)) {
      _freeLayer = mission.freeSpaceLayer;
      _channelLayer = mission.channelMapLayer;
      _riskLayer = mission.riskMapLayer;
      final overlays = <RotatedOverlayImage?>[
        // Drawn bottom→top: freespace, then channel, then risk on top.
        _gridOverlay(_freeLayer, 0.55),
        _gridOverlay(_channelLayer, 0.6),
        _gridOverlay(_riskLayer, 0.6),
      ].whereType<RotatedOverlayImage>().toList();
      _gridLayer = overlays.isEmpty
          ? null
          : OverlayImageLayer(
              key: const ValueKey('grid-layers'),
              overlayImages: overlays,
            );
    }

    if (anchorChanged || !identical(_coverageSrc, mission.coverageRows)) {
      _coverageSrc = mission.coverageRows;
      final lines = <Polyline>[
        for (final row in _coverageSrc!)
          if (row.length >= 2)
            Polyline(
              points: row.map(_ll).toList(),
              strokeWidth: 2.5,
              color: const Color(0xFF2EC86E),
            ),
      ];
      _coverageLayer = lines.isEmpty
          ? null
          : PolylineLayer(key: const ValueKey('coverage'), polylines: lines);
    }

    final zones = mission.zones;
    if (anchorChanged || !_samePoints(_zonePoints, zones)) {
      _zonePoints = [for (final z in zones) z.points];
      final polygons = <Polygon>[
        for (final z in zones)
          if (z.points.length >= 3)
            Polygon(
              points: z.points.map(_ll).toList(),
              color: const Color(0x332DA653),
              borderColor: const Color(0xFF2DA653),
              borderStrokeWidth: 2,
            ),
      ];
      _zoneLayer = polygons.isEmpty
          ? null
          : PolygonLayer(key: const ValueKey('zones'), polygons: polygons);
    }
  }

  static bool _samePoints(List<List<MapPoint>> known, List<MissionZone> zones) {
    if (known.length != zones.length) return false;
    for (var i = 0; i < zones.length; i++) {
      if (!identical(known[i], zones[i].points)) return false;
    }
    return true;
  }

  /// The path being driven for a recording, as the schematic map draws it: a
  /// line (a translucent closing polygon for zones and no-go areas), a white
  /// start anchor and the live head. Empty when nothing is being recorded.
  List<Widget> _trailLayers() {
    final type = mission.recordingType;
    final trail = mission.recordTrail;
    if (type == null || trail.isEmpty) return const [];
    final color = switch (type) {
      RecordObjectType.zone => const Color(0xFF35B861),
      RecordObjectType.risk => const Color(0xFFE55353),
      RecordObjectType.channel => const Color(0xFF25AFC6),
    };
    final isArea = type != RecordObjectType.channel;
    final points = [for (final p in trail) _ll(p)];
    return [
      if (isArea && points.length >= 3)
        PolygonLayer(
          key: const ValueKey('record-trail'),
          polygons: [
            Polygon(
              points: points,
              color: color.withValues(alpha: 0.16),
              borderColor: color,
              borderStrokeWidth: 4,
            ),
          ],
        )
      else if (points.length >= 2)
        PolylineLayer(
          key: const ValueKey('record-trail'),
          polylines: [Polyline(points: points, strokeWidth: 4, color: color)],
        ),
      CircleLayer(
        key: const ValueKey('record-ends'),
        circles: [
          CircleMarker(
            point: points.first,
            radius: 6,
            color: Colors.white,
            borderColor: color,
            borderStrokeWidth: 2.5,
          ),
          CircleMarker(point: points.last, radius: 4.5, color: color),
        ],
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final phonePosition = widget.phonePosition;
    final phoneAccuracyM = widget.phoneAccuracyM;
    _syncLayers();

    final bounds = _contentBounds();
    final google = _google;
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
        // the desktop-run iOS sim); rotation off to keep north up. Locked
        // to zoom-only while driving.
        interactionOptions: InteractionOptions(
          flags: widget.lockPan
              ? InteractiveFlag.pinchZoom |
                    InteractiveFlag.doubleTapZoom |
                    InteractiveFlag.scrollWheelZoom
              : InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        if (google != null)
          GroundShift(
            offset: widget.googleOffset ?? _savedOffset,
            child: TileLayer(
              // Keyed: a new session is a new set of tiles.
              key: ValueKey(google.urlTemplate),
              urlTemplate: google.urlTemplate,
              tileProvider: _googleProvider,
              maxNativeZoom: google.maxNativeZoom,
              userAgentPackageName: 'com.example.mower_stdio',
            ),
          )
        else
          TileLayer(
            urlTemplate: SatelliteMapView.nlscTileUrl,
            userAgentPackageName: 'com.example.mower_stdio',
            maxNativeZoom: SatelliteMapView.nlscMaxNativeZoom,
          ),
        if (google != null && widget.nlscCompare > 0)
          Opacity(
            opacity: widget.nlscCompare.clamp(0.0, 1.0),
            child: TileLayer(
              urlTemplate: SatelliteMapView.nlscTileUrl,
              userAgentPackageName: 'com.example.mower_stdio',
              maxNativeZoom: SatelliteMapView.nlscMaxNativeZoom,
            ),
          ),
        if (aiOverlays.isNotEmpty) OverlayImageLayer(overlayImages: aiOverlays),
        if (_gridLayer != null) _gridLayer!,
        if (_zoneLayer != null) _zoneLayer!,
        if (_coverageLayer != null) _coverageLayer!,
        ..._trailLayers(),
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
            // Under the robot: a docked robot is drawn on top of its dock.
            if (mission.baseStationPosition case final base?)
              Marker(
                point: _ll(base),
                width: BaseStationMarker.size,
                height: BaseStationMarker.size,
                child: const BaseStationMarker(),
              ),
            Marker(
              point: _ll(mission.robotPosition),
              width: 40,
              height: 40,
              child: _RobotMarker(
                // Map-frame heading -> clockwise from up on the north-up map.
                headingRad: anchor.bearingRad - mission.robotHeadingRad,
                animate: widget.animateMarker,
              ),
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
        if (_aiOn && _aiLoading.isNotEmpty)
          Align(
            alignment: Alignment.bottomLeft,
            child: Padding(
              // Not inside a SafeArea like the attribution: add the inset.
              padding: EdgeInsets.fromLTRB(
                12,
                12,
                12,
                12 + widget.bottomInset + MediaQuery.paddingOf(context).bottom,
              ),
              child: _AiLoadingChip(
                done: _aiWanted.where(_aiTiles.containsKey).length,
                total: _aiWanted.length,
              ),
            ),
          ),
        if (google != null)
          _GoogleAttribution(
            copyright: google.copyright,
            bottom: widget.bottomInset + MediaQuery.paddingOf(context).bottom,
          )
        else
          Padding(
            padding: EdgeInsets.only(bottom: widget.bottomInset),
            child: RichAttributionWidget(
              attributions: [
                const TextSourceAttribution('© 內政部國土測繪中心'),
                if (_aiOn) const TextSourceAttribution('AI 強化影像，細節僅供參考'),
              ],
            ),
          ),
      ],
    );
  }
}

/// Draws a map layer moved by [offset] on the ground: Google's photo, placed
/// where things really are. The map does not rotate (rotation is off), so a
/// screen shift is all it takes.
class GroundShift extends StatelessWidget {
  const GroundShift({super.key, required this.offset, required this.child});

  final ImageryOffset offset;
  final Widget child;

  /// Screen pixels for [offset] at [latitude] and [zoom] (Web Mercator,
  /// 256 px tiles); screen y grows southward.
  static Offset pixels(ImageryOffset offset, double latitude, double zoom) {
    final metresPerPixel =
        156543.03392 * math.cos(latitude * math.pi / 180) / math.pow(2, zoom);
    return Offset(
      offset.eastM / metresPerPixel,
      -offset.northM / metresPerPixel,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (offset.isZero) return child;
    final camera = MapCamera.of(context);
    return Transform.translate(
      offset: pixels(offset, camera.center.latitude, camera.zoom),
      child: child,
    );
  }
}

/// Google's terms for its tiles: the Google Maps logo always in view (16-19
/// dp tall, 10 dp clear on the left, right and top, 5 dp below, nothing over
/// it) and the data copyright in full. Kept as small and out of the way as
/// that allows: the smallest logo, the copyright in small print over it, in
/// the corner above the left stick, where no button goes (a zone's task
/// buttons float over the right stick).
class _GoogleAttribution extends StatelessWidget {
  const _GoogleAttribution({required this.copyright, required this.bottom});

  final String copyright;
  final double bottom;

  /// Google's minimum.
  static const double logoHeight = 16;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(10, 10, 10, 5 + bottom),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (copyright.isNotEmpty) ...[
                  Text(
                    copyright,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 9,
                      height: 1.2,
                      shadows: const [Shadow(blurRadius: 2)],
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Semantics(
                  label: 'Google Maps',
                  image: true,
                  child: Image.asset(
                    'assets/images/google_maps_logo.png',
                    height: logoHeight,
                    excludeFromSemantics: true,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The robot on the satellite map: the pulsing tractor, with a wedge on its
/// rim pointing the way it faces ([headingRad], clockwise from up).
class _RobotMarker extends StatelessWidget {
  const _RobotMarker({required this.headingRad, required this.animate});

  final double headingRad;
  final bool animate;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      clipBehavior: Clip.none,
      children: [
        Transform.rotate(
          key: const ValueKey('robot-heading'),
          angle: headingRad,
          child: Align(
            alignment: Alignment.topCenter,
            child: Transform.translate(
              offset: const Offset(0, -9),
              child: const CustomPaint(
                size: Size(14, 10),
                painter: _WedgePainter(),
              ),
            ),
          ),
        ),
        BreathingMarker(animate: animate),
      ],
    );
  }
}

class _WedgePainter extends CustomPainter {
  const _WedgePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final path = ui.Path()
      ..moveTo(size.width / 2, 0)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(path, Paint()..color = const Color(0xFFE65100));
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(covariant _WedgePainter oldDelegate) => false;
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
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'AI 強化中 $done/$total',
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w700,
            ),
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
        boxShadow: const [BoxShadow(color: Color(0x55000000), blurRadius: 4)],
      ),
    );
  }
}
