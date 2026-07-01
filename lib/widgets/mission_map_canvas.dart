import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';
import '../models/robot_fleet.dart';
import '../providers/mission_mock_provider.dart';

/// Screen positions of the 4 corner handles (TL, TR, BR, BL).
List<Offset> alignmentCornerScreens(
  ImageAlignmentOverlay overlay,
  Offset Function(MapPoint) project,
) {
  return [
    project(overlay.corner(0)),
    project(overlay.corner(1)),
    project(overlay.corner(2)),
    project(overlay.corner(3)),
  ];
}

/// Screen position of the Word-style rotate handle, above the top-centre edge.
Offset alignmentRotateHandleScreen(
  ImageAlignmentOverlay overlay,
  Offset Function(MapPoint) project, {
  double gapPx = 34,
}) {
  final topMid = project(overlay.worldOf(overlay.imageWidth / 2, 0));
  final center = project(overlay.centerWorld);
  var dir = topMid - center;
  final len = dir.distance;
  dir = len > 1e-4 ? dir / len : const Offset(0, -1);
  return topMid + dir * gapPx;
}

/// Snapshot of the world↔screen mapping used by [MissionMapCanvas], so callers
/// (e.g. the alignment page) can convert finger deltas into map metres.
class MapProjection {
  const MapProjection({
    required this.scale,
    required this.offset,
    required this.worldBounds,
  });

  /// Pixels per metre.
  final double scale;

  /// Screen offset of [worldBounds] top-left.
  final Offset offset;

  /// World rectangle (map-frame metres) currently framed by the canvas.
  final Rect worldBounds;

  Offset project(MapPoint point) => Offset(
        offset.dx + (point.x - worldBounds.left) * scale,
        offset.dy + (point.y - worldBounds.top) * scale,
      );

  MapPoint unproject(Offset screen) => MapPoint(
        worldBounds.left + (screen.dx - offset.dx) / scale,
        worldBounds.top + (screen.dy - offset.dy) / scale,
      );
}

/// A semi-transparent uploaded-image mask rendered on top of the freespace so
/// the user can align it. Geometry mirrors the backend
/// `rasterize_image_masks` placement exactly so the preview equals the raster.
class ImageAlignmentOverlay {
  const ImageAlignmentOverlay({
    required this.image,
    required this.imageWidth,
    required this.imageHeight,
    required this.baseResolutionM,
    required this.startPixel,
    required this.placement,
  });

  /// Pre-rendered RGBA image of the free (+risk) mask.
  final ui.Image image;
  final int imageWidth;
  final int imageHeight;

  /// Draft base resolution (metres per pixel) before [placement] scale.
  final double baseResolutionM;

  /// Start point in image pixel coords (col, row); the rotation/scale pivot.
  final MapPoint startPixel;
  final ImageMissionPlacement placement;

  /// World (map-frame metres) location of image pixel (col, row), using the
  /// exact backend formula: world = R(theta)·(localMetres - start) + anchor,
  /// with localMetres = (col*res, (H-row)*res), res = baseRes * scale.
  MapPoint worldOf(double col, double row) {
    final res = baseResolutionM * placement.mapScale;
    final theta = placement.mapRotationRad;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    final lx = (col - startPixel.x) * res;
    final ly = (startPixel.y - row) * res;
    return MapPoint(
      placement.mapAnchor.x + cosT * lx - sinT * ly,
      placement.mapAnchor.y + sinT * lx + cosT * ly,
    );
  }

  /// World point of image corner i (0=TL, 1=TR, 2=BR, 3=BL).
  MapPoint corner(int i) {
    final w = imageWidth.toDouble();
    final h = imageHeight.toDouble();
    switch (i) {
      case 0:
        return worldOf(0, 0);
      case 1:
        return worldOf(w, 0);
      case 2:
        return worldOf(w, h);
      default:
        return worldOf(0, h);
    }
  }

  /// World point of the image centre.
  MapPoint get centerWorld =>
      worldOf(imageWidth / 2, imageHeight / 2);

