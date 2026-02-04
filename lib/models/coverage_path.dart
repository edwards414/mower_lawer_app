/// 路径点 (经纬度)
class PathPoint {
  final double latitude;
  final double longitude;

  const PathPoint(this.latitude, this.longitude);
}

/// 覆盖路径数据
class CoveragePath {
  /// 路径点列表 (计划路径)
  final List<PathPoint> pathPoints;

  /// 已覆盖区域多边形 (多个多边形，每个为闭合的 PathPoint 列表)
  final List<List<PathPoint>> coveredPolygons;

  /// 当前进度 (0.0 - 1.0)
  final double progress;

  const CoveragePath({
    this.pathPoints = const [],
    this.coveredPolygons = const [],
    this.progress = 0,
  });

  CoveragePath copyWith({
    List<PathPoint>? pathPoints,
    List<List<PathPoint>>? coveredPolygons,
    double? progress,
  }) {
    return CoveragePath(
      pathPoints: pathPoints ?? this.pathPoints,
      coveredPolygons: coveredPolygons ?? this.coveredPolygons,
      progress: progress ?? this.progress,
    );
  }
}
