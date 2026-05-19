import 'dart:ui' as ui;

enum MissionMode { objects, record, plan, run, logs }

enum RecordObjectType { zone, risk, channel }

enum CoveragePatternKind { zigzag, spiral }

enum NavMockStatus { idle, executing, paused, failed }

enum CameraFeed { front, rear }

class MapPoint {
  const MapPoint(this.x, this.y);

  final double x;
  final double y;

  static MapPoint lerp(MapPoint a, MapPoint b, double t) {
    return MapPoint(
      ui.lerpDouble(a.x, b.x, t) ?? a.x,
      ui.lerpDouble(a.y, b.y, t) ?? a.y,
    );
  }
}

class MissionZone {
  const MissionZone({
    required this.id,
    required this.name,
    required this.points,
    this.hasCoveragePath = false,
  });

  final int id;
  final String name;
  final List<MapPoint> points;
  final bool hasCoveragePath;
}

class ChannelPath {
  const ChannelPath({
    required this.id,
    required this.name,
    required this.points,
  });

  final int id;
  final String name;
  final List<MapPoint> points;
}

class InvalidSegment {
  const InvalidSegment({required this.id, required this.points});

  final int id;
  final List<MapPoint> points;
}

class MissionLogEntry {
  const MissionLogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final String time;
  final String level;
  final String message;
}

class MapGridLayer {
  MapGridLayer({
    required this.resolution,
    required this.width,
    required this.height,
    required this.originX,
    required this.originY,
    required this.image,
  });

  final double resolution;
  final int width;
  final int height;
  final double originX;
  final double originY;
  final ui.Image image;

  void dispose() => image.dispose();
}

class CameraFrame {
  CameraFrame({
    required this.feed,
    required this.topic,
    required this.encoding,
    required this.width,
    required this.height,
    required this.image,
    required this.receivedAt,
  });

  final CameraFeed feed;
  final String topic;
  final String encoding;
  final int width;
  final int height;
  final ui.Image image;
  final DateTime receivedAt;

  void dispose() => image.dispose();
}

class MissionLayerVisibility {
  const MissionLayerVisibility({
    this.zones = true,
    this.risks = true,
    this.channels = true,
    this.coverage = true,
    this.invalidSegments = true,
  });

  final bool zones;
  final bool risks;
  final bool channels;
  final bool coverage;
  final bool invalidSegments;

  MissionLayerVisibility copyWith({
    bool? zones,
    bool? risks,
    bool? channels,
    bool? coverage,
    bool? invalidSegments,
  }) {
    return MissionLayerVisibility(
      zones: zones ?? this.zones,
      risks: risks ?? this.risks,
      channels: channels ?? this.channels,
      coverage: coverage ?? this.coverage,
      invalidSegments: invalidSegments ?? this.invalidSegments,
    );
  }
}