  /// Inverse of [worldOf]: image pixel (col, row) that currently sits at the
  /// given world point. Used for tap-to-set-start.
  MapPoint pixelOf(MapPoint world) {
    final res = baseResolutionM * placement.mapScale;
    final theta = placement.mapRotationRad;
    final cosT = math.cos(theta);
    final sinT = math.sin(theta);
    final dx = world.x - placement.mapAnchor.x;
    final dy = world.y - placement.mapAnchor.y;
    // R(-theta) · (world - anchor)
    final lx = cosT * dx + sinT * dy;
    final ly = -sinT * dx + cosT * dy;
    return MapPoint(
      startPixel.x + lx / res,
      startPixel.y - ly / res,
    );
  }

  /// Axis-aligned world bounds of the four image corners.
  Rect worldBounds() {
    final corners = [
      worldOf(0, 0),
      worldOf(imageWidth.toDouble(), 0),
      worldOf(imageWidth.toDouble(), imageHeight.toDouble()),
      worldOf(0, imageHeight.toDouble()),
    ];
    var minX = corners.first.x, maxX = corners.first.x;
    var minY = corners.first.y, maxY = corners.first.y;
    for (final c in corners.skip(1)) {
      minX = math.min(minX, c.x);
      maxX = math.max(maxX, c.x);
      minY = math.min(minY, c.y);
      maxY = math.max(maxY, c.y);
    }
    return Rect.fromLTRB(minX, minY, maxX, maxY);
  }
}

class MissionMapCanvas extends StatefulWidget {
  const MissionMapCanvas({
    super.key,
    required this.mission,
    required this.bottomInset,
    this.robots = const [],
    this.selectedRobotId,
    this.showScalePill = true,
    this.alignmentOverlay,
    this.worldBoundsOverride,
    this.onProjectionPainted,
  });

  final MissionMockProvider mission;
  final double bottomInset;
  final List<RobotAgent> robots;
  final int? selectedRobotId;
  final bool showScalePill;

  /// When set, draws a draggable uploaded-image overlay on top of the map.
  final ImageAlignmentOverlay? alignmentOverlay;

  /// When set, freezes the framed world rect (so dragging doesn't rescale).
  final Rect? worldBoundsOverride;

  /// Reports the world↔screen mapping each paint (no setState; safe).
  final ValueChanged<MapProjection>? onProjectionPainted;

  @override
  MissionMapCanvasState createState() => MissionMapCanvasState();
}

