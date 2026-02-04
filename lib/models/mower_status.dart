/// 割草机实时状态
class MowerStatus {
  /// 电量百分比 (0-100)
  final double batteryPercent;

  /// 纬度
  final double latitude;

  /// 经度
  final double longitude;

  /// 起始点纬度
  final double startLatitude;

  /// 起始点经度
  final double startLongitude;

  /// 当前速度 (m/s)
  final double speed;

  /// 工作状态
  final MowerWorkStatus workStatus;

  const MowerStatus({
    required this.batteryPercent,
    required this.latitude,
    required this.longitude,
    required this.startLatitude,
    required this.startLongitude,
    this.speed = 0,
    this.workStatus = MowerWorkStatus.idle,
  });

  MowerStatus copyWith({
    double? batteryPercent,
    double? latitude,
    double? longitude,
    double? startLatitude,
    double? startLongitude,
    double? speed,
    MowerWorkStatus? workStatus,
  }) {
    return MowerStatus(
      batteryPercent: batteryPercent ?? this.batteryPercent,
      latitude: latitude ?? this.latitude,
      longitude: longitude ?? this.longitude,
      startLatitude: startLatitude ?? this.startLatitude,
      startLongitude: startLongitude ?? this.startLongitude,
      speed: speed ?? this.speed,
      workStatus: workStatus ?? this.workStatus,
    );
  }
}

enum MowerWorkStatus {
  /// 待机
  idle,

  /// 工作中
  working,

  /// 充电中
  charging,
}
