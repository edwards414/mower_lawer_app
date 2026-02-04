/// 路径覆盖方式
enum CoveragePattern {
  /// 平行线模式 (往返直线)
  parallel,
}

/// 割草设置
class MowingSettings {
  /// 割草方向 (0-360 度，0=北，90=东)
  final double direction;

  /// 割草时长 (分钟)
  final int durationMinutes;

  /// 路径覆盖方式
  final CoveragePattern coveragePattern;

  /// 路径间距 (cm)
  final double pathSpacingCm;

  const MowingSettings({
    this.direction = 0,
    this.durationMinutes = 60,
    this.coveragePattern = CoveragePattern.parallel,
    this.pathSpacingCm = 30,
  });

  MowingSettings copyWith({
    double? direction,
    int? durationMinutes,
    CoveragePattern? coveragePattern,
    double? pathSpacingCm,
  }) {
    return MowingSettings(
      direction: direction ?? this.direction,
      durationMinutes: durationMinutes ?? this.durationMinutes,
      coveragePattern: coveragePattern ?? this.coveragePattern,
      pathSpacingCm: pathSpacingCm ?? this.pathSpacingCm,
    );
  }
}
