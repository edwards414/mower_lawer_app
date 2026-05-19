import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class MissionMapCanvas extends StatelessWidget {
  const MissionMapCanvas({
    super.key,
    required this.mission,
    required this.bottomInset,
    this.showScalePill = true,
  });

  final MissionMockProvider mission;
  final double bottomInset;
  final bool showScalePill;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MissionMapPainter(
        mission: mission,
        bottomInset: bottomInset,
        showScalePill: showScalePill,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _MissionMapPainter extends CustomPainter {
  _MissionMapPainter({
    required this.mission,
    required this.bottomInset,
    required this.showScalePill,
  });

  final MissionMockProvider mission;
  final double bottomInset;
  final bool showScalePill;

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
    final project = _projector(mapRect, _worldBounds());

    if (mission.freeSpaceLayer != null) {
      _drawGridLayer(canvas, mission.freeSpaceLayer!, project);
    }
    if (mission.channelMapLayer != null) {
      _drawGridLayer(canvas, mission.channelMapLayer!, project);
    }
    if (mission.riskMapLayer != null) {
      _drawGridLayer(canvas, mission.riskMapLayer!, project);
    }

    if (mission.layers.zones) {
      for (final zone in mission.zones) {
        if (zone.points.length < 3) {
          continue;
        }
        _drawPolygon(
          canvas,
          zone.points,
          project,
          fill: const Color(0x333BBF6A),
          stroke: const Color(0xFF2DA653),
          strokeWidth: 3,
        );
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
        _drawPolygon(
          canvas,
          risk.points,
          project,
          fill: const Color(0x33E55353),
          stroke: const Color(0xFFE04A4A),
          strokeWidth: 3,
        );
      }
    }

    if (mission.layers.channels) {
      for (final channel in mission.channels) {
        _drawPolyline(
          canvas,
          channel.points,
          project,
          color: const Color(0xFF25AFC6),
          strokeWidth: 5,
        );
      }
    }

    if (mission.layers.coverage) {
      for (var i = 0; i < mission.coverageRows.length; i += 1) {
        final isCurrent = i == mission.currentSegment - 1;
        _drawPolyline(
          canvas,
          mission.coverageRows[i],
          project,
          color: isCurrent ? const Color(0xFF147B58) : const Color(0x992A9470),
          strokeWidth: isCurrent ? 5 : 3,
        );
      }
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

    if (mission.shouldShowRobot) {
      _drawRobot(
        canvas,
        project(mission.robotPosition),
        mission.robotHeadingRad,
      );
    }
    if (showScalePill) {
      _drawScalePill(canvas, mapRect);
    }
  }

  Offset Function(MapPoint point) _projector(Rect mapRect, Rect worldBounds) {
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

    return (MapPoint point) {
      return Offset(
        offset.dx + (point.x - worldBounds.left) * scale,
        offset.dy + (point.y - worldBounds.top) * scale,
      );
    };
  }

  Rect _worldBounds() {
    final points = <MapPoint>[
      if (mission.shouldShowRobot) mission.robotPosition,
      for (final zone in mission.zones) ...zone.points,
      for (final risk in mission.riskZones) ...risk.points,
      for (final channel in mission.channels) ...channel.points,
      for (final row in mission.coverageRows) ...row,
      for (final segment in mission.invalidSegments) ...segment.points,
    ];
    if (points.length < 2) {
      return _fallbackWorldBounds;
    }
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

  void _drawPolygon(
    Canvas canvas,
    List<MapPoint> points,
    Offset Function(MapPoint point) project, {
    required Color fill,
    required Color stroke,
    required double strokeWidth,
  }) {
    if (points.length < 3) {
      return;
    }
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

  void _drawPolyline(
    Canvas canvas,
    List<MapPoint> points,
    Offset Function(MapPoint point) project, {
    required Color color,
    required double strokeWidth,
  }) {
    if (points.length < 2) {
      return;
    }
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

  void _drawRecordingTrace(
    Canvas canvas,
    Offset Function(MapPoint point) project,
  ) {
    final robot = mission.robotPosition;
    final points = [
      MapPoint(robot.x - 11, robot.y + 5),
      MapPoint(robot.x - 7, robot.y - 3),
      MapPoint(robot.x - 1, robot.y + 2),
      robot,
    ];
    _drawPolyline(
      canvas,
      points,
      project,
      color: const Color(0xFF222222),
      strokeWidth: 3,
    );
  }

  void _drawRobot(Canvas canvas, Offset center, double heading) {
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
    canvas.drawPath(body, Paint()..color = const Color(0xFF111827));
    canvas.drawPath(
      body,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    canvas.drawCircle(Offset.zero, 5, Paint()..color = const Color(0xFF46D28B));
    canvas.restore();
  }

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
  bool shouldRepaint(covariant _MissionMapPainter oldDelegate) {
    return true;
  }
}
