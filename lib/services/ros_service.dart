import '../models/coverage_path.dart';
import '../models/mower_status.dart';
import '../models/mowing_settings.dart';
import 'mock_data_provider.dart';

/// ROS HTTP API service
/// Initially using MockDataProvider, can switch to real HTTP requests later
class RosService {
  final MockDataProvider _mock;

  RosService({MockDataProvider? mock}) : _mock = mock ?? MockDataProvider();

  /// Get mower status
  Future<MowerStatus> getMowerStatus() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _mock.getMowerStatus();
  }

  /// Get coverage path data
  Future<CoveragePath> getCoveragePath() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return _mock.getCoveragePath();
  }

  /// Get current settings
  MowingSettings getSettings() => _mock.getSettings();

  /// Update mowing settings
  Future<void> updateSettings(MowingSettings settings) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _mock.updateSettings(settings);
  }

  /// Start mowing
  Future<void> startMowing() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _mock.startMowing();
  }

  /// Stop mowing
  Future<void> stopMowing() async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    _mock.stopMowing();
  }

  /// Is currently mowing
  bool get isMowing => _mock.isMowing;
}
