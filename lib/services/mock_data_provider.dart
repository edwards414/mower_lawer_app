import 'dart:math';

import '../models/coverage_path.dart';
import '../models/mower_status.dart';
import '../models/mowing_settings.dart';
import '../utils/constants.dart';

/// Mock data provider for development and testing
class MockDataProvider {
  MowerStatus _status;
  CoveragePath _coveragePath;
  MowingSettings _settings;
  bool _isMowing;
  final Random _random = Random(42);

  MockDataProvider({
    MowerStatus? initialStatus,
    MowingSettings? initialSettings,
  }) : _status =
           initialStatus ??
           MowerStatus(
             batteryPercent: 85,
             latitude: AppConstants.defaultLatitude,
             longitude: AppConstants.defaultLongitude,
             startLatitude: AppConstants.defaultLatitude,
             startLongitude: AppConstants.defaultLongitude,
             speed: 0,
             workStatus: MowerWorkStatus.idle,
           ),
       _settings = initialSettings ?? const MowingSettings(),
       _coveragePath = CoveragePath(
         pathPoints: [
           PathPoint(
             AppConstants.defaultLatitude - 0.0003,
             AppConstants.defaultLongitude - 0.0003,
           ),
           PathPoint(
             AppConstants.defaultLatitude + 0.0003,
             AppConstants.defaultLongitude - 0.0003,
           ),
           PathPoint(
             AppConstants.defaultLatitude + 0.0003,
             AppConstants.defaultLongitude + 0.0003,
           ),
           PathPoint(
             AppConstants.defaultLatitude - 0.0003,
             AppConstants.defaultLongitude + 0.0003,
           ),
           PathPoint(
             AppConstants.defaultLatitude - 0.0003,
             AppConstants.defaultLongitude - 0.0003,
           ),
         ],
         coveredPolygons: [],
         progress: 0,
       ),
       _isMowing = false;

  MowerStatus getMowerStatus() {
    if (_isMowing) {
      // Simulate movement: slowly moving northeast
      final double dlat = 0.00002 * (0.5 + _random.nextDouble());
      final double dlon = 0.00003 * (0.5 + _random.nextDouble());
      double newBattery = (_status.batteryPercent - 0.02).clamp(0, 100);
      _status = _status.copyWith(
        latitude: _status.latitude + dlat,
        longitude: _status.longitude + dlon,
        batteryPercent: newBattery,
        speed: 0.5,
        workStatus: MowerWorkStatus.working,
      );
    } else {
      _status = _status.copyWith(speed: 0, workStatus: MowerWorkStatus.idle);
    }
    return _status;
  }

  CoveragePath getCoveragePath() {
    if (_isMowing && _coveragePath.progress < 1.0) {
      double newProgress = (_coveragePath.progress + 0.008).clamp(0, 1);
      // Covered area: rectangle expanding with progress
      final double size = 0.00015 * newProgress;
      final List<PathPoint> polygon = [
        PathPoint(_status.latitude + size, _status.longitude + size),
        PathPoint(_status.latitude + size, _status.longitude - size),
        PathPoint(_status.latitude - size, _status.longitude - size),
        PathPoint(_status.latitude - size, _status.longitude + size),
      ];
      // Planned path: simple rectangle
      final double pathSize = 0.0003;
      final List<PathPoint> pathPoints = [
        PathPoint(_status.latitude - pathSize, _status.longitude - pathSize),
        PathPoint(_status.latitude + pathSize, _status.longitude - pathSize),
        PathPoint(_status.latitude + pathSize, _status.longitude + pathSize),
        PathPoint(_status.latitude - pathSize, _status.longitude + pathSize),
        PathPoint(_status.latitude - pathSize, _status.longitude - pathSize),
      ];
      _coveragePath = CoveragePath(
        pathPoints: pathPoints,
        coveredPolygons: [polygon],
        progress: newProgress,
      );
    }
    return _coveragePath;
  }

  MowingSettings getSettings() => _settings;

  void updateSettings(MowingSettings settings) {
    _settings = settings;
  }

  void startMowing() {
    _isMowing = true;
  }

  void stopMowing() {
    _isMowing = false;
  }

  bool get isMowing => _isMowing;
}
