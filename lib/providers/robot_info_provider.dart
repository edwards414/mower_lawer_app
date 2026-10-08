import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/robot_info.dart';
import '../services/rosbridge_service.dart';

/// What is running on the robot, from the latched `/robot/info` topic, plus
/// the app-side compatibility verdict and the update/restart actions
/// (`/system/update`, `/system/restart`).
///
/// The robot re-publishes `/robot/info` about once a second; the app treats
/// it as stale after [staleAfter] so an unplugged robot does not keep
/// showing "compatible".
class RobotInfoProvider extends ChangeNotifier {
  RobotInfoProvider({
    required RosbridgeService rosbridge,
    this.staleAfter = const Duration(seconds: 10),
    Duration tick = const Duration(seconds: 2),
  }) : _rosbridge = rosbridge {
    _rosbridge.subscribe(
      infoTopic,
      type: 'std_msgs/msg/String',
      throttleRateMs: 500,
      qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
    );
    _messages = _rosbridge.messages.listen(_onMessage);
    _states = _rosbridge.states.listen(_onState);
    _timer = Timer.periodic(tick, (_) => _tick());
  }

  static const infoTopic = '/robot/info';
  static const updateService = '/system/update';
  static const restartService = '/system/restart';
  static const checkUpdateService = '/system/check_update';

  final RosbridgeService _rosbridge;
  final Duration staleAfter;
  StreamSubscription<RosbridgeTopicMessage>? _messages;
  StreamSubscription<RosbridgeConnectionState>? _states;
  Timer? _timer;

  RobotInfo? _info;
  DateTime? _receivedAt;
  bool _stale = true;
  bool _actionPending = false;
  String? _lastActionResult;
  bool _overrideCompatibility = false;
  bool _checkUnsupported = false;

  RobotInfo? get info => _info;
  DateTime? get receivedAt => _receivedAt;

  /// True until a fresh `/robot/info` arrives (and again once it stops).
  bool get stale => _stale;
  bool get actionPending => _actionPending;
  String? get lastActionResult => _lastActionResult;

  /// Operator chose to continue despite an API mismatch (bench use).
  bool get overrideCompatibility => _overrideCompatibility;

  /// The robot turned a check request down: its software predates the checker
  /// (new services do not bump `api_version`), so the card falls back to the
  /// plain update, which is also how it gets the checker. Cleared as soon as
  /// the robot reports a check result.
  bool get checkUpdateUnsupported => _checkUnsupported;

  RobotCompatibility get compatibility {
    final info = _info;
    if (info == null || _stale) return RobotCompatibility.unknown;
    return info.compatibility;
  }

  /// Mission controls should be blocked: the robot answered with an API
  /// version this app cannot drive safely, and nobody overrode it.
  bool get blocksOperation {
    if (_overrideCompatibility) return false;
    final c = compatibility;
    return c == RobotCompatibility.robotTooOld ||
        c == RobotCompatibility.appTooOld;
  }

  /// What the version card says: whether the robot has the latest version,
  /// from the robot's own check (`update.available`, API 2), or what stands in
  /// the way of saying so.
  VersionStatus get versionStatus {
    final info = this.info;
    if (info == null || stale) return VersionStatus.offline;
    // Whatever else is true, an update under way is what the robot is doing.
    if (info.update.inProgress) return VersionStatus.updating;
    switch (info.compatibility) {
      case RobotCompatibility.robotTooOld:
        return VersionStatus.robotTooOld;
      case RobotCompatibility.appTooOld:
        return VersionStatus.appTooOld;
      case RobotCompatibility.compatible:
      case RobotCompatibility.unknown:
        break;
    }
    final update = info.update;
    if (info.firmwareSyncError.isNotEmpty ||
        info.firmwareSyncAction == 'failed') {
      return VersionStatus.firmwareFailed;
    }
    if (update.available == true) return VersionStatus.newerAvailable;
    // Not at the version it was built for, though nothing newer is out.
    if (info.firmwareUpToDate == false) return VersionStatus.firmwareMismatch;
    // Nothing newer on the channel: an earlier failed update no longer matters.
    if (update.available == false && update.checkError.isEmpty) {
      return VersionStatus.upToDate;
    }
    if (update.failed) return VersionStatus.updateFailed;
    if (update.checkError.isNotEmpty) return VersionStatus.checkFailed;
    if (update.state == 'up_to_date') return VersionStatus.upToDate;
    return VersionStatus.notChecked;
  }

  void setOverrideCompatibility(bool value) {
    if (_overrideCompatibility == value) return;
    _overrideCompatibility = value;
    notifyListeners();
  }

  /// Ask the robot host to pull the current image tag and restart.
  Future<RosbridgeServiceResponse> requestUpdate() =>
      _call(updateService, '更新');

  Future<RosbridgeServiceResponse> requestRestart() =>
      _call(restartService, '重新啟動');

  /// Ask the robot to look the channel up now (no download, no restart; fine
  /// while it moves). The answer shows in `update.available` within seconds.
  Future<RosbridgeServiceResponse> requestCheckUpdate() async {
    final response = await _call(checkUpdateService, '檢查更新');
    if (!response.success && !_checkUnsupported) {
      _checkUnsupported = true;
      notifyListeners();
    }
    return response;
  }

  Future<RosbridgeServiceResponse> _call(String service, String label) async {
    if (_actionPending) {
      return RosbridgeServiceResponse(
        service: service,
        result: false,
        values: const {'success': false, 'message': '上一個請求還在處理'},
      );
    }
    _actionPending = true;
    _lastActionResult = null;
    notifyListeners();
    try {
      final response = await _rosbridge.callService(service);
      _lastActionResult = response.success
          ? '$label已送出：${response.message}'
          : '$label失敗：${response.message}';
      return response;
    } finally {
      _actionPending = false;
      notifyListeners();
    }
  }

  void _onMessage(RosbridgeTopicMessage event) {
    if (event.topic != infoTopic) return;
    final raw = event.message['data'];
    if (raw is! String) return;
    final parsed = RobotInfo.tryParse(raw);
    if (parsed == null) return;
    _info = parsed;
    if (parsed.update.available != null) _checkUnsupported = false;
    _receivedAt = DateTime.now();
    _stale = false;
    notifyListeners();
  }

  void _onState(RosbridgeConnectionState state) {
    if (state != RosbridgeConnectionState.connected && !_stale) {
      _stale = true;
      notifyListeners();
    }
  }

  void _tick() {
    final at = _receivedAt;
    if (at == null || _stale) return;
    if (DateTime.now().difference(at) > staleAfter) {
      _stale = true;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _messages?.cancel();
    _states?.cancel();
    _rosbridge.unsubscribe(infoTopic);
    super.dispose();
  }
}