/// Public state so that a `GlobalKey<MissionMapCanvasState>` can access
/// [robotScreenPositions] from a parent widget for long-press hit-testing.
class MissionMapCanvasState extends State<MissionMapCanvas>
    with SingleTickerProviderStateMixin {
  late final AnimationController _breatheController;

  /// Last-painted screen positions of each robot, keyed by robot id.
  /// Updated synchronously inside the painter — no setState needed.
  final Map<int, Offset> robotScreenPositions = {};

  /// Last-painted world↔screen mapping, for hit-testing / gesture conversion.
  MapProjection? lastProjection;

  void _onRobotPositionsPainted(Map<int, Offset> positions) {
    robotScreenPositions
      ..clear()
      ..addAll(positions);
  }

  void _onProjectionPainted(MapProjection projection) {
    lastProjection = projection;
    widget.onProjectionPainted?.call(projection);
  }

  @override
  void initState() {
    super.initState();
    _breatheController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _breatheController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _breatheController,
      builder: (context, _) => CustomPaint(
        painter: _MissionMapPainter(
          mission: widget.mission,
          bottomInset: widget.bottomInset,
          showScalePill: widget.showScalePill,
          robots: widget.robots,
          selectedRobotId: widget.selectedRobotId,
          breatheValue: _breatheController.value,
          onRobotPositionsPainted: _onRobotPositionsPainted,
          alignmentOverlay: widget.alignmentOverlay,
          worldBoundsOverride: widget.worldBoundsOverride,
          onProjectionPainted: _onProjectionPainted,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }
}

class _MissionMapPainter extends CustomPainter {
  _MissionMapPainter({
    required this.mission,
    required this.bottomInset,
    required this.showScalePill,
    required this.robots,
    required this.selectedRobotId,
    required this.breatheValue,
    required this.onRobotPositionsPainted,
    this.alignmentOverlay,
    this.worldBoundsOverride,
    this.onProjectionPainted,
  });

  final MissionMockProvider mission;
  final double bottomInset;
  final bool showScalePill;
  final List<RobotAgent> robots;
  final int? selectedRobotId;
  final double breatheValue;
  final void Function(Map<int, Offset>) onRobotPositionsPainted;
  final ImageAlignmentOverlay? alignmentOverlay;
  final Rect? worldBoundsOverride;
  final void Function(MapProjection)? onProjectionPainted;

  static const Rect _fallbackWorldBounds = Rect.fromLTWH(0, 12, 104, 128);

  @override
  void paint(Canvas canvas, Size size) {
    final backgroundPaint = Paint()..color = const Color(0xFFECEFF1);
    canvas.drawRect(Offset.zero & size, backgroundPaint);

    final minMapHeight = math.min(260.0, size.height);
    final mapHeight = (size.height - bottomInset + 56)
        .clamp(minMapHeight, size.height)
        .toDouble();
    final mapRect = Rect.fromLTWH(0, 0, size.width, mapHeight);

    _drawGrid(canvas, mapRect);
    final projection = _projection(mapRect, worldBoundsOverride ?? _worldBounds());
    final project = projection.project;
    onProjectionPainted?.call(projection);

    if (mission.freeSpaceLayer != null) {
      _drawGridLayer(canvas, mission.freeSpaceLayer!, project);
    }
    if (mission.channelMapLayer != null) {
      _drawGridLayer(canvas, mission.channelMapLayer!, project);
    }
    if (mission.riskMapLayer != null) {
      _drawGridLayer(canvas, mission.riskMapLayer!, project);
    }
    if (alignmentOverlay != null) {
      _drawAlignmentOverlay(canvas, alignmentOverlay!, project);
    }

    if (mission.layers.zones) {
      for (final zone in mission.zones) {
        if (zone.points.length < 3) continue;
        // Skip the object under vertex-edit; the editor draws it live instead.
        if (_editingObject('zone', zone.id)) continue;
        _drawPolygon(
          canvas,
          zone.points,
          project,
          fill: const Color(0x333BBF6A),
          stroke: const Color(0xFF2DA653),
          strokeWidth: 3,
        );
        if (mission.isObjectSelected('zone', zone.id)) {
          _drawSelectionHighlight(canvas, zone.points, project, closed: true);
        }
        _drawLabel(
          canvas,
          zone.name,
          project(zone.points.first),
          const Color(0xFF1B5E35),
        );
      }
    }

    if (mission.layers.risks) {
      for (final risk in mission.riskZones) {
        if (_editingObject('risk', risk.id)) continue;
        _drawPolygon(
          canvas,
          risk.points,
          project,
          fill: const Color(0x33E55353),
          stroke: const Color(0xFFE04A4A),
          strokeWidth: 3,
        );
        if (mission.isObjectSelected('risk', risk.id)) {
          _drawSelectionHighlight(canvas, risk.points, project, closed: true);
        }
      }
    }

    if (mission.layers.channels) {
      for (final channel in mission.channels) {
        if (_editingObject('channel', channel.id)) continue;
        _drawPolyline(
          canvas,
          channel.points,
          project,
          color: const Color(0xFF25AFC6),
          strokeWidth: 5,
        );
        if (mission.isObjectSelected('channel', channel.id)) {
          _drawSelectionHighlight(canvas, channel.points, project,
              closed: false);
        }
      }
    }

    if (mission.editVertexMode && mission.editPolygon.isNotEmpty) {
      _drawVertexEditor(canvas, project);
    }

    if (mission.layers.coverage) {
      _drawCoverageRows(canvas, project);
    }

    if (mission.layers.invalidSegments) {
      for (final segment in mission.invalidSegments) {
        _drawPolyline(
          canvas,
          segment.points,
          project,
          color: const Color(0xFFE53935),
          strokeWidth: 6,
        );
      }
    }

    if (mission.recordingType != null) {
      _drawRecordingTrace(canvas, project);
    }

    if (mission.drawMode && mission.draftPolygon.isNotEmpty) {
      _drawDraft(canvas, project);
    }

    // Draw fleet robots; fall back to single robot if fleet is empty.
    final Map<int, Offset> robotPositions = {};
    if (robots.isNotEmpty) {
      for (final robot in robots) {
        final screenPos = project(robot.position);
        robotPositions[robot.id] = screenPos;
        // Offline robots are drawn greyed at their last known position.
        final drawColor = robot.online ? robot.color : _desaturate(robot.color);
        final isSelected = robot.id == selectedRobotId;
        if (isSelected && selectedRobotId != null && robot.online) {
          _drawRobotGlow(canvas, screenPos, robot.color, breatheValue);
        }
        _drawRobotWithColor(canvas, screenPos, robot.headingRad, drawColor);
        _drawRobotLabel(canvas, robot.name, screenPos, drawColor);
      }
    } else if (mission.shouldShowRobot) {
      _drawRobot(
        canvas,
        project(mission.robotPosition),
        mission.robotHeadingRad,
      );
    }

    if (showScalePill) {
      _drawScalePill(canvas, mapRect);
    }

    // Report positions to state — safe: no setState, just map mutation.
    onRobotPositionsPainted(robotPositions);
  }

  // ─── Coverage rows ─────────────────────────────────────────────────────────

  void _drawCoverageRows(
    Canvas canvas,
    Offset Function(MapPoint) project,
  ) {
    final hasFleet =
        robots.isNotEmpty && robots.any((r) => r.assignedRowIndices.isNotEmpty);

    if (!hasFleet) {
      // Single-robot fallback rendering
      for (var i = 0; i < mission.coverageRows.length; i++) {
        final isCurrent = i == mission.currentSegment - 1;
        _drawPolyline(
          canvas,
          mission.coverageRows[i],
          project,
          color: isCurrent ? const Color(0xFF147B58) : const Color(0x992A9470),
          strokeWidth: isCurrent ? 5 : 3,
        );
      }
      return;
    }

    final isAnySelected = selectedRobotId != null;

    for (final robot in robots) {
      final isSelected = robot.id == selectedRobotId;
      for (final rowIdx in robot.assignedRowIndices) {
        if (rowIdx >= mission.coverageRows.length) continue;
        final isCurrent = rowIdx == mission.currentSegment - 1;

        double opacity;
        if (isAnySelected) {
          // Breathing pulse for selected robot; dim others
          opacity = isSelected ? (0.35 + 0.65 * breatheValue) : 0.28;
        } else {
          opacity = 0.75;
        }

        final rowColor = robot.online ? robot.color : _desaturate(robot.color);
        _drawPolyline(
          canvas,
          mission.coverageRows[rowIdx],
          project,
          color: rowColor.withValues(alpha: opacity),
          strokeWidth: isCurrent ? 5 : 3,
        );
      }
    }
  }

  /// Greyed/desaturated variant of [c] for offline robots.
  static Color _desaturate(Color c) =>
      HSLColor.fromColor(c).withSaturation(0.0).withLightness(0.6).toColor();

  // ─── Projector ─────────────────────────────────────────────────────────────

  MapProjection _projection(Rect mapRect, Rect worldBounds) {
    final scale = math.min(
      (mapRect.width - 44) / worldBounds.width,
      (mapRect.height - 44) / worldBounds.height,
    );
    final contentSize = Size(
      worldBounds.width * scale,
      worldBounds.height * scale,
    );
    final offset = Offset(
      mapRect.left + (mapRect.width - contentSize.width) / 2,
      mapRect.top + (mapRect.height - contentSize.height) / 2,
    );
    return MapProjection(scale: scale, offset: offset, worldBounds: worldBounds);
  }

  static List<MapPoint> _gridCorners(MapGridLayer layer) {
    final w = layer.width * layer.resolution;
    final h = layer.height * layer.resolution;
    return [
      MapPoint(layer.originX, layer.originY),
      MapPoint(layer.originX + w, layer.originY + h),
    ];
  }

  Rect _worldBounds() {
    final overlay = alignmentOverlay;
    final points = <MapPoint>[
      if (mission.shouldShowRobot && robots.isEmpty) mission.robotPosition,
      for (final robot in robots) robot.position,
      for (final zone in mission.zones) ...zone.points,
      for (final risk in mission.riskZones) ...risk.points,
      for (final channel in mission.channels) ...channel.points,
      for (final row in mission.coverageRows) ...row,
      for (final segment in mission.invalidSegments) ...segment.points,
      if (mission.freeSpaceLayer != null)
        ..._gridCorners(mission.freeSpaceLayer!),
      if (overlay != null) ...[
        overlay.worldOf(0, 0),
        overlay.worldOf(overlay.imageWidth.toDouble(), 0),
        overlay.worldOf(
          overlay.imageWidth.toDouble(),
          overlay.imageHeight.toDouble(),
        ),
        overlay.worldOf(0, overlay.imageHeight.toDouble()),
      ],
    ];
    if (points.length < 2) return _fallbackWorldBounds;

    var minX = points.first.x;
    var maxX = points.first.x;
    var minY = points.first.y;
    var maxY = points.first.y;
    for (final point in points.skip(1)) {
      minX = math.min(minX, point.x);
      maxX = math.max(maxX, point.x);
      minY = math.min(minY, point.y);
      maxY = math.max(maxY, point.y);
    }
    final width = math.max(maxX - minX, 1.0);
    final height = math.max(maxY - minY, 1.0);
    final padding = math.max(math.max(width, height) * 0.12, 2.0);
    return Rect.fromLTRB(
      minX - padding,
      minY - padding,
      maxX + padding,
      maxY + padding,
    );
  }

  // ─── Grid layer ────────────────────────────────────────────────────────────

  void _drawGridLayer(
    Canvas canvas,
    MapGridLayer layer,
    Offset Function(MapPoint) project,
  ) {
    final worldW = layer.width * layer.resolution;
    final worldH = layer.height * layer.resolution;
    final topLeft = project(MapPoint(layer.originX, layer.originY));
    final bottomRight = project(
      MapPoint(layer.originX + worldW, layer.originY + worldH),
    );
    final dstRect = Rect.fromPoints(topLeft, bottomRight);
    if (dstRect.isEmpty) return;
    final srcRect = ui.Rect.fromLTWH(
      0,
      0,
      layer.width.toDouble(),
      layer.height.toDouble(),
    );
    canvas.drawImageRect(layer.image, srcRect, dstRect, Paint());
  }

  // ─── Alignment overlay (uploaded image being placed) ─────────────────────────

  void _drawAlignmentOverlay(
    Canvas canvas,
    ImageAlignmentOverlay overlay,
    Offset Function(MapPoint) project,
  ) {
    final w = overlay.imageWidth.toDouble();
    final h = overlay.imageHeight.toDouble();
    final p00 = project(overlay.worldOf(0, 0));
    final p10 = project(overlay.worldOf(w, 0));
    final p01 = project(overlay.worldOf(0, h));
    final p11 = project(overlay.worldOf(w, h));

    // Affine screen = A·imageCoord + t from three corner correspondences,
    // so the image is drawn as a rotated/scaled quad (rotated _drawGridLayer).
    final a = (p10.dx - p00.dx) / w;
    final b = (p10.dy - p00.dy) / w;
    final c = (p01.dx - p00.dx) / h;
    final d = (p01.dy - p00.dy) / h;
    final m = Matrix4.identity()
      ..setEntry(0, 0, a)
      ..setEntry(1, 0, b)
      ..setEntry(0, 1, c)
      ..setEntry(1, 1, d)
      ..setEntry(0, 3, p00.dx)
      ..setEntry(1, 3, p00.dy);

    canvas.save();
    canvas.transform(m.storage);
    canvas.drawImageRect(
      overlay.image,
      Rect.fromLTWH(0, 0, w, h),
      Rect.fromLTWH(0, 0, w, h),
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.restore();

    // Outline.
    const handleColor = Color(0xFF1565C0);
    final quad = Path()
      ..moveTo(p00.dx, p00.dy)
      ..lineTo(p10.dx, p10.dy)
      ..lineTo(p11.dx, p11.dy)
      ..lineTo(p01.dx, p01.dy)
      ..close();
    canvas.drawPath(
      quad,
      Paint()
        ..color = handleColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final whiteFill = Paint()..color = Colors.white;
    final handleStroke = Paint()
      ..color = handleColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    // Rotate handle (Word-style, above top-centre).
    final rotate = alignmentRotateHandleScreen(overlay, project);
    final topMid = project(overlay.worldOf(overlay.imageWidth / 2, 0));
    canvas.drawLine(
      topMid,
      rotate,
      Paint()
        ..color = handleColor
        ..strokeWidth = 2,
    );
    canvas.drawCircle(rotate, 10, whiteFill);
    canvas.drawCircle(rotate, 10, handleStroke);
    canvas.drawCircle(rotate, 3.5, Paint()..color = handleColor);

    // Corner handles.
    for (final c in alignmentCornerScreens(overlay, project)) {
      final r = Rect.fromCenter(center: c, width: 16, height: 16);
      final rr = RRect.fromRectAndRadius(r, const Radius.circular(3));
      canvas.drawRRect(rr, whiteFill);
      canvas.drawRRect(rr, handleStroke);
    }

    // Start marker (green) so it is distinct from the blue handles.
    final anchor = project(overlay.placement.mapAnchor);
    canvas.drawCircle(anchor, 7, whiteFill);
    canvas.drawCircle(anchor, 5, Paint()..color = const Color(0xFF2E9E5B));
  }

  // ─── Grid background ───────────────────────────────────────────────────────

  void _drawGrid(Canvas canvas, Rect rect) {
    final finePaint = Paint()
      ..color = const Color(0xFFD8DDE0)
      ..strokeWidth = 1;
    final heavyPaint = Paint()
      ..color = const Color(0xFFC6CED2)
      ..strokeWidth = 1.2;

    const spacing = 24.0;
    for (var x = rect.left; x <= rect.right; x += spacing) {
      canvas.drawLine(
        Offset(x, rect.top),
        Offset(x, rect.bottom),
        (x / spacing).round().isEven ? heavyPaint : finePaint,
      );
    }
    for (var y = rect.top; y <= rect.bottom; y += spacing) {
      canvas.drawLine(
        Offset(rect.left, y),
        Offset(rect.right, y),
        (y / spacing).round().isEven ? heavyPaint : finePaint,
      );
    }
  }

  // ─── Polygon / polyline ─────────────────────────────────────────────────────

  void _drawPolygon(
    Canvas canvas,
    List<MapPoint> points,
    Offset Function(MapPoint point) project, {
    required Color fill,
    required Color stroke,
    required double strokeWidth,
  }) {
    if (points.length < 3) return;
    final path = Path()
      ..moveTo(project(points.first).dx, project(points.first).dy);
    for (final point in points.skip(1)) {
      final offset = project(point);
      path.lineTo(offset.dx, offset.dy);
    }
    path.close();

    canvas.drawPath(path, Paint()..color = fill);
    canvas.drawPath(
      path,
      Paint()
        ..color = stroke
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth,
    );
  }

  bool _editingObject(String kind, int id) =>
      mission.editVertexMode && mission.editKind == kind && mission.editId == id;

  /// Vertex-edit overlay (P3): the object's live polygon with large draggable
  /// handles.
  void _drawVertexEditor(
    Canvas canvas,
    Offset Function(MapPoint point) project,
  ) {
    final pts = mission.editPolygon;
    if (pts.isEmpty) return;
    const accent = Color(0xFF1384E8);
    final closed = mission.editKind != 'channel';
    if (closed && pts.length >= 3) {
      _drawPolygon(
        canvas,
        pts,
        project,
        fill: accent.withValues(alpha: 0.12),
        stroke: accent,
        strokeWidth: 3,
      );
    } else if (pts.length >= 2) {
      _drawPolyline(canvas, pts, project, color: accent, strokeWidth: 3);
    }
    for (final v in pts) {
      final o = project(v);
      canvas.drawCircle(o, 9, Paint()..color = Colors.white);
      canvas.drawCircle(
        o,
        9,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      canvas.drawCircle(o, 3, Paint()..color = accent);
    }
  }

  /// In-progress hand-drawn polygon (P2): growing line + vertex dots, with a
  /// faint closing edge back to the start once it is a polygon.
  void _drawDraft(
    Canvas canvas,
    Offset Function(MapPoint point) project,
  ) {
    final pts = mission.draftPolygon;
    if (pts.isEmpty) return;
    const c = Color(0xFFE55353);
    if (pts.length >= 2) {
      _drawPolyline(canvas, pts, project, color: c, strokeWidth: 4);
    }
    if (pts.length >= 3) {
      final close = Path()
        ..moveTo(project(pts.last).dx, project(pts.last).dy)
        ..lineTo(project(pts.first).dx, project(pts.first).dy);
      canvas.drawPath(
        close,
        Paint()
          ..color = c.withValues(alpha: 0.45)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    for (final v in pts) {
      final o = project(v);
      canvas.drawCircle(o, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        o,
        5,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
    // Emphasise the start vertex.
    canvas.drawCircle(
      project(pts.first),
      8,
      Paint()
        ..color = c
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
  }

  /// Bright outline + vertex dots over a selected object.
  void _drawSelectionHighlight(
    Canvas canvas,
    List<MapPoint> points,
    Offset Function(MapPoint point) project, {
    required bool closed,
  }) {
    if (points.isEmpty) return;
    const accent = Color(0xFF1384E8);
    final path = Path()
      ..moveTo(project(points.first).dx, project(points.first).dy);
    for (final p in points.skip(1)) {
      final o = project(p);
      path.lineTo(o.dx, o.dy);
    }
    if (closed) path.close();
    canvas.drawPath(
      path,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 4,
    );
    for (final p in points) {
      final o = project(p);
      canvas.drawCircle(o, 5, Paint()..color = Colors.white);
      canvas.drawCircle(
        o,
        5,
        Paint()
          ..color = accent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  void _drawPolyline(
    Canvas canvas,
    List<MapPoint> points,
    Offset Function(MapPoint point) project, {
    required Color color,
    required double strokeWidth,
  }) {
    if (points.length < 2) return;
    final path = Path()
      ..moveTo(project(points.first).dx, project(points.first).dy);
    for (final point in points.skip(1)) {
      final offset = project(point);
      path.lineTo(offset.dx, offset.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..strokeWidth = strokeWidth,
    );
  }

  // ─── Robot markers ─────────────────────────────────────────────────────────

  void _drawRobotGlow(
    Canvas canvas,
    Offset center,
    Color color,
    double breathe,
  ) {
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.25 + 0.35 * breathe)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 5;
    canvas.drawCircle(center, 22 + 5 * breathe, glowPaint);
  }

  void _drawRobotWithColor(
    Canvas canvas,
    Offset center,
    double heading,
    Color color,
  ) {
    final shadowPaint = Paint()..color = const Color(0x33000000);
    canvas.drawCircle(center.translate(0, 3), 18, shadowPaint);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(heading + math.pi / 2);

    final body = Path()
      ..moveTo(0, -18)
      ..lineTo(14, 13)
      ..lineTo(0, 8)
      ..lineTo(-14, 13)
      ..close();

    canvas.drawPath(body, Paint()..color = color.withValues(alpha: 0.92));
    canvas.drawPath(
      body,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(
      Offset.zero,
      5,
      Paint()..color = Colors.white.withValues(alpha: 0.9),
    );
    canvas.restore();
  }

  void _drawRobotLabel(
    Canvas canvas,
    String label,
    Offset robotCenter,
    Color color,
  ) {
    final span = TextSpan(
      text: label,
      style: TextStyle(
        color: color,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    );
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: 64);
    final anchor = robotCenter.translate(-(painter.width / 2), 22);
    final bgRect = Rect.fromLTWH(
      anchor.dx - 5,
      anchor.dy - 2,
      painter.width + 10,
      painter.height + 4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(bgRect, const Radius.circular(8)),
      Paint()..color = Colors.white.withValues(alpha: 0.88),
    );
    painter.paint(canvas, anchor);
  }

  // Legacy single-robot marker (used when no fleet is provided)
  void _drawRobot(Canvas canvas, Offset center, double heading) {
    _drawRobotWithColor(canvas, center, heading, const Color(0xFF111827));
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.drawCircle(
      Offset.zero,
      5,
      Paint()..color = const Color(0xFF46D28B),
    );
    canvas.restore();
  }

  void _drawRecordingTrace(
    Canvas canvas,
    Offset Function(MapPoint point) project,
  ) {
    final trail = mission.recordTrail;
    if (trail.isEmpty) return;

    final type = mission.recordingType;
    final Color color;
    switch (type) {
      case RecordObjectType.zone:
        color = const Color(0xFF35B861);
      case RecordObjectType.risk:
        color = const Color(0xFFE55353);
      case RecordObjectType.channel:
        color = const Color(0xFF25AFC6);
      case null:
        color = const Color(0xFF222222);
    }
    final isArea =
        type == RecordObjectType.zone || type == RecordObjectType.risk;

    if (isArea && trail.length >= 3) {
      // Area types preview as a translucent closing polygon.
      _drawPolygon(
        canvas,
        trail,
        project,
        fill: color.withValues(alpha: 0.16),
        stroke: color,
        strokeWidth: 4,
      );
    } else if (trail.length >= 2) {
      _drawPolyline(canvas, trail, project, color: color, strokeWidth: 4);
    }

    // Start anchor.
    final start = project(trail.first);
    canvas.drawCircle(start, 6, Paint()..color = Colors.white);
    canvas.drawCircle(
      start,
      6,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );
    // Live head at the current robot position.
    canvas.drawCircle(project(trail.last), 4.5, Paint()..color = color);
  }

  // ─── Labels / scale ────────────────────────────────────────────────────────

  void _drawLabel(Canvas canvas, String text, Offset anchor, Color color) {
    final span = TextSpan(
      text: text,
      style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w700),
    );
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout(maxWidth: 96);
    final rect = Rect.fromLTWH(
      anchor.dx + 8,
      anchor.dy - 12,
      painter.width + 12,
      24,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(12)),
      Paint()..color = Colors.white.withValues(alpha: 0.86),
    );
    painter.paint(canvas, Offset(rect.left + 6, rect.top + 4));
  }

  void _drawScalePill(Canvas canvas, Rect mapRect) {
    final rect = Rect.fromLTWH(16, mapRect.bottom - 52, 88, 32);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(16)),
      Paint()..color = Colors.white.withValues(alpha: 0.88),
    );
    final span = TextSpan(
      text: 'Grid 5 m',
      style: const TextStyle(
        color: Color(0xFF455A64),
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    );
    final painter = TextPainter(text: span, textDirection: TextDirection.ltr)
      ..layout();
    painter.paint(canvas, Offset(rect.left + 14, rect.top + 8));
  }

  @override
  bool shouldRepaint(covariant _MissionMapPainter oldDelegate) => true;
}
