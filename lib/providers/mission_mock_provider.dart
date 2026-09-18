import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/geo_anchor.dart';
import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';
import '../models/site_info.dart';
import '../services/image_mission_processor.dart';
import '../services/rosbridge_service.dart';

class MissionMockProvider extends ChangeNotifier {
  static const _mockDataPreferenceKey = 'mock_data_enabled';
  static const manualVelocityTopic = '/app_joy_cmd';
  static const _manualCommandClockTopic = '/manual_command_clock';
  static const frontCameraTopic = '/front_depth_camera/image_raw';
  static const rearCameraTopic = '/back_camera/image_raw';
  static const _manualVelocityType = 'geometry_msgs/msg/TwistStamped';

  /// TCP port of the on-robot WebRTC (WHEP) media server (MediaMTX).
  static const _webrtcPort = 8889;

  /// Build-time override of the WHEP base URL (special builds only). By
  /// default the camera follows the paired robot's route, see [cameraBaseUrl].
  static const _configuredCameraBaseUrl = String.fromEnvironment(
    'CAMERA_BASE_URL',
    defaultValue: '',
  );

  MissionMockProvider({RosbridgeService? rosbridge})
    : _rosbridge = rosbridge ?? RosbridgeService(),
      _ownsRosbridge = rosbridge == null {
    _addLog('INFO', '等待 ROS 真實資料', notify: false);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_connectRosbridge());
  }

  final RosbridgeService _rosbridge;
  final bool _ownsRosbridge;
  Timer? _timer;
  Timer? _ambiguousCancelRetryTimer;
  StreamSubscription<RosbridgeTopicMessage>? _rosMessages;
  StreamSubscription<RosbridgeConnectionState>? _rosStates;
  int _tickCount = 0;
  DateTime? _recordingStartedAt;
  bool _hasLiveRobotPose = false;
  DateTime? _lastRobotPoseAt;
  bool _hasLoggedRosFailure = false;
  bool _hasLoggedManualDisconnected = false;
  bool _hasLoggedManualBlocked = false;
  int? _manualCommandClockSec;
  int? _manualCommandClockNanosec;
  String? _manualCommandSessionId;
  DateTime? _lastManualCommandClockAt;
  int? _lastManualCommandClockMicros;
  bool _manualSessionNeedsNeutral = false;
  bool _recordCommandPending = false;
  bool _externalRecordCancelAttempted = false;
  bool _navCommandPending = false;
  bool _cancelRequestInFlight = false;
  bool _cancelPending = false;
  bool _cancelRequestedDuringStart = false;
  bool _ambiguousStartCancelRequired = false;
  bool _navStatusCheckInFlight = false;
  int _navCommandEpoch = 0;
  int _connectionGeneration = 0;
  int _navStatusPollFailures = 0;
  bool _hasNavStatusSnapshot = false;
  bool _navigationAdmissionReady = false;
  String? _navigationAdmissionBlockReason;
  DateTime? _lastNavStatusAt;
  bool _connectionSettingsPending = false;
  bool _planningMutationPending = false;
  RecordObjectType? _pendingRecordSaveType;
  final Set<String> _loggedRejectedMapDatumSources = {};

  MissionMode selectedMode = MissionMode.objects;
  RecordObjectType? recordingType;
  // How the active recording was started: true = real ROS (*_start sent),
  // false = mock fallback. Latched at start so stopRecording matches it even
  // if the connection state changes mid-recording.
  bool _recordingViaRos = false;
  CoveragePatternKind coveragePattern = CoveragePatternKind.zigzag;
  // True once a custom image mission has been imported into the backend; used
  // to restore full-freespace coverage when switching back to zigzag/spiral.
  bool _imageMissionActive = false;
  // Satellite base-map toggle + the geo-anchor (from /adapter/map_datum) used
  // to place the local map-frame overlays on real-world satellite imagery.
  bool satelliteBaseMap = false;
  GeoAnchor? mapGeoAnchor;
  NavMockStatus navStatus = NavMockStatus.idle;
  MissionLayerVisibility layers = const MissionLayerVisibility();

  MapPoint robotPosition = const MapPoint(0, 0);
  double robotHeadingRad = 0.0;
  double coverageProgress = 0.0;
  double stripWidthM = 0.8;
  double waypointSpacingM = 0.2;
  double zigzagAngleDeg = 0.0;
  bool boundaryRing = false;
  int selectedZoneId = 0;
  int currentSegment = 0;
  int recordPointCount = 0;
  // Live breadcrumb of the robot's own pose captured while recording, used to
  // draw the in-progress shape on the map. The backend (path_record_node) does
  // the authoritative odom-sampled recording; this is just the visual trail.
  List<MapPoint> recordTrail = const [];
  bool freeSpaceReady = false;
  bool riskMapReady = false;
  bool channelMapReady = false;
  bool coverageReady = false;
  bool rosConnected = false;

  /// Whether the robot itself is alive (LWT-style), from the `/robot/online`
  /// heartbeat. Distinct from [rosConnected] (app<->rosbridge link): the robot
  /// can be offline while rosbridge is still up.
  bool robotOnline = false;
  DateTime? _lastHeartbeatAt;
  bool _lastHeartbeatData = false;
  static const Duration _heartbeatTimeout = Duration(seconds: 3);
  static const Duration _poseTimeout = Duration(seconds: 3);
  static const Duration _navStatusTimeout = Duration(seconds: 5);
  static const Duration _manualCommandClockTimeout = Duration(
    milliseconds: 200,
  );
  static const Duration _ambiguousCancelRetryInterval = Duration(seconds: 2);
  double? _batteryPercent;
  DateTime? _lastBatteryAt;
  bool _gpsFixValid = false;
  double? _gpsHorizontalSigmaM;
  DateTime? _lastGpsFixAt;
  int? _gpsSourceStampMicros;
  int? _lastGpsSourceStampMicros;
  double? _gpsLatitude;
  double? _gpsLongitude;
  static const Duration _telemetryTimeout = Duration(seconds: 10);
  static const Duration _gpsFixTimeout = Duration(milliseconds: 300);
  static const Duration _sensorMaxFutureSkew = Duration(milliseconds: 500);
  static const double maxGpsHorizontalSigmaM = 0.015;
  static const String _gpsFixTopic = String.fromEnvironment(
    'GPS_FIX_TOPIC',
    defaultValue: '/fix',
  );

  ImageMissionDraft? imageMissionDraft;

  MapGridLayer? freeSpaceLayer;
  MapGridLayer? riskMapLayer;
  MapGridLayer? channelMapLayer;
  CameraFrame? frontCameraFrame;
  CameraFrame? rearCameraFrame;
  String? frontCameraError;
  String? rearCameraError;

  bool _isDisposed = false;

  DateTime? _stripWidthEditedAt;
  DateTime? _waypointSpacingEditedAt;
  DateTime? _zigzagAngleEditedAt;
  DateTime? _coveragePatternEditedAt;
  DateTime? _boundaryRingEditedAt;
  static const _editGrace = Duration(seconds: 2);
  bool liveDataActive = false;
  bool mockDataEnabled = false;
  bool manualControlActive = false;

  List<MissionZone> zones = const [];
  List<MissionZone> riskZones = const [];
  List<ChannelPath> channels = const [];
  List<List<MapPoint>> coverageRows = const [];
  List<InvalidSegment> invalidSegments = const [];

  final List<MissionLogEntry> _logs = [];

  List<MissionLogEntry> get logs => List.unmodifiable(_logs);
  String get rosbridgeUrl => _rosbridge.url;
  String get robotIp => _rosbridge.robotIp;
  bool get shouldShowRobot => mockDataEnabled || _hasLiveRobotPose;
  bool get canControlRobot =>
      !mockDataEnabled &&
      !_connectionSettingsPending &&
      rosConnected &&
      robotOnline;
  bool get _navOperationActive =>
      _navCommandPending ||
      _cancelRequestInFlight ||
      _cancelPending ||
      navStatus == NavMockStatus.executing ||
      navStatus == NavMockStatus.paused;
  bool get canDriveManually =>
      canControlRobot &&
      _hasFreshManualCommandClock &&
      !_manualSessionNeedsNeutral &&
      hasFreshTerminalNavStatus &&
      !_navOperationActive &&
      !_recordCommandPending &&
      !_planningMutationPending;
  bool get canStartMission =>
      !_connectionSettingsPending &&
      !_planningMutationPending &&
      !_navOperationActive &&
      recordingType == null &&
      !_recordCommandPending &&
      !hasPendingRecordSave &&
      !manualControlActive &&
      zones.isNotEmpty &&
      (mockDataEnabled ||
          (canControlRobot &&
              hasFreshTerminalNavStatus &&
              _navigationAdmissionReady &&
              hasFreshRobotPose &&
              hasFreshGpsFix &&
              coverageReady &&
              zones.any(
                (zone) => zone.id == selectedZoneId && zone.hasCoveragePath,
              )));
  bool get navCommandPending => _navCommandPending;
  bool get cancelRequestInFlight => _cancelRequestInFlight;
  bool get cancelPending => _cancelPending;
  bool get recordCommandPending => _recordCommandPending;
  bool get hasNavStatusSnapshot => _hasNavStatusSnapshot;
  bool get hasFreshNavStatusSnapshot {
    final receivedAt = _lastNavStatusAt;
    return _hasNavStatusSnapshot &&
        _receiptIsFresh(receivedAt, _navStatusTimeout);
  }

  /// `failed` is terminal in the backend and accepts a subsequent goal; it is
  /// therefore safe for recovery/manual control even though the UI still
  /// presents it as an abnormal state.
  bool get hasFreshTerminalNavStatus =>
      hasFreshNavStatusSnapshot &&
      (navStatus == NavMockStatus.idle || navStatus == NavMockStatus.failed);

  bool get connectionSettingsPending => _connectionSettingsPending;
  bool get planningMutationPending => _planningMutationPending;
  RecordObjectType? get pendingRecordSaveType => _pendingRecordSaveType;
  bool get hasPendingRecordSave => _pendingRecordSaveType != null;
  String get pendingRecordSaveTitle {
    final type = _pendingRecordSaveType;
    return type == null ? '' : _recordTypeName(type);
  }

  bool get canMutatePlanning =>
      !_connectionSettingsPending &&
      !_planningMutationPending &&
      !_navOperationActive &&
      recordingType == null &&
      !_recordCommandPending &&
      !manualControlActive &&
      !hasPendingRecordSave &&
      (mockDataEnabled || (rosConnected && hasFreshTerminalNavStatus));

  double? get batteryPercent {
    if (mockDataEnabled) {
      return 85.0;
    }
    final receivedAt = _lastBatteryAt;
    if (!_receiptIsFresh(receivedAt, _telemetryTimeout)) {
      return null;
    }
    return _batteryPercent;
  }

  bool get hasFreshGpsFix {
    if (mockDataEnabled) {
      return true;
    }
    final receivedAt = _lastGpsFixAt;
    return _gpsFixValid &&
        _receiptIsFresh(receivedAt, _gpsFixTimeout) &&
        _robotSourceStampIsFresh(_gpsSourceStampMicros, _gpsFixTimeout);
  }

  bool get _hasFreshManualCommandClock {
    final receivedAt = _lastManualCommandClockAt;
    return _manualCommandClockSec != null &&
        _manualCommandClockNanosec != null &&
        _manualCommandSessionId != null &&
        _receiptIsFresh(receivedAt, _manualCommandClockTimeout);
  }

  bool _robotSourceStampIsFresh(int? sourceMicros, Duration timeout) {
    final robotClockMicros = _lastManualCommandClockMicros;
    if (sourceMicros == null ||
        robotClockMicros == null ||
        !_hasFreshManualCommandClock) {
      return false;
    }
    final ageMicros = robotClockMicros - sourceMicros;
    return ageMicros >= -_sensorMaxFutureSkew.inMicroseconds &&
        ageMicros <= timeout.inMicroseconds;
  }

  double? get gpsLatitude => hasFreshGpsFix ? _gpsLatitude : null;
  double? get gpsLongitude => hasFreshGpsFix ? _gpsLongitude : null;
  double? get gpsHorizontalSigmaM =>
      hasFreshGpsFix ? _gpsHorizontalSigmaM : null;

  /// Whether a real `/adapter/robot_pose` has been received (the default robot
  /// has a live pose). Consumed by [RobotFleetProvider.syncFromMission].
  bool get hasLiveRobotPose => _hasLiveRobotPose;
  bool get hasFreshRobotPose =>
      _hasLiveRobotPose && _receiptIsFresh(_lastRobotPoseAt, _poseTimeout);

  CameraFrame? cameraFrame(CameraFeed feed) {
    return switch (feed) {
      CameraFeed.front => frontCameraFrame,
      CameraFeed.rear => rearCameraFrame,
    };
  }

  String? cameraError(CameraFeed feed) {
    return switch (feed) {
      CameraFeed.front => frontCameraError,
      CameraFeed.rear => rearCameraError,
    };
  }

  String cameraTopic(CameraFeed feed) {
    return switch (feed) {
      CameraFeed.front => frontCameraTopic,
      CameraFeed.rear => rearCameraTopic,
    };
  }

  /// WHEP base URL for the current connection: a build-time override, else
  /// what the robot registry set for the active route (QR `c` or the LAN
  /// MediaMTX), else the rosbridge host (legacy tunnel / dev). Through the
  /// fleet relay there is no video path yet, so this is '' there.
  String get cameraBaseUrl {
    final configured = _configuredCameraBaseUrl.trim();
    if (configured.isNotEmpty) {
      return configured.replaceFirst(RegExp(r'/+$'), '');
    }
    final fromRoute = _rosbridge.cameraBaseUrl;
    if (fromRoute.isNotEmpty) {
      return fromRoute;
    }
    if (_rosbridge.framed) {
      return '';
    }
    final ip = robotIp;
    if (ip.isEmpty) {
      return '';
    }
    return 'http://$ip:$_webrtcPort';
  }

  /// Why [whepUrl] is empty, for the camera placeholder.
  String get cameraUnavailableReason => _rosbridge.framed
      ? '遠端連線暫不支援影像，請在同一個 Wi-Fi 下使用'
      : '尚未設定機器人 IP';

  /// WHEP endpoint for a camera feed, or empty when the robot IP is unknown.
  /// The path name (`front`/`rear`) must match the MediaMTX `paths` config.
  String whepUrl(CameraFeed feed) {
    final base = cameraBaseUrl;
    if (base.isEmpty) {
      return '';
    }
    final path = switch (feed) {
      CameraFeed.front => 'front',
      CameraFeed.rear => 'rear',
    };
    return '$base/$path/whep';
  }

  Duration get recordingElapsed {
    final startedAt = _recordingStartedAt;
    if (startedAt == null) {
      return Duration.zero;
    }
    return DateTime.now().difference(startedAt);
  }

  String get recordingTitle {
    switch (recordingType) {
      case RecordObjectType.zone:
        return '工作區記錄中';
      case RecordObjectType.risk:
        return '禁入區記錄中';
      case RecordObjectType.channel:
        return '通道記錄中';
      case null:
        return '選擇要記錄的物件';
    }
  }

  Future<void> _connectRosbridge() async {
    await _rosbridge.loadSavedRobotIp();
    await _loadMockDataPreference();
    const markerTopics = [
      '/adapter/marker_layers/zones',
      '/adapter/marker_layers/risk_zones',
      '/adapter/marker_layers/channels',
      '/adapter/marker_layers/coverage_path',
      '/adapter/marker_layers/invalid_segments',
      '/adapter/marker_layers/connectors',
      '/adapter/coverage_settings',
      '/adapter/zone_summaries',
    ];
    const mapTopics = [
      '/adapter/map_layers/map_grid',
      '/adapter/map_layers/free_space_inflated',
      '/adapter/map_layers/risk_map_inflated',
      '/adapter/map_layers/chennal_map_inflated',
    ];

    for (final topic in markerTopics) {
      _rosbridge.subscribe(
        topic,
        type: 'std_msgs/msg/String',
        throttleRateMs: 100,
        qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
      );
    }
    for (final topic in mapTopics) {
      _rosbridge.subscribe(
        topic,
        type: 'std_msgs/msg/String',
        throttleRateMs: 100,
        qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
      );
    }
    _rosbridge.subscribe(
      '/adapter/map_datum',
      type: 'std_msgs/msg/String',
      throttleRateMs: 1000,
      qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
    );
    _rosbridge.subscribe(
      '/site_list',
      type: 'std_msgs/msg/String',
      throttleRateMs: 200,
      qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
    );
    _rosbridge.subscribe(
      '/adapter/robot_pose',
      type: 'geometry_msgs/msg/PoseStamped',
      throttleRateMs: 100,
    );
    _rosbridge.subscribe(
      '/robot/online',
      type: 'std_msgs/msg/Bool',
      throttleRateMs: 200,
      qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
    );
    _rosbridge.subscribe(
      '/battery_state',
      type: 'sensor_msgs/msg/BatteryState',
      throttleRateMs: 1000,
      qos: const {'durability': 'volatile', 'reliability': 'best_effort'},
    );
    _rosbridge.subscribe(
      _gpsFixTopic,
      type: 'sensor_msgs/msg/NavSatFix',
      throttleRateMs: 100,
      qos: const {'durability': 'volatile', 'reliability': 'best_effort'},
    );
    _rosbridge.subscribe(
      _manualCommandClockTopic,
      type: 'std_msgs/msg/Header',
      qos: const {'durability': 'volatile', 'reliability': 'reliable'},
    );
    // Camera feeds are delivered over WebRTC (WHEP) from the on-robot media
    // server, not as raw sensor_msgs/Image over rosbridge. See [whepUrl].

    _rosMessages = _rosbridge.messages.listen(_handleRosMessage);
    _rosStates = _rosbridge.states.listen(_handleRosState);
    _rosbridge.connect();
    notifyListeners();
  }

  Future<void> _loadMockDataPreference() async {
    final prefs = await SharedPreferences.getInstance();
    mockDataEnabled = prefs.getBool(_mockDataPreferenceKey) ?? false;
    if (mockDataEnabled) {
      _restoreDemoData();
      _addLog('INFO', 'Demo 模式已由使用者設定開啟', notify: false);
    } else if (!liveDataActive) {
      _clearMissionData();
      _addLog('INFO', 'Demo 模式關閉，等待 ROS 真實資料', notify: false);
    }
  }

  Future<String?> updateRobotIp(String value) async {
    final error = RosbridgeService.validateRobotIp(value);
    if (error != null) {
      return error;
    }
    if (value.trim() == _rosbridge.robotIp) {
      return null;
    }
    if (_connectionSettingsPending ||
        _planningMutationPending ||
        _navOperationActive ||
        recordingType != null ||
        _recordCommandPending ||
        manualControlActive ||
        hasPendingRecordSave) {
      return '任務、記錄或手動控制進行中，不能切換機器人連線';
    }
    _connectionSettingsPending = true;
    notifyListeners();
    try {
      await _rosbridge.setRobotIp(value);
      _connectionGeneration += 1;
      rosConnected = false;
      liveDataActive = false;
      _clearLiveReadiness();
      _clearCameraFrames();
      if (mockDataEnabled) {
        _clearMissionData();
        _restoreDemoData();
      } else {
        _clearMissionData();
      }
      _addLog('INFO', '機器人 IP 已設定為 ${_rosbridge.robotIp}');
      return null;
    } catch (error) {
      _addLog('ERROR', '設定機器人 IP 失敗: $error');
      return '設定機器人 IP 失敗，請稍後重試';
    } finally {
      _connectionSettingsPending = false;
      notifyListeners();
    }
  }

  Future<void> setMockDataEnabled(bool enabled) async {
    if (enabled == mockDataEnabled) {
      return;
    }
    if (_connectionSettingsPending ||
        _planningMutationPending ||
        _navOperationActive ||
        recordingType != null ||
        _recordCommandPending ||
        manualControlActive ||
        hasPendingRecordSave) {
      _addLog('WARN', '任務、記錄或手動控制進行中，不能切換 Demo 模式');
      return;
    }
    _connectionSettingsPending = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_mockDataPreferenceKey, enabled);
      mockDataEnabled = enabled;
      _connectionGeneration += 1;
      liveDataActive = false;
      _clearLiveReadiness();
      if (enabled) {
        _clearMissionData();
        _restoreDemoData();
      } else {
        _clearMissionData();
        // Re-subscribe so transient-local live layers are replayed after
        // leaving the explicitly isolated demo mode.
        if (rosConnected) {
          _rosbridge.reconnect();
        }
      }

      _addLog(
        'INFO',
        enabled ? 'Demo 模式已手動開啟' : 'Demo 模式已關閉，等待 ROS 真實資料',
        notify: false,
      );
    } catch (error) {
      _addLog('ERROR', '切換 Demo 模式失敗: $error', notify: false);
    } finally {
      _connectionSettingsPending = false;
      notifyListeners();
    }
  }

  void _handleRosState(RosbridgeConnectionState state) {
    final connected = state == RosbridgeConnectionState.connected;
    if (rosConnected == connected) {
      if (!connected && !_hasLoggedRosFailure) {
        _hasLoggedRosFailure = true;
        _addLog(
          'WARN',
          mockDataEnabled ? 'rosbridge 尚未連線，使用 demo 資料' : 'rosbridge 尚未連線',
        );
      }
      return;
    }
    rosConnected = connected;
    if (connected) {
      _hasLoggedRosFailure = false;
      _hasLoggedManualDisconnected = false;
      _addLog('SUCCESS', 'rosbridge 已連線');
      if (_ambiguousStartCancelRequired) {
        // A one-shot retry may have fired while disconnected. Re-arm it as
        // soon as the transport returns instead of leaving an uncertain mower
        // permanently without further stop attempts.
        _scheduleAmbiguousCancelRetry();
        unawaited(_pollNavStatus());
      }
    } else {
      stopManualControl();
      _hasNavStatusSnapshot = false;
      _navigationAdmissionReady = false;
      _navigationAdmissionBlockReason = null;
      _lastNavStatusAt = null;
      _lastHeartbeatAt = null;
      _lastHeartbeatData = false;
      _lastRobotPoseAt = null;
      _lastGpsFixAt = null;
      _clearManualCommandClock();
      _addLog('WARN', 'rosbridge 連線中斷，保留最後資料');
    }
    _updateRobotOnline();
    notifyListeners();
  }

  /// Recompute [robotOnline] from the last `/robot/online` heartbeat. Online
  /// only when the app is linked to rosbridge AND a `true` heartbeat arrived
  /// within [_heartbeatTimeout] (so a stopped/dead robot — whose heartbeat
  /// either flips false or stops entirely — is detected). Called on each
  /// heartbeat, on connection changes, and every tick (for the timeout).
  void _updateRobotOnline() {
    final last = _lastHeartbeatAt;
    final fresh = _receiptIsFresh(last, _heartbeatTimeout);
    final next = rosConnected && fresh && _lastHeartbeatData;
    if (next != robotOnline) {
      final wasOnline = robotOnline;
      robotOnline = next;
      if (wasOnline && !next && manualControlActive) {
        stopManualControl();
      }
      _addLog(next ? 'SUCCESS' : 'WARN', next ? '機器人上線' : '機器人離線');
      if (wasOnline &&
          !next &&
          !mockDataEnabled &&
          navStatus == NavMockStatus.executing) {
        navStatus = NavMockStatus.paused;
        _addLog('ERROR', '導航狀態中斷：機器人 heartbeat 已逾時');
      }
      if (next && !mockDataEnabled) {
        unawaited(_pollNavStatus());
      }
      notifyListeners();
    }
  }

  void _handleRosMessage(RosbridgeTopicMessage event) {
    try {
      // Demo is an explicit, isolated data source. Keep the socket connected
      // for a quick return to live mode, but do not retain live telemetry or
      // mission layers while demo is selected.
      if (mockDataEnabled) {
        return;
      }
      switch (event.topic) {
        case '/robot/online':
          _lastHeartbeatAt = DateTime.now();
          _lastHeartbeatData = event.message['data'] == true;
          _updateRobotOnline();
          break;
        case '/battery_state':
          _applyBatteryState(event.message);
          break;
        case _gpsFixTopic:
          _applyGpsFix(event.message);
          break;
        case _manualCommandClockTopic:
          _applyManualCommandClock(event.message);
          break;
        default:
          _handleLiveMissionMessage(event);
      }
    } catch (error) {
      _addLog('ERROR', 'rosbridge 資料解析失敗: $error');
    }
  }

  void _handleLiveMissionMessage(RosbridgeTopicMessage event) {
    switch (event.topic) {
      case '/adapter/robot_pose':
        _applyRobotPose(event.message);
        break;
      case '/adapter/coverage_settings':
        final dto = _decodeStringMessage(event.message);
        if (dto is Map<String, dynamic>) {
          _applyCoverageSettings(dto);
        }
        break;
      case '/adapter/zone_summaries':
        final dto = _decodeStringMessage(event.message);
        if (dto is List) {
          _applyZoneSummaries(dto);
        }
        break;
      case '/adapter/map_datum':
        final dto = _decodeStringMessage(event.message);
        if (dto is Map<String, dynamic>) {
          final anchor = GeoAnchor.fromJson(dto);
          if (anchor != null) {
            if (!anchor.isTrustedForLive) {
              if (_loggedRejectedMapDatumSources.add(anchor.source)) {
                _addLog('WARN', '忽略不可信的 map datum（source=${anchor.source}）');
              }
              return;
            }
            _loggedRejectedMapDatumSources.clear();
            mapGeoAnchor = anchor;
            notifyListeners();
          }
        }
        break;
      case '/site_list':
        final dto = _decodeStringMessage(event.message);
        if (dto is Map<String, dynamic>) {
          _applySiteList(dto);
        }
        break;
      default:
        final dto = _decodeStringMessage(event.message);
        if (dto is Map<String, dynamic>) {
          final name = dto['name']?.toString();
          if (dto.containsKey('markers')) {
            _applyMarkerLayer(name, dto);
          } else if (dto['type'] == 'occupancy_grid') {
            _applyMapLayer(name, dto);
          }
        }
    }
  }

  void _applyBatteryState(Map<String, dynamic> message) {
    final raw = _asDouble(message['percentage']);
    if (raw == null || !raw.isFinite || raw < 0) {
      return;
    }
    _batteryPercent = (raw <= 1.0 ? raw * 100.0 : raw)
        .clamp(0.0, 100.0)
        .toDouble();
    _lastBatteryAt = DateTime.now();
    notifyListeners();
  }

  void _applyGpsFix(Map<String, dynamic> message) {
    final header = message['header'];
    final sourceStampMicros = header is Map
        ? _rosStampMicroseconds(header['stamp'])
        : null;
    final robotClockMicros = _hasFreshManualCommandClock
        ? _lastManualCommandClockMicros
        : null;
    if (sourceStampMicros != null) {
      if (robotClockMicros == null) {
        // Without a fresh robot clock, the source timestamp is untrusted. Do
        // not let it poison the replay high-water mark.
        _clearGpsFix();
        _lastGpsFixAt = DateTime.now();
        notifyListeners();
        return;
      }
      if (sourceStampMicros >
          robotClockMicros + _sensorMaxFutureSkew.inMicroseconds) {
        // Mirror the drivetrain guard: reject a far-future value, but advance
        // only to trusted robot time so a valid later sample can recover.
        if (_lastGpsSourceStampMicros == null ||
            robotClockMicros > _lastGpsSourceStampMicros!) {
          _lastGpsSourceStampMicros = robotClockMicros;
        }
        _clearGpsFix();
        _lastGpsFixAt = DateTime.now();
        notifyListeners();
        return;
      }
    }
    final sourceStampMovesForward =
        sourceStampMicros != null &&
        (_lastGpsSourceStampMicros == null ||
            sourceStampMicros > _lastGpsSourceStampMicros!);
    if (sourceStampMicros != null && !sourceStampMovesForward) {
      // Ignore a replay without refreshing receipt freshness or replacing the
      // newest fix. Missing timestamps still fail closed below.
      return;
    }
    if (sourceStampMovesForward) {
      // Advance the high-water mark even for a no-fix/invalid sample. An older
      // previously-valid frame must never revive readiness after a fault.
      _lastGpsSourceStampMicros = sourceStampMicros;
    }
    final status = message['status'];
    final code = status is Map ? _asEnumInt(status['status']) : null;
    final latitude = _asDouble(message['latitude']);
    final longitude = _asDouble(message['longitude']);
    final covarianceType = _asEnumInt(message['position_covariance_type']);
    final horizontalSigma = _horizontalCovarianceSigma(
      message['position_covariance'],
    );
    _gpsFixValid =
        sourceStampMovesForward &&
        _robotSourceStampIsFresh(sourceStampMicros, _gpsFixTimeout) &&
        code != null &&
        code >= 0 &&
        code <= 2 &&
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite &&
        latitude >= -90 &&
        latitude <= 90 &&
        longitude >= -180 &&
        longitude <= 180 &&
        !(latitude.abs() < 1e-9 && longitude.abs() < 1e-9) &&
        covarianceType != null &&
        covarianceType >= 1 &&
        covarianceType <= 3 &&
        horizontalSigma != null &&
        horizontalSigma <= maxGpsHorizontalSigmaM;
    _gpsLatitude = _gpsFixValid ? latitude : null;
    _gpsLongitude = _gpsFixValid ? longitude : null;
    _gpsHorizontalSigmaM = _gpsFixValid ? horizontalSigma : null;
    _gpsSourceStampMicros = _gpsFixValid ? sourceStampMicros : null;
    _lastGpsFixAt = DateTime.now();
    notifyListeners();
  }

  void _applyManualCommandClock(Map<String, dynamic> message) {
    final stamp = message['stamp'];
    final sec = stamp is Map ? _asEnumInt(stamp['sec']) : null;
    final nanosec = stamp is Map ? _asEnumInt(stamp['nanosec']) : null;
    final incomingMicros = _rosStampMicroseconds(stamp);
    final sessionId = message['frame_id']?.toString();
    final valid =
        incomingMicros != null &&
        sec != null &&
        nanosec != null &&
        sessionId != null &&
        sessionId.startsWith('manual-session-v1:') &&
        sessionId.length > 'manual-session-v1:'.length;
    if (!valid) {
      return;
    }
    final wasReady = _hasFreshManualCommandClock;
    final sessionChanged = sessionId != _manualCommandSessionId;
    final previousClockMicros = _lastManualCommandClockMicros;
    if (!sessionChanged &&
        _lastManualCommandClockMicros != null &&
        incomingMicros <= _lastManualCommandClockMicros!) {
      // A duplicated or backwards robot clock is replay, not fresh authority.
      // In particular, never refresh the 200 ms receipt gate for it.
      return;
    }
    final gpsWasFresh = hasFreshGpsFix;
    if (sessionChanged) {
      // Every guard restart invalidates current readiness. Reset the replay
      // barrier only when ROS time actually moved to an earlier clock domain;
      // a normal same-domain restart must retain no-fix/invalid barriers.
      _clearGpsFix(
        resetSourceHighWater:
            previousClockMicros != null && incomingMicros < previousClockMicros,
      );
    }
    if (sessionChanged && manualControlActive) {
      // Keep canDriveManually false until the overlay observes this rollover,
      // sends zero, and clears its joystick gesture. A guard restart must not
      // silently re-arm a still-held touch from the previous session.
      _manualSessionNeedsNeutral = true;
      manualControlActive = false;
    }
    _manualCommandClockSec = sec;
    _manualCommandClockNanosec = nanosec;
    _manualCommandSessionId = sessionId;
    _lastManualCommandClockMicros = incomingMicros;
    _lastManualCommandClockAt = DateTime.now();
    if (!wasReady || sessionChanged || gpsWasFresh != hasFreshGpsFix) {
      notifyListeners();
    }
  }

  void _clearManualCommandClock() {
    _manualCommandClockSec = null;
    _manualCommandClockNanosec = null;
    _manualCommandSessionId = null;
    _lastManualCommandClockAt = null;
    _lastManualCommandClockMicros = null;
    _manualSessionNeedsNeutral = false;
  }

  void _clearGpsFix({bool resetSourceHighWater = false}) {
    _gpsFixValid = false;
    _gpsHorizontalSigmaM = null;
    _lastGpsFixAt = null;
    _gpsSourceStampMicros = null;
    _gpsLatitude = null;
    _gpsLongitude = null;
    if (resetSourceHighWater) {
      _lastGpsSourceStampMicros = null;
    }
  }

  dynamic _decodeStringMessage(Map<String, dynamic> message) {
    final data = message['data'];
    if (data is! String || data.isEmpty) {
      return null;
    }
    return jsonDecode(data);
  }

  void _applyMarkerLayer(String? name, Map<String, dynamic> dto) {
    final rawMarkers = dto['markers'];
    if (rawMarkers is! List) {
      return;
    }
    final markers = rawMarkers.whereType<Map>().map((m) {
      return m.cast<String, dynamic>();
    }).toList();

    switch (name) {
      case 'zones':
        zones = _buildZonesFromMarkers(markers);
        _ensureSelectedZone();
        break;
      case 'risk_zones':
        riskZones = _buildRiskZonesFromMarkers(markers);
        break;
      case 'channels':
        channels = _buildChannelsFromMarkers(markers);
        channelMapReady = channels.isNotEmpty || channelMapReady;
        break;
      case 'coverage_path':
        coverageRows = markers
            .where((marker) => marker['type'] == 'line_strip')
            .map(_markerPoints)
            .where((points) => points.length >= 2)
            .toList();
        coverageReady = coverageRows.isNotEmpty;
        currentSegment = coverageRows.isEmpty
            ? 0
            : currentSegment.clamp(1, coverageRows.length).toInt();
        coverageProgress = coverageRows.isEmpty ? 0.0 : coverageProgress;
        break;
      case 'invalid_segments':
        invalidSegments = _buildInvalidSegmentsFromMarkers(markers);
        break;
    }

    liveDataActive = true;
    notifyListeners();
  }

  void _applyMapLayer(String? name, Map<String, dynamic> dto) {
    liveDataActive = true;
    notifyListeners();
    unawaited(_decodeAndStoreMapLayer(name, dto));
  }

  Future<void> _decodeAndStoreMapLayer(
    String? name,
    Map<String, dynamic> dto,
  ) async {
    final layer = await _decodeMapLayer(name, dto);
    if (_isDisposed) {
      layer?.dispose();
      return;
    }
    if (layer == null) return;
    switch (name) {
      case 'free_space_inflated':
        freeSpaceLayer?.dispose();
        freeSpaceLayer = layer;
        freeSpaceReady = true;
        break;
      case 'risk_map_inflated':
        riskMapLayer?.dispose();
        riskMapLayer = layer;
        riskMapReady = true;
        break;
      case 'chennal_map_inflated':
        channelMapLayer?.dispose();
        channelMapLayer = layer;
        channelMapReady = true;
        break;
    }
    liveDataActive = true;
    notifyListeners();
  }

  static Future<MapGridLayer?> _decodeMapLayer(
    String? name,
    Map<String, dynamic> dto,
  ) async {
    try {
      final encoded = dto['data'] as String?;
      final width = dto['width'] as int?;
      final height = dto['height'] as int?;
      final resolution = (dto['resolution'] as num?)?.toDouble();
      final originMap = dto['origin'] as Map?;
      if (encoded == null ||
          width == null ||
          height == null ||
          resolution == null ||
          originMap == null) {
        return null;
      }
      final originX = (originMap['x'] as num?)?.toDouble() ?? 0.0;
      final originY = (originMap['y'] as num?)?.toDouble() ?? 0.0;
      final bytes = base64Decode(encoded);

      // Pre-compute RGBA for free (v=0) and occupied (v=100) cells per layer.
      // v=255 (unknown, was int8 -1) stays transparent.
      int fR = 0, fG = 0, fB = 0, fA = 0;
      int oR = 0, oG = 0, oB = 0, oA = 0;
      switch (name) {
        case 'free_space_inflated':
          fR = 46;
          fG = 190;
          fB = 90;
          fA = 22; // subtle green = navigable
          oR = 60;
          oG = 60;
          oB = 60;
          oA = 90; // gray = inflated boundary
          break;
        case 'risk_map_inflated':
          // free cells are safe → transparent
          oR = 220;
          oG = 48;
          oB = 48;
          oA = 120; // red = risk zone
          break;
        case 'chennal_map_inflated':
          fR = 30;
          fG = 155;
          fB = 195;
          fA = 50; // cyan = channel
          // occupied cells = outside channel → transparent
          break;
      }

      final pixels = Uint8List(width * height * 4);
      final total = bytes.length < width * height
          ? bytes.length
          : width * height;
      for (var i = 0; i < total; i++) {
        final v = bytes[i];
        final idx = i * 4;
        if (v == 0) {
          pixels[idx] = fR;
          pixels[idx + 1] = fG;
          pixels[idx + 2] = fB;
          pixels[idx + 3] = fA;
        } else if (v == 100) {
          pixels[idx] = oR;
          pixels[idx + 1] = oG;
          pixels[idx + 2] = oB;
          pixels[idx + 3] = oA;
        }
        // v == 255 (unknown) → stays 0 (transparent)
      }

      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        pixels,
        width,
        height,
        ui.PixelFormat.rgba8888,
        completer.complete,
      );
      final image = await completer.future;
      return MapGridLayer(
        resolution: resolution,
        width: width,
        height: height,
        originX: originX,
        originY: originY,
        image: image,
      );
    } catch (_) {
      return null;
    }
  }

  void _applyZoneSummaries(List<dynamic> summaries) {
    final coverageByZone = <int, bool>{};
    for (final item in summaries.whereType<Map>()) {
      final zoneId = _asInt(item['zoneId']);
      if (zoneId == null) {
        continue;
      }
      coverageByZone[zoneId] = item['hasCoveragePath'] == true;
    }
    _zoneCoverageById
      ..clear()
      ..addAll(coverageByZone);
    zones = zones
        .map(
          (zone) => MissionZone(
            id: zone.id,
            name: zone.name,
            points: zone.points,
            hasCoveragePath: _zoneCoverageById[zone.id] ?? zone.hasCoveragePath,
          ),
        )
        .toList();
    _ensureSelectedZone();
    liveDataActive = true;
    notifyListeners();
  }

  void _applyCoverageSettings(Map<String, dynamic> dto) {
    final now = DateTime.now();
    if (_stripWidthEditedAt == null ||
        now.difference(_stripWidthEditedAt!) > _editGrace) {
      stripWidthM = _asDouble(dto['stripWidthM']) ?? stripWidthM;
    }
    if (_waypointSpacingEditedAt == null ||
        now.difference(_waypointSpacingEditedAt!) > _editGrace) {
      waypointSpacingM = _asDouble(dto['waypointSpacingM']) ?? waypointSpacingM;
    }
    if (_zigzagAngleEditedAt == null ||
        now.difference(_zigzagAngleEditedAt!) > _editGrace) {
      zigzagAngleDeg = _asDouble(dto['zigzagAngleDeg']) ?? zigzagAngleDeg;
    }
    if (_coveragePatternEditedAt == null ||
        now.difference(_coveragePatternEditedAt!) > _editGrace) {
      final pattern = dto['coveragePattern']?.toString();
      if (pattern == 'spiral') {
        coveragePattern = CoveragePatternKind.spiral;
      } else if (pattern == 'zigzag') {
        coveragePattern = CoveragePatternKind.zigzag;
      }
    }
    if (_boundaryRingEditedAt == null ||
        now.difference(_boundaryRingEditedAt!) > _editGrace) {
      final ring = dto['boundaryRing'];
      if (ring is bool) {
        boundaryRing = ring;
      }
    }
    liveDataActive = true;
    notifyListeners();
  }

  void _applyRobotPose(Map<String, dynamic> message) {
    final pose = message['pose'];
    if (pose is! Map) {
      return;
    }
    final position = pose['position'];
    final orientation = pose['orientation'];
    if (position is! Map) {
      return;
    }
    final x = _asDouble(position['x']);
    final y = _asDouble(position['y']);
    if (x == null || y == null) {
      return;
    }
    robotPosition = MapPoint(x, y);
    if (orientation is Map) {
      robotHeadingRad = _yawFromQuaternion(orientation.cast<String, dynamic>());
    }
    _hasLiveRobotPose = true;
    _lastRobotPoseAt = DateTime.now();
    liveDataActive = true;
    if (recordingType != null && rosConnected) {
      _appendRecordTrail(robotPosition);
    }
    notifyListeners();
  }

  /// Append a pose to the live record trail, skipping points closer than ~5cm
  /// to the previous one (mirrors the backend `min_dist` sampling).
  void _appendRecordTrail(MapPoint p) {
    if (recordTrail.isEmpty) {
      recordTrail = [p];
    } else {
      final last = recordTrail.last;
      final dx = p.x - last.x;
      final dy = p.y - last.y;
      if (dx * dx + dy * dy >= 0.0025) {
        recordTrail = [...recordTrail, p];
      }
    }
    recordPointCount = recordTrail.length;
  }

  final Map<int, bool> _zoneCoverageById = {};

  bool _zoneHasCoveragePath(int zoneId) => _zoneCoverageById[zoneId] ?? false;

  List<MissionZone> _buildZonesFromMarkers(List<Map<String, dynamic>> markers) {
    final result = <MissionZone>[];
    for (final marker in markers) {
      final points = _markerPoints(marker);
      if (points.length < 3) {
        continue;
      }
      final id = _markerId(marker, fallback: result.length + 1);
      result.add(
        MissionZone(
          id: id,
          name: 'Zone $id',
          points: points,
          hasCoveragePath: _zoneHasCoveragePath(id),
        ),
      );
    }
    return result;
  }

  List<MissionZone> _buildRiskZonesFromMarkers(
    List<Map<String, dynamic>> markers,
  ) {
    final result = <MissionZone>[];
    for (final marker in markers) {
      final points = _markerPoints(marker);
      if (points.length < 3) {
        continue;
      }
      final id = _markerId(marker, fallback: result.length + 1);
      result.add(MissionZone(id: id, name: 'Risk $id', points: points));
    }
    return result;
  }

  List<ChannelPath> _buildChannelsFromMarkers(
    List<Map<String, dynamic>> markers,
  ) {
    final result = <ChannelPath>[];
    for (final marker in markers) {
      final points = _markerPoints(marker);
      if (points.length < 2) {
        continue;
      }
      final id = _markerId(marker, fallback: result.length + 1);
      result.add(ChannelPath(id: id, name: 'Channel $id', points: points));
    }
    return result;
  }

  List<InvalidSegment> _buildInvalidSegmentsFromMarkers(
    List<Map<String, dynamic>> markers,
  ) {
    final result = <InvalidSegment>[];
    for (final marker in markers) {
      final points = _markerPoints(marker);
      if (points.length < 2) {
        continue;
      }
      final id = _markerId(marker, fallback: result.length + 1);
      result.add(InvalidSegment(id: id, points: points));
    }
    return result;
  }

  List<MapPoint> _markerPoints(Map<String, dynamic> marker) {
    final points = marker['points'];
    if (points is! List) {
      return const [];
    }
    return points.whereType<Map>().map((point) {
      final x = _asDouble(point['x']) ?? 0.0;
      final y = _asDouble(point['y']) ?? 0.0;
      return MapPoint(x, y);
    }).toList();
  }

  int _markerId(Map<String, dynamic> marker, {required int fallback}) {
    return _asInt(marker['id']) ?? fallback;
  }

  void selectMode(MissionMode mode) {
    selectedMode = mode;
    notifyListeners();
  }

  void startRecording(RecordObjectType type) {
    if (_connectionSettingsPending ||
        _planningMutationPending ||
        recordingType != null ||
        _recordCommandPending) {
      return;
    }
    if (_pendingRecordSaveType != null) {
      _addLog('WARN', '上一次記錄尚未持久化，請先重試儲存');
      return;
    }
    if (_navOperationActive) {
      _addLog('WARN', '自動導航進行中，不能開始手動記錄');
      return;
    }
    unawaited(_startRecording(type));
  }

  Future<void> _startRecording(RecordObjectType type) async {
    if (mockDataEnabled) {
      recordingType = type;
      _recordingViaRos = false;
      recordPointCount = 8;
      recordTrail = const [];
      _recordingStartedAt = DateTime.now();
      _addLog('INFO', 'Demo：開始${_recordTypeName(type)}');
      notifyListeners();
      return;
    }
    if (!canDriveManually) {
      _addLog(
        'WARN',
        !canControlRobot
            ? '無法開始記錄：需要 rosbridge 與新鮮的機器人 heartbeat'
            : '無法開始記錄：需要可確認的導航待命狀態',
      );
      return;
    }

    if (manualControlActive) {
      stopManualControl();
    }
    _recordCommandPending = true;
    notifyListeners();
    final accepted = await _callRecordService(_recordStartService(type));
    _recordCommandPending = false;
    if (!accepted) {
      notifyListeners();
      return;
    }

    // Only enter recording UI after the backend acknowledged *_start.
    recordingType = type;
    _recordingViaRos = true;
    _recordingStartedAt = DateTime.now();
    recordTrail = _hasLiveRobotPose ? [robotPosition] : const [];
    recordPointCount = recordTrail.length;
    notifyListeners();
  }

  Future<bool> stopRecording({required bool save}) async {
    final type = recordingType;
    if (type == null || _recordCommandPending) {
      return false;
    }

    if (!_recordingViaRos) {
      _addLog(
        save ? 'SUCCESS' : 'WARN',
        'Demo：${_recordTypeName(type)}${save ? '已儲存' : '已取消'}',
      );
      _resetRecordingState();
      notifyListeners();
      return true;
    }

    if (!rosConnected) {
      _addLog('ERROR', 'rosbridge 已斷線，後端尚未確認記錄結束');
      return false;
    }

    if (manualControlActive) {
      stopManualControl();
    }
    _recordCommandPending = true;
    notifyListeners();
    if (!save) {
      final canceled = await _callRecordService('/record_cancel');
      _recordCommandPending = false;
      if (!canceled) {
        _addLog('ERROR', '${_recordTypeName(type)}仍維持記錄中，請重試');
        notifyListeners();
        return false;
      }
      _addLog('WARN', '${_recordTypeName(type)}已取消');
      _resetRecordingState();
      notifyListeners();
      return true;
    }

    final ended = await _callRecordService(_recordEndService(type));
    if (!ended) {
      _recordCommandPending = false;
      _addLog('ERROR', '${_recordTypeName(type)}仍維持記錄中，請重試停止');
      notifyListeners();
      return false;
    }

    // The recorder is no longer active as soon as *_end is acknowledged.
    // Persistence is a separate phase so a failed save never causes a retry
    // to send *_end twice.
    _resetRecordingState();
    _pendingRecordSaveType = type;
    notifyListeners();
    final persisted = await _callRecordService('/save_zone_list');
    _recordCommandPending = false;
    if (!persisted) {
      _addLog('ERROR', '${_recordTypeName(type)}已停止，但尚未持久化；請重試儲存');
      notifyListeners();
      return false;
    }

    _pendingRecordSaveType = null;
    _addLog('SUCCESS', '${_recordTypeName(type)}已儲存');
    notifyListeners();
    return true;
  }

  Future<bool> retryPendingRecordSave() async {
    final type = _pendingRecordSaveType;
    if (type == null || _recordCommandPending || !rosConnected) {
      if (type != null && !rosConnected) {
        _addLog('ERROR', 'rosbridge 已斷線，無法重試儲存${_recordTypeName(type)}');
      }
      return false;
    }
    if (manualControlActive) {
      stopManualControl();
    }
    _recordCommandPending = true;
    notifyListeners();
    final persisted = await _callRecordService('/save_zone_list');
    _recordCommandPending = false;
    if (persisted) {
      _pendingRecordSaveType = null;
      _addLog('SUCCESS', '${_recordTypeName(type)}已完成持久化');
    } else {
      _addLog('ERROR', '${_recordTypeName(type)}仍未持久化，請稍後重試');
    }
    notifyListeners();
    return persisted;
  }

  void _resetRecordingState() {
    recordingType = null;
    _recordingViaRos = false;
    recordPointCount = 0;
    recordTrail = const [];
    _recordingStartedAt = null;
    selectedMode = MissionMode.objects;
  }

  String _recordStartService(RecordObjectType type) {
    switch (type) {
      case RecordObjectType.zone:
        return '/record_zone_start';
      case RecordObjectType.risk:
        return '/risk_zone_start';
      case RecordObjectType.channel:
        return '/channel_record_start';
    }
  }

  String _recordEndService(RecordObjectType type) {
    switch (type) {
      case RecordObjectType.zone:
        return '/record_zone_end';
      case RecordObjectType.risk:
        return '/risk_zone_end';
      case RecordObjectType.channel:
        return '/channel_record_end';
    }
  }

  Future<bool> _callRecordService(String service) async {
    _addLog('INFO', '呼叫 $service');
    final response = await _rosbridge.callService(service);
    final message = response.message;
    final partialPersistence =
        service == '/save_zone_list' &&
        (message.contains('部分') || message.toLowerCase().contains('partial'));
    final accepted = response.success && !partialPersistence;
    _addLog(
      accepted ? 'SUCCESS' : 'ERROR',
      message.isEmpty
          ? '$service ${accepted ? '已送出' : '失敗'}'
          : partialPersistence
          ? '$message（未視為完整持久化）'
          : message,
    );
    return accepted;
  }

  void updateLayer({
    bool? zones,
    bool? risks,
    bool? channels,
    bool? coverage,
    bool? invalidSegments,
  }) {
    layers = layers.copyWith(
      zones: zones,
      risks: risks,
      channels: channels,
      coverage: coverage,
      invalidSegments: invalidSegments,
    );
    notifyListeners();
  }

  void toggleSatelliteBaseMap() {
    satelliteBaseMap = !satelliteBaseMap;
    notifyListeners();
  }

  bool _allowPlanningMutation(String action) {
    if (canMutatePlanning) {
      return true;
    }
    _addLog('WARN', '無法$action：請先確認導航已停止、狀態新鮮，且未在記錄或手動移動');
    return false;
  }

  bool _beginPlanningMutation(String action) {
    if (!_allowPlanningMutation(action)) {
      return false;
    }
    _planningMutationPending = true;
    notifyListeners();
    return true;
  }

  Future<void> _completePlanningMutation(
    String action,
    Future<void> Function() operation,
  ) async {
    try {
      await operation();
    } catch (error) {
      _addLog('ERROR', '$action失敗: $error');
    } finally {
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  void _invalidateCoverageReadiness() {
    coverageReady = false;
    coverageRows = const [];
    coverageProgress = 0.0;
    currentSegment = 0;
    _zoneCoverageById.updateAll((_, _) => false);
    zones = zones
        .map(
          (zone) => MissionZone(
            id: zone.id,
            name: zone.name,
            points: zone.points,
            hasCoveragePath: false,
          ),
        )
        .toList();
  }

  bool _planningChainCanContinue(int connectionGeneration) =>
      connectionGeneration == _connectionGeneration &&
      _planningMutationPending &&
      !mockDataEnabled &&
      rosConnected &&
      hasFreshTerminalNavStatus &&
      !_navOperationActive &&
      recordingType == null &&
      !_recordCommandPending &&
      !manualControlActive;

  void setCoveragePattern(CoveragePatternKind pattern) {
    if (mockDataEnabled || pattern == CoveragePatternKind.custom) {
      if (!_allowPlanningMutation('變更 Coverage pattern')) {
        return;
      }
      coveragePattern = pattern;
      _coveragePatternEditedAt = DateTime.now();
      _invalidateCoverageReadiness();
      _addLog('INFO', 'Coverage pattern set to ${pattern.name}');
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('變更 Coverage pattern')) {
      return;
    }
    final connectionGeneration = _connectionGeneration;
    final previousPattern = coveragePattern;
    coveragePattern = pattern;
    _coveragePatternEditedAt = DateTime.now();
    _invalidateCoverageReadiness();
    _addLog('INFO', 'Coverage pattern set to ${pattern.name}');
    notifyListeners();
    unawaited(
      _completePlanningMutation('變更 Coverage pattern', () async {
        final parameterAccepted = await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'coverage_pattern',
          pattern.name,
          type: 4,
        );
        if (!parameterAccepted) {
          coveragePattern = previousPattern;
          _coveragePatternEditedAt = null;
          _addLog('ERROR', 'Coverage pattern 未獲後端確認');
          return;
        }
        if (!_planningChainCanContinue(connectionGeneration)) {
          _addLog('ERROR', 'Coverage pattern 後續處理已中止：導航或連線狀態改變');
          return;
        }
        // Leaving custom: discard the imported image, restore the full
        // freespace coverage area, and drop the perimeter ring.
        if (_imageMissionActive) {
          final restored = await _rosbridge.callService(
            '/restore_free_space_coverage',
          );
          if (!_planningChainCanContinue(connectionGeneration)) {
            _addLog('ERROR', '恢復自由空間後狀態改變，未繼續修改參數');
            return;
          }
          final ringAccepted = await _setRosDoubleParam(
            '/boustrophedon_coverage/set_parameters',
            'boundary_ring',
            false,
            type: 1,
          );
          if (!restored.success || !ringAccepted) {
            _addLog('ERROR', '恢復完整自由空間未獲完整 ACK');
            return;
          }
          _imageMissionActive = false;
          boundaryRing = false;
          _addLog('INFO', '已切回完整自由空間（捨棄圖片範圍）');
        }
      }),
    );
  }

  void setStripWidth(double value) {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('變更 Strip Width')) return;
      stripWidthM = value;
      _stripWidthEditedAt = DateTime.now();
      _invalidateCoverageReadiness();
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('變更 Strip Width')) return;
    final previousValue = stripWidthM;
    stripWidthM = value;
    _stripWidthEditedAt = DateTime.now();
    _invalidateCoverageReadiness();
    notifyListeners();
    unawaited(
      _completePlanningMutation('變更 Strip Width', () async {
        if (!await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'strip_width_m',
          value,
        )) {
          stripWidthM = previousValue;
          _stripWidthEditedAt = null;
          _addLog('ERROR', 'Strip Width 未獲後端確認');
        }
      }),
    );
  }

  void setWaypointSpacing(double value) {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('變更 Waypoint Spacing')) return;
      waypointSpacingM = value;
      _waypointSpacingEditedAt = DateTime.now();
      _invalidateCoverageReadiness();
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('變更 Waypoint Spacing')) return;
    final previousValue = waypointSpacingM;
    waypointSpacingM = value;
    _waypointSpacingEditedAt = DateTime.now();
    _invalidateCoverageReadiness();
    notifyListeners();
    unawaited(
      _completePlanningMutation('變更 Waypoint Spacing', () async {
        if (!await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'waypoint_spacing_m',
          value,
        )) {
          waypointSpacingM = previousValue;
          _waypointSpacingEditedAt = null;
          _addLog('ERROR', 'Waypoint Spacing 未獲後端確認');
        }
      }),
    );
  }

  void setZigzagAngle(double value) {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('變更 Zigzag Angle')) return;
      zigzagAngleDeg = value;
      _zigzagAngleEditedAt = DateTime.now();
      _invalidateCoverageReadiness();
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('變更 Zigzag Angle')) return;
    final previousValue = zigzagAngleDeg;
    zigzagAngleDeg = value;
    _zigzagAngleEditedAt = DateTime.now();
    _invalidateCoverageReadiness();
    notifyListeners();
    unawaited(
      _completePlanningMutation('變更 Zigzag Angle', () async {
        if (!await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'zigzag_angle_deg',
          value,
        )) {
          zigzagAngleDeg = previousValue;
          _zigzagAngleEditedAt = null;
          _addLog('ERROR', 'Zigzag Angle 未獲後端確認');
        }
      }),
    );
  }

  void setBoundaryRing(bool value) {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('變更 Boundary Ring')) return;
      boundaryRing = value;
      _boundaryRingEditedAt = DateTime.now();
      _invalidateCoverageReadiness();
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('變更 Boundary Ring')) return;
    final previousValue = boundaryRing;
    boundaryRing = value;
    _boundaryRingEditedAt = DateTime.now();
    _invalidateCoverageReadiness();
    notifyListeners();
    unawaited(
      _completePlanningMutation('變更 Boundary Ring', () async {
        if (!await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'boundary_ring',
          value,
          type: 1,
        )) {
          boundaryRing = previousValue;
          _boundaryRingEditedAt = null;
          _addLog('ERROR', 'Boundary Ring 未獲後端確認');
        }
      }),
    );
  }

  void setImageMissionDraft(ImageMissionDraft draft) {
    if (_planningMutationPending || imageMissionDraft?.submitting == true) {
      _addLog('WARN', '圖片任務送出中，不能替換草稿');
      return;
    }
    imageMissionDraft = draft;
    selectedMode = MissionMode.plan;
    _addLog('INFO', '圖片任務已載入：${draft.sourceName}');
    notifyListeners();
  }

  void clearImageMissionDraft() {
    if (_planningMutationPending || imageMissionDraft?.submitting == true) {
      _addLog('WARN', '圖片任務送出中，不能清除草稿');
      return;
    }
    imageMissionDraft = null;
    _addLog('WARN', '圖片任務草稿已清除');
    notifyListeners();
  }

  void updateImageMissionThreshold(int threshold) {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      threshold: threshold,
      freeMask: ImageMissionProcessor.thresholdMask(draft.grayscale, threshold),
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  void updateImageMissionResolution(double resolutionM) {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      resolutionM: resolutionM.clamp(0.005, 0.5).toDouble(),
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  void updateImageMissionStartPose(ImageMissionStartPose startPose) {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      startPose: startPose,
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  /// Default the alignment placement (and a sensible start pixel) when the
  /// align step opens. Re-entry keeps any existing placement/start.
  void initImageMissionPlacement() {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }

    // Default start pixel = centroid of free cells, else image centre.
    var startPoint = draft.startPose?.point;
    if (startPoint == null) {
      var sumX = 0.0;
      var sumY = 0.0;
      var count = 0;
      for (var row = 0; row < draft.height; row += 1) {
        final base = row * draft.width;
        for (var col = 0; col < draft.width; col += 1) {
          if (draft.freeMask[base + col] == 255) {
            sumX += col;
            sumY += row;
            count += 1;
          }
        }
      }
      startPoint = count > 0
          ? MapPoint(sumX / count, sumY / count)
          : MapPoint(draft.width / 2, draft.height / 2);
    }

    // Default anchor = centre of the collected freespace, else robot position.
    MapPoint anchor;
    final fs = freeSpaceLayer;
    if (fs != null) {
      anchor = MapPoint(
        fs.originX + fs.width * fs.resolution / 2,
        fs.originY + fs.height * fs.resolution / 2,
      );
    } else {
      anchor = robotPosition;
    }

    imageMissionDraft = draft.copyWith(
      startPose:
          draft.startPose ??
          ImageMissionStartPose(point: startPoint, headingRad: 0.0),
      placement: draft.placement ?? ImageMissionPlacement(mapAnchor: anchor),
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  /// Clear the alignment + start pixel and recompute defaults.
  void resetImageMissionPlacement() {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      clearPlacement: true,
      clearStartPose: true,
    );
    initImageMissionPlacement();
  }

  /// Live update of the drag/rotate/scale alignment (no path computed here).
  void updateImageMissionPlacement(ImageMissionPlacement placement) {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      placement: placement,
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  /// Set the start pixel by tapping on the map. [worldAnchor] is the tapped
  /// world point and becomes the new anchor so the overlay does not move.
  void setImageMissionStartFromMap(MapPoint pixel, MapPoint worldAnchor) {
    final draft = imageMissionDraft;
    final placement = draft?.placement;
    if (draft == null ||
        placement == null ||
        draft.submitting ||
        _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      startPose: ImageMissionStartPose(
        point: pixel,
        headingRad: draft.startPose?.headingRad ?? 0.0,
      ),
      placement: placement.copyWith(mapAnchor: worldAnchor),
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  void updateImageMissionRiskMask(Uint8List riskMask) {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      riskMask: riskMask,
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  void clearImageMissionRiskMask() {
    final draft = imageMissionDraft;
    if (draft == null || draft.submitting || _planningMutationPending) {
      return;
    }
    imageMissionDraft = draft.copyWith(
      clearRiskMask: true,
      submitted: false,
      clearSubmitMessage: true,
      clearSubmittedArea: true,
    );
    notifyListeners();
  }

  Future<bool> submitImageMissionDraft() async {
    final draft = imageMissionDraft;
    if (draft == null || !draft.canSubmit) {
      _addLog('WARN', '圖片任務尚未完成縮放比例與起點設定');
      return false;
    }

    if (mockDataEnabled) {
      if (!_allowPlanningMutation('建立圖片任務')) {
        return false;
      }
      imageMissionDraft = draft.copyWith(
        submitting: false,
        submitted: true,
        submitMessage: 'Mock 圖片任務已建立',
        submittedAreaM2: draft.areaM2,
      );
      coverageReady = true;
      coverageProgress = 0.0;
      selectedZoneId = draft.zoneId;
      _addLog(
        'SUCCESS',
        'Mock 圖片任務已建立，面積 ${draft.areaM2.toStringAsFixed(1)} m²',
      );
      notifyListeners();
      return true;
    }
    if (!_beginPlanningMutation('建立圖片任務')) {
      return false;
    }
    final connectionGeneration = _connectionGeneration;
    imageMissionDraft = draft.copyWith(submitting: true);
    _invalidateCoverageReadiness();
    notifyListeners();

    try {
      // Map the on-canvas alignment (anchor + rotation θ + scale s) onto the
      // existing /import_image_mask geometry. Scale folds into resolution_m,
      // translation into robot_pose_map.position, rotation into robot yaw
      // (image_heading stays at φ_img so theta = robot_yaw − image_heading = θ).
      final placement = draft.placement!;
      final resolutionM = draft.resolutionM * placement.mapScale;
      final startLocal = ImageMissionProcessor.imagePointToLocalMeters(
        draft.startPose!.point,
        imageHeight: draft.height,
        resolutionM: resolutionM,
      );
      final imageHeadingRad = draft.startPose!.headingRad;
      final now = DateTime.now();
      final response = await _rosbridge.callService(
        '/import_image_mask',
        args: {
          'zone_id': draft.zoneId,
          'robot_pose_header': {
            'stamp': {
              'sec': now.millisecondsSinceEpoch ~/ 1000,
              'nanosec': (now.millisecondsSinceEpoch % 1000) * 1000000,
            },
            'frame_id': 'map',
          },
          'robot_pose_map': {
            'position': {
              'x': placement.mapAnchor.x,
              'y': placement.mapAnchor.y,
              'z': 0.0,
            },
            'orientation': _yawToQuaternion(
              imageHeadingRad + placement.mapRotationRad,
            ),
          },
          'width': draft.width,
          'height': draft.height,
          'resolution_m': resolutionM,
          'start_x_m': startLocal.x,
          'start_y_m': startLocal.y,
          'image_heading_rad': imageHeadingRad,
          'mask_encoding': 'base64_u8_row_major',
          'free_mask_data': ImageMissionProcessor.encodeMaskBase64(
            draft.freeMask,
          ),
          'risk_mask_data': draft.riskMask == null
              ? ''
              : ImageMissionProcessor.encodeMaskBase64(draft.riskMask!),
        },
      );

      if (!_planningChainCanContinue(connectionGeneration)) {
        imageMissionDraft = draft.copyWith(
          submitting: false,
          submitted: false,
          submitMessage: '連線或導航狀態已改變，後續規劃已中止',
        );
        _addLog('ERROR', '圖片匯入後狀態已改變，未繼續生成路徑');
        return false;
      }

      final success = response.success;
      final area =
          (response.values['area_m2'] as num?)?.toDouble() ?? draft.areaM2;
      imageMissionDraft = draft.copyWith(
        submitting: false,
        submitted: success,
        submitMessage: response.message.isEmpty
            ? success
                  ? '圖片任務已送出'
                  : '圖片任務送出失敗'
            : response.message,
        submittedAreaM2: success ? area : null,
        clearSubmittedArea: !success,
      );
      if (success) {
        selectedZoneId =
            (response.values['zone_id'] as num?)?.toInt() ?? draft.zoneId;
        freeSpaceReady = true;
        riskMapReady = true;
        _imageMissionActive = true;
        boundaryRing = true;
        // Custom missions add an outer-contour perimeter pass; set this BEFORE
        // generating so coverage_node reads it (await to guarantee ordering).
        final ringAccepted = await _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'boundary_ring',
          true,
          type: 1,
        );
        if (!ringAccepted) {
          imageMissionDraft = draft.copyWith(
            submitting: false,
            submitted: false,
            submitMessage: '圖片已匯入，但 Boundary Ring 未獲後端確認',
          );
          _addLog('ERROR', '圖片已匯入，但 Boundary Ring 未獲後端確認；未生成路徑');
          return false;
        }
        if (!_planningChainCanContinue(connectionGeneration)) {
          imageMissionDraft = draft.copyWith(
            submitting: false,
            submitted: false,
            submitMessage: '導航或連線狀態已改變，未生成路徑',
          );
          _addLog('ERROR', 'Boundary Ring 設定後狀態改變，未生成 Coverage Path');
          return false;
        }
        _addLog('SUCCESS', '圖片任務已匯入，準備生成 Coverage Path');
        await _runRosPlanningStep('coverage');
      } else {
        _addLog(
          'ERROR',
          response.message.isEmpty ? '圖片任務匯入失敗' : response.message,
        );
      }
      notifyListeners();
      return success;
    } finally {
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  Map<String, double> _yawToQuaternion(double yaw) {
    final half = yaw / 2.0;
    return {'x': 0.0, 'y': 0.0, 'z': math.sin(half), 'w': math.cos(half)};
  }

  Future<bool> _setRosDoubleParam(
    String service,
    String name,
    dynamic value, {
    int type = 3,
  }) async {
    final response = await _rosbridge.callService(
      service,
      args: {
        'parameters': [
          {
            'name': name,
            'value': {
              'type': type,
              if (type == 1) 'bool_value': value,
              if (type == 3) 'double_value': value,
              if (type == 4) 'string_value': value,
            },
          },
        ],
      },
    );
    final rawResults = response.values['results'];
    if (!response.result || rawResults is! List || rawResults.isEmpty) {
      return false;
    }
    for (final raw in rawResults) {
      if (raw is! Map || raw['successful'] != true) {
        final reason = raw is Map ? raw['reason']?.toString() : null;
        if (reason != null && reason.isNotEmpty) {
          _addLog('ERROR', '參數被後端拒絕: $reason');
        }
        return false;
      }
    }
    return true;
  }

  void runPlanningStep(String step) {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('執行規劃')) {
        return;
      }
      _invalidateCoverageReadiness();
      _runMockPlanningStep(step);
      return;
    }
    if (!_beginPlanningMutation('執行規劃')) {
      return;
    }
    _invalidateCoverageReadiness();
    notifyListeners();
    unawaited(
      _completePlanningMutation('執行規劃', () => _runRosPlanningStep(step)),
    );
  }

  Future<void> _runRosPlanningStep(String step) async {
    final service = switch (step) {
      'free_space' => '/create_free_space',
      'risk_map' => '/create_risk_map',
      'channel_map' => '/create_chennal_map',
      'coverage' => '/generate_coverage_path',
      _ => null,
    };
    if (service == null) {
      return;
    }
    _addLog('INFO', '呼叫 $service');
    final response = await _rosbridge.callService(service);
    if (response.success) {
      _addLog(
        'SUCCESS',
        response.message.isEmpty ? '$service 已送出，等待地圖資料...' : response.message,
      );
    } else {
      _addLog(
        'ERROR',
        response.message.isEmpty ? '$service 失敗' : response.message,
      );
    }
    notifyListeners();
  }

  void _runMockPlanningStep(String step) {
    switch (step) {
      case 'free_space':
        freeSpaceReady = true;
        _addLog('SUCCESS', '自由空間地圖已建立');
        break;
      case 'risk_map':
        riskMapReady = true;
        _addLog('SUCCESS', '風險地圖已更新');
        break;
      case 'channel_map':
        channelMapReady = true;
        _addLog('SUCCESS', '通道地圖已更新');
        break;
      case 'coverage':
        coverageReady = true;
        coverageProgress = 0.42;
        currentSegment = 3;
        _addLog('SUCCESS', '覆蓋路徑已生成');
        break;
    }
    notifyListeners();
  }

  void selectZone(int zoneId) {
    if (_navOperationActive || _planningMutationPending) {
      _addLog('WARN', '導航或規劃處理中，不能切換工作區');
      return;
    }
    selectedZoneId = zoneId;
    notifyListeners();
  }

  // ── Object selection / editing (物件頁: 選取 / 刪除 / …) ─────────────────────
  // selectedObjectKind: 'zone' | 'risk' | 'channel'.
  String? selectedObjectKind;
  int? selectedObjectId;
  bool replanning = false;

  bool isObjectSelected(String kind, int id) =>
      selectedObjectKind == kind && selectedObjectId == id;

  void selectObject(String kind, int id) {
    selectedObjectKind = kind;
    selectedObjectId = id;
    notifyListeners();
  }

  void clearObjectSelection() {
    if (selectedObjectKind == null && selectedObjectId == null) {
      return;
    }
    selectedObjectKind = null;
    selectedObjectId = null;
    notifyListeners();
  }

  /// Hit-test a world point: zones/risks by polygon, channels by proximity.
  /// Selects the first hit and returns true; clears nothing on a miss.
  bool selectObjectAt(MapPoint world, {double channelTol = 1.0}) {
    for (final z in zones) {
      if (_pointInPolygon(world, z.points)) {
        selectObject('zone', z.id);
        return true;
      }
    }
    for (final r in riskZones) {
      if (_pointInPolygon(world, r.points)) {
        selectObject('risk', r.id);
        return true;
      }
    }
    for (final c in channels) {
      if (_nearPolyline(world, c.points, channelTol)) {
        selectObject('channel', c.id);
        return true;
      }
    }
    return false;
  }

  /// Delete an object via the backend /edit_zone service, then re-plan.
  Future<void> deleteObject(String kind, int id) async {
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('刪除規劃物件')) return;
      // Explicit demo mode: update only the isolated in-memory scene.
      _removeObjectLocally(kind, id);
      _invalidateCoverageReadiness();
      if (isObjectSelected(kind, id)) {
        clearObjectSelection();
      }
      _addLog('SUCCESS', '$kind #$id 已刪除（mock）');
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('刪除規劃物件')) {
      return;
    }
    try {
      _addLog('INFO', '刪除 $kind #$id');
      final r = await _rosbridge.callService(
        '/edit_zone',
        args: {'op': 'delete', 'kind': kind, 'id': id, 'points': <dynamic>[]},
      );
      if (!r.success) {
        _addLog('ERROR', r.message.isEmpty ? '刪除失敗' : r.message);
        return;
      }
      _addLog('SUCCESS', r.message.isEmpty ? '$kind #$id 已刪除' : r.message);
      if (isObjectSelected(kind, id)) {
        clearObjectSelection();
      }
      _invalidateCoverageReadiness();
      await _replanAfterEdit();
    } finally {
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  void _removeObjectLocally(String kind, int id) {
    switch (kind) {
      case 'zone':
        zones = zones.where((z) => z.id != id).toList();
        _ensureSelectedZone();
      case 'risk':
        riskZones = riskZones.where((z) => z.id != id).toList();
      case 'channel':
        channels = channels.where((c) => c.id != id).toList();
    }
  }

  /// Re-run the planning chain after an object edit so coverage updates.
  Future<void> _replanAfterEdit() async {
    if (mockDataEnabled || !rosConnected) {
      return;
    }
    final connectionGeneration = _connectionGeneration;
    replanning = true;
    notifyListeners();
    const steps = [
      '/load_zone_list',
      '/create_free_space',
      '/create_risk_map',
      '/generate_coverage_path',
    ];
    try {
      for (final s in steps) {
        if (!_planningChainCanContinue(connectionGeneration)) {
          _addLog('ERROR', '規劃鏈已中止：連線或導航狀態已改變');
          break;
        }
        final r = await _rosbridge.callService(s);
        if (!r.success) {
          _addLog('ERROR', '$s ${r.message.isEmpty ? '失敗' : r.message}');
          break;
        }
        _addLog('INFO', '$s 完成');
      }
    } finally {
      replanning = false;
      notifyListeners();
    }
  }

  // ── 場地庫 (saved site library, backend /site_list + /site_op) ─────────────
  List<SiteInfo> sites = const [];
  String? activeSiteName;
  bool siteOpBusy = false;

  /// Last user-facing message from a site operation — backend `message` or
  /// the mock equivalent, success AND failure. Drives the sheet's result
  /// banner (and the SnackBars shown once the sheet closes).
  String? siteOpMessage;

  void _applySiteList(Map<String, dynamic> dto) {
    final rawSites = dto['sites'];
    sites = rawSites is List
        ? rawSites
              .whereType<Map>()
              .map((s) => SiteInfo.fromJson(s.cast<String, dynamic>()))
              .toList()
        : const <SiteInfo>[];
    activeSiteName = dto['active']?.toString();
    notifyListeners();
  }

  /// Save the current planning (whole zone set) as a named site.
  Future<String?> saveSiteAs(String name) =>
      _withSiteBusy(() => _callSiteOp('save', name));

  /// Load a saved site. The backend replaces its zone set and republishes the
  /// marker topics; the app then regenerates the derived maps + coverage.
  Future<String?> activateSite(String name) => _withSiteBusy(() async {
    final error = await _callSiteOp('load', name);
    if (error != null) {
      return error;
    }
    _invalidateCoverageReadiness();
    await _replanAfterSiteLoad();
    return null;
  });

  Future<String?> deleteSite(String name) =>
      _withSiteBusy(() => _callSiteOp('delete', name));

  Future<String?> renameSite(String oldName, String newName) =>
      _withSiteBusy(() => _callSiteOp('rename', oldName, newName: newName));

  /// Every site op runs inside this guard: [siteOpBusy] is set/cleared exactly
  /// once per operation (spanning activateSite's whole load+replan chain) so
  /// the sheet can disable all actions while any site op is in flight.
  Future<String?> _withSiteBusy(Future<String?> Function() op) async {
    if (siteOpBusy) {
      return _siteOpFail('場地操作仍在進行中');
    }
    if (!_beginPlanningMutation('變更場地資料')) {
      return '目前無法變更場地資料';
    }
    siteOpBusy = true;
    notifyListeners();
    try {
      return await op();
    } finally {
      siteOpBusy = false;
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  Future<String?> _callSiteOp(
    String op,
    String name, {
    String newName = '',
  }) async {
    if (mockDataEnabled) {
      return _mockSiteOp(op, name, newName);
    }
    if (!rosConnected) {
      return _siteOpFail('請先連上 rosbridge');
    }
    _addLog('INFO', '呼叫 /site_op $op「$name」');
    final r = await _rosbridge.callService(
      '/site_op',
      args: {'op': op, 'name': name, 'new_name': newName},
    );
    final sitesJson = r.values['sites_json'];
    if (sitesJson is String && sitesJson.isNotEmpty) {
      try {
        final dto = jsonDecode(sitesJson);
        if (dto is Map<String, dynamic>) {
          _applySiteList(dto);
        }
      } catch (error) {
        _addLog('ERROR', 'sites_json 解析失敗: $error');
      }
    }
    if (!r.success) {
      return _siteOpFail(r.message.isEmpty ? '/site_op $op 失敗' : r.message);
    }
    siteOpMessage = r.message.isEmpty ? '/site_op $op 完成' : r.message;
    _addLog('SUCCESS', siteOpMessage!);
    notifyListeners();
    return null;
  }

  /// Record a site-op failure in [siteOpMessage] (so the sheet banner always
  /// reflects the last op) and return it as the error string.
  String _siteOpFail(String message) {
    siteOpMessage = message;
    _addLog('ERROR', message);
    notifyListeners();
    return message;
  }

  /// Offline/mock: keep an in-memory site library so the demo still responds
  /// (mirrors deleteObject's local fallback). Nothing is persisted.
  String? _mockSiteOp(String op, String name, String newName) {
    if (!mockDataEnabled) {
      return _siteOpFail('請先連上 rosbridge');
    }
    switch (op) {
      case 'save':
        final now = DateTime.now();
        final index = sites.indexWhere((s) => s.name == name);
        final snapshot = SiteInfo(
          name: name,
          createdAt: index < 0 ? now : sites[index].createdAt,
          updatedAt: now,
          zoneCount: zones.length,
          riskCount: riskZones.length,
          channelCount: channels.length,
          areaM2: zones.fold<double>(
            0.0,
            (sum, z) => sum + _polygonAreaM2(z.points),
          ),
        );
        // Updating keeps the site's list position (backend keeps name order).
        sites = index < 0
            ? [...sites, snapshot]
            : (List<SiteInfo>.of(sites)..[index] = snapshot);
        activeSiteName = name;
        siteOpMessage = '已儲存場地「$name」（mock）';
      case 'load':
        if (!sites.any((s) => s.name == name)) {
          return _siteOpFail('找不到場地「$name」');
        }
        activeSiteName = name;
        siteOpMessage = '已啟用場地「$name」（mock）';
      case 'delete':
        sites = sites.where((s) => s.name != name).toList();
        if (activeSiteName == name) {
          activeSiteName = null;
        }
        siteOpMessage = '已刪除場地「$name」（mock）';
      case 'rename':
        if (!sites.any((s) => s.name == name)) {
          return _siteOpFail('找不到場地「$name」');
        }
        if (sites.any((s) => s.name == newName)) {
          return _siteOpFail('場地「$newName」已存在');
        }
        sites = sites
            .map(
              (s) => s.name == name
                  ? SiteInfo(
                      name: newName,
                      createdAt: s.createdAt,
                      updatedAt: s.updatedAt,
                      zoneCount: s.zoneCount,
                      riskCount: s.riskCount,
                      channelCount: s.channelCount,
                      areaM2: s.areaM2,
                      datumSource: s.datumSource,
                    )
                  : s,
            )
            .toList();
        if (activeSiteName == name) {
          activeSiteName = newName;
        }
        siteOpMessage = '已改名為「$newName」（mock）';
      default:
        return _siteOpFail('未知的操作 $op');
    }
    _addLog('SUCCESS', siteOpMessage!);
    notifyListeners();
    return null;
  }

  double _polygonAreaM2(List<MapPoint> points) {
    if (points.length < 3) {
      return 0.0;
    }
    var sum = 0.0;
    for (var i = 0, j = points.length - 1; i < points.length; j = i++) {
      sum += points[j].x * points[i].y - points[i].x * points[j].y;
    }
    return sum.abs() / 2.0;
  }

  /// Re-run the planning chain after a site load so the derived maps and
  /// coverage match the loaded zone set. Same chain as [_replanAfterEdit]
  /// WITHOUT the /load_zone_list step — the load already replaced the zones.
  Future<void> _replanAfterSiteLoad() async {
    if (mockDataEnabled || !rosConnected) {
      return;
    }
    final connectionGeneration = _connectionGeneration;
    const steps = [
      '/create_free_space',
      '/create_risk_map',
      '/generate_coverage_path',
    ];
    for (final s in steps) {
      if (!_planningChainCanContinue(connectionGeneration)) {
        _addLog('ERROR', '場地規劃已中止：連線或導航狀態已改變');
        break;
      }
      final r = await _rosbridge.callService(s);
      if (!r.success) {
        _addLog('ERROR', '$s ${r.message.isEmpty ? '失敗' : r.message}');
        break;
      }
      _addLog('INFO', '$s 完成');
    }
  }

  bool _pointInPolygon(MapPoint p, List<MapPoint> poly) {
    if (poly.length < 3) {
      return false;
    }
    var inside = false;
    for (var i = 0, j = poly.length - 1; i < poly.length; j = i++) {
      final xi = poly[i].x, yi = poly[i].y;
      final xj = poly[j].x, yj = poly[j].y;
      final denom = (yj - yi) == 0 ? 1e-9 : (yj - yi);
      final intersect =
          ((yi > p.y) != (yj > p.y)) &&
          (p.x < (xj - xi) * (p.y - yi) / denom + xi);
      if (intersect) {
        inside = !inside;
      }
    }
    return inside;
  }

  bool _nearPolyline(MapPoint p, List<MapPoint> line, double tol) {
    for (var i = 0; i < line.length - 1; i++) {
      if (_distToSegment(p, line[i], line[i + 1]) <= tol) {
        return true;
      }
    }
    return false;
  }

  double _distToSegment(MapPoint p, MapPoint a, MapPoint b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    final len2 = dx * dx + dy * dy;
    if (len2 == 0) {
      return math.sqrt((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y));
    }
    var t = ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final cx = a.x + t * dx, cy = a.y + t * dy;
    return math.sqrt((p.x - cx) * (p.x - cx) + (p.y - cy) * (p.y - cy));
  }

  // ── Draw a new object by tapping vertices on the map (P2) ───────────────────
  bool drawMode = false;
  String drawKind = 'risk';
  List<MapPoint> draftPolygon = const [];

  void startDrawRisk() {
    drawMode = true;
    drawKind = 'risk';
    draftPolygon = const [];
    clearObjectSelection();
    _addLog('INFO', '開始繪製危險區：點地圖加頂點,至少 3 點後閉合儲存');
    notifyListeners();
  }

  void addDraftVertex(MapPoint p) {
    if (!drawMode) {
      return;
    }
    draftPolygon = [...draftPolygon, p];
    notifyListeners();
  }

  void undoDraftVertex() {
    if (!drawMode || draftPolygon.isEmpty) {
      return;
    }
    draftPolygon = draftPolygon.sublist(0, draftPolygon.length - 1);
    notifyListeners();
  }

  void cancelDraw() {
    if (!drawMode) {
      return;
    }
    drawMode = false;
    draftPolygon = const [];
    _addLog('WARN', '取消繪製');
    notifyListeners();
  }

  Future<void> commitDraw() async {
    if (!drawMode) {
      return;
    }
    final pts = List<MapPoint>.of(draftPolygon);
    if (pts.length < 3) {
      _addLog('WARN', '危險區至少需要 3 個點');
      return;
    }
    final kind = drawKind;
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('新增規劃物件')) return;
      drawMode = false;
      draftPolygon = const [];
      _addRiskLocally(pts);
      _invalidateCoverageReadiness();
      _addLog('SUCCESS', '已新增 $kind（mock）');
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('新增規劃物件')) {
      return;
    }
    drawMode = false;
    draftPolygon = const [];
    notifyListeners();

    try {
      _addLog('INFO', '新增 $kind（${pts.length} 點）');
      final r = await _rosbridge.callService(
        '/edit_zone',
        args: {
          'op': 'add',
          'kind': kind,
          'id': 0,
          'points': pts.map((p) => {'x': p.x, 'y': p.y, 'z': 0.0}).toList(),
        },
      );
      if (!r.success) {
        _addLog('ERROR', r.message.isEmpty ? '新增失敗' : r.message);
        // Restore the draft so the user can retry instead of losing the work.
        draftPolygon = pts;
        drawMode = true;
        notifyListeners();
        return;
      }
      _addLog('SUCCESS', r.message.isEmpty ? '已新增 $kind' : r.message);
      _invalidateCoverageReadiness();
      await _replanAfterEdit();
    } finally {
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  void _addRiskLocally(List<MapPoint> pts) {
    final id = riskZones.fold<int>(0, (m, z) => z.id > m ? z.id : m) + 1;
    riskZones = [
      ...riskZones,
      MissionZone(id: id, name: 'Risk $id', points: pts),
    ];
  }

  // ── Vertex editing of an existing object (P3) ───────────────────────────────
  bool editVertexMode = false;
  String editKind = 'zone';
  int editId = 0;
  List<MapPoint> editPolygon = const [];

  void startVertexEdit(String kind, int id) {
    final pts = _objectPoints(kind, id);
    if (pts == null || pts.isEmpty) {
      return;
    }
    editVertexMode = true;
    editKind = kind;
    editId = id;
    editPolygon = List<MapPoint>.of(pts);
    selectObject(kind, id);
    drawMode = false;
    _addLog('INFO', '編輯 $kind #$id 頂點：拖曳移動,長按刪除,完成儲存');
    notifyListeners();
  }

  List<MapPoint>? _objectPoints(String kind, int id) {
    switch (kind) {
      case 'zone':
        final m = zones.where((e) => e.id == id);
        return m.isEmpty ? null : m.first.points;
      case 'risk':
        final m = riskZones.where((e) => e.id == id);
        return m.isEmpty ? null : m.first.points;
      case 'channel':
        final m = channels.where((e) => e.id == id);
        return m.isEmpty ? null : m.first.points;
    }
    return null;
  }

  void moveVertex(int index, MapPoint world) {
    if (!editVertexMode || index < 0 || index >= editPolygon.length) {
      return;
    }
    final next = List<MapPoint>.of(editPolygon);
    next[index] = world;
    editPolygon = next;
    notifyListeners();
  }

  void deleteVertex(int index) {
    if (!editVertexMode || index < 0 || index >= editPolygon.length) {
      return;
    }
    final minPts = editKind == 'channel' ? 2 : 3;
    if (editPolygon.length <= minPts) {
      _addLog('WARN', '至少需要 $minPts 個頂點');
      return;
    }
    editPolygon = List<MapPoint>.of(editPolygon)..removeAt(index);
    notifyListeners();
  }

  void cancelVertexEdit() {
    if (!editVertexMode) {
      return;
    }
    editVertexMode = false;
    editPolygon = const [];
    _addLog('WARN', '取消編輯');
    notifyListeners();
  }

  Future<void> commitVertexEdit() async {
    if (!editVertexMode) {
      return;
    }
    final pts = List<MapPoint>.of(editPolygon);
    final kind = editKind;
    final id = editId;
    final minPts = kind == 'channel' ? 2 : 3;
    if (pts.length < minPts) {
      _addLog('WARN', '至少需要 $minPts 個頂點');
      return;
    }
    if (mockDataEnabled) {
      if (!_allowPlanningMutation('更新規劃物件')) return;
      editVertexMode = false;
      editPolygon = const [];
      _updateObjectLocally(kind, id, pts);
      _invalidateCoverageReadiness();
      _addLog('SUCCESS', '已更新 $kind #$id（mock）');
      notifyListeners();
      return;
    }
    if (!_beginPlanningMutation('更新規劃物件')) {
      return;
    }
    editVertexMode = false;
    editPolygon = const [];
    notifyListeners();

    try {
      _addLog('INFO', '更新 $kind #$id（${pts.length} 點）');
      final r = await _rosbridge.callService(
        '/edit_zone',
        args: {
          'op': 'update',
          'kind': kind,
          'id': id,
          'points': pts.map((p) => {'x': p.x, 'y': p.y, 'z': 0.0}).toList(),
        },
      );
      if (!r.success) {
        _addLog('ERROR', r.message.isEmpty ? '更新失敗' : r.message);
        // Restore for retry — but only if the user hasn't started another
        // edit/draw during the async gap (don't clobber the new one).
        if (!editVertexMode && !drawMode) {
          editVertexMode = true;
          editKind = kind;
          editId = id;
          editPolygon = pts;
        }
        notifyListeners();
        return;
      }
      _addLog('SUCCESS', r.message.isEmpty ? '已更新 $kind #$id' : r.message);
      // Keep the edited shape visible during the replan (same shape the
      // backend republishes) instead of snapping back to the old points.
      _updateObjectLocally(kind, id, pts);
      _invalidateCoverageReadiness();
      await _replanAfterEdit();
    } finally {
      _planningMutationPending = false;
      notifyListeners();
    }
  }

  void _updateObjectLocally(String kind, int id, List<MapPoint> pts) {
    switch (kind) {
      case 'zone':
        zones = zones
            .map(
              (z) => z.id == id
                  ? MissionZone(
                      id: z.id,
                      name: z.name,
                      points: pts,
                      hasCoveragePath: z.hasCoveragePath,
                    )
                  : z,
            )
            .toList();
      case 'risk':
        riskZones = riskZones
            .map(
              (z) => z.id == id
                  ? MissionZone(id: z.id, name: z.name, points: pts)
                  : z,
            )
            .toList();
      case 'channel':
        channels = channels
            .map(
              (c) => c.id == id
                  ? ChannelPath(id: c.id, name: c.name, points: pts)
                  : c,
            )
            .toList();
    }
  }

  void startExecution() {
    if (_connectionSettingsPending ||
        _planningMutationPending ||
        _navOperationActive) {
      return;
    }
    if (zones.isEmpty || selectedZoneId == 0) {
      _addLog('WARN', '尚未選擇可執行的工作區');
      return;
    }
    if (recordingType != null || _recordCommandPending) {
      _addLog('WARN', '記錄流程進行中，不能開始自動導航');
      return;
    }
    if (manualControlActive) {
      _addLog('WARN', '請先停止手動移動，再開始自動導航');
      return;
    }
    if (mockDataEnabled) {
      navStatus = NavMockStatus.executing;
      selectedMode = MissionMode.run;
      _addLog('INFO', 'Demo：開始執行 Zone $selectedZoneId');
      notifyListeners();
      return;
    }
    if (!canStartMission) {
      final missing = <String>[
        if (!rosConnected) 'rosbridge',
        if (!robotOnline) '新鮮 heartbeat',
        if (!_hasNavStatusSnapshot) '可確認的 Nav2 狀態',
        if (!_navigationAdmissionReady)
          _navigationAdmissionBlockReason ?? '後端導航安全條件',
        if (!hasFreshRobotPose) '新鮮 pose',
        if (!hasFreshGpsFix) '有效 GPS fix',
        if (!coverageReady) 'coverage path',
        if (!zones.any(
          (zone) => zone.id == selectedZoneId && zone.hasCoveragePath,
        ))
          '選定 Zone 的 coverage path',
      ];
      _addLog('WARN', '無法開始任務：缺少 ${missing.join('、')}');
      return;
    }
    unawaited(_startRosExecution());
  }

  Future<void> _startRosExecution() async {
    if (_navCommandPending) {
      return;
    }
    final zoneId = selectedZoneId;
    _navCommandEpoch += 1;
    _navCommandPending = true;
    _cancelRequestedDuringStart = false;
    _cancelPending = false;
    _ambiguousCancelRetryTimer?.cancel();
    _ambiguousCancelRetryTimer = null;
    _addLog('INFO', '呼叫 /zone_exec_path Zone $zoneId');
    notifyListeners();
    final response = await _rosbridge.callService(
      '/zone_exec_path',
      args: {'zone_id': zoneId},
    );
    if (_isDisposed) {
      return;
    }
    final cancelWasRequested = _cancelRequestedDuringStart;
    // Invalidate any status request started before this ACK. An old `idle`
    // snapshot must never overwrite a newly accepted navigation goal.
    _navCommandEpoch += 1;
    _navCommandPending = false;
    _cancelRequestedDuringStart = false;
    if (response.success && !cancelWasRequested) {
      _ambiguousStartCancelRequired = false;
      _ambiguousCancelRetryTimer?.cancel();
      _ambiguousCancelRetryTimer = null;
      navStatus = NavMockStatus.executing;
      _navStatusPollFailures = 0;
      coverageProgress = 0.0;
      currentSegment = 0;
      selectedMode = MissionMode.run;
      _addLog(
        'SUCCESS',
        response.message.isEmpty ? '開始執行 Zone $zoneId' : response.message,
      );
    } else if (response.success) {
      // A stop request made while the start ACK was outstanding wins. A late
      // positive start ACK cannot restore "executing" or clear cancellation;
      // re-confirm backend state and keep issuing bounded stop retries.
      _ambiguousStartCancelRequired = true;
      // A cancel ACK that preceded this late positive start ACK cannot prove
      // the newly accepted action is terminal. Require another stop attempt.
      _cancelPending = false;
      navStatus = NavMockStatus.paused;
      _hasNavStatusSnapshot = false;
      _lastNavStatusAt = null;
      _addLog('WARN', '開始 ACK 晚於取消要求；保持鎖定並持續確認停止');
      _scheduleAmbiguousCancelRetry();
      unawaited(_pollNavStatus());
    } else {
      // A timeout/disconnect is an ambiguous ACK: the backend may already be
      // running. Never expose a terminal state that would enable manual drive
      // until /check_nav_status confirms one.
      if (navStatus != NavMockStatus.executing) {
        navStatus = NavMockStatus.paused;
        _hasNavStatusSnapshot = false;
        _lastNavStatusAt = null;
      }
      final lowerMessage = response.message.toLowerCase();
      _ambiguousStartCancelRequired =
          cancelWasRequested ||
          !response.result ||
          lowerMessage.contains('outcome is uncertain') ||
          lowerMessage.contains('navigation may be active');
      if (cancelWasRequested) {
        _cancelPending = false;
      }
      if (!_ambiguousStartCancelRequired) {
        _ambiguousCancelRetryTimer?.cancel();
        _ambiguousCancelRetryTimer = null;
      }
      _addLog(
        'ERROR',
        response.message.isEmpty
            ? 'Zone $zoneId 開始結果未確認，正在查詢導航狀態'
            : response.message,
      );
      if (_ambiguousStartCancelRequired) {
        _scheduleAmbiguousCancelRetry();
      }
      unawaited(_pollNavStatus());
    }
    notifyListeners();
  }

  void cancelExecution() {
    if (_cancelRequestInFlight || _cancelPending) {
      return;
    }
    if (mockDataEnabled) {
      navStatus = NavMockStatus.idle;
      _addLog('WARN', 'Demo：導航已取消');
      notifyListeners();
      return;
    }
    // Cancellation is intentionally less strict than start/manual control:
    // when heartbeat is stale but rosbridge is reachable, a stop attempt is
    // still the safest action available.
    if (!rosConnected) {
      navStatus = NavMockStatus.paused;
      _addLog('ERROR', '無法取消導航：rosbridge 未連線');
      notifyListeners();
      return;
    }
    if (!_navCommandPending &&
        navStatus != NavMockStatus.executing &&
        navStatus != NavMockStatus.paused) {
      return;
    }
    if (_navCommandPending) {
      _cancelRequestedDuringStart = true;
      _ambiguousStartCancelRequired = true;
      _addLog('WARN', '開始 ACK 尚未回覆；立即送出獨立取消要求');
    }
    unawaited(_cancelRosExecution());
  }

  Future<void> _cancelRosExecution() async {
    if (_cancelRequestInFlight || _isDisposed || !rosConnected) {
      return;
    }
    _navCommandEpoch += 1;
    _cancelRequestInFlight = true;
    notifyListeners();
    late final RosbridgeServiceResponse response;
    try {
      response = await _rosbridge.callService('/cancel_nav2');
    } catch (error) {
      _cancelRequestInFlight = false;
      _cancelPending = false;
      _addLog('ERROR', '導航取消要求失敗: $error');
      if (_ambiguousStartCancelRequired) {
        _scheduleAmbiguousCancelRetry();
      }
      return;
    }
    if (_isDisposed) {
      return;
    }
    // Status responses initiated before this cancellation ACK are stale. A
    // fresh post-ACK idle/canceled snapshot is required to unlock controls.
    _navCommandEpoch += 1;
    _cancelRequestInFlight = false;
    _cancelPending = response.success;
    _addLog(
      response.success ? 'WARN' : 'ERROR',
      response.message.isEmpty
          ? response.success
                ? '已送出導航取消要求，等待後端確認'
                : '導航取消失敗'
          : response.message,
    );
    notifyListeners();
    if (_ambiguousStartCancelRequired) {
      _scheduleAmbiguousCancelRetry();
    }
    if (response.success) {
      unawaited(_pollNavStatus());
    }
  }

  void _scheduleAmbiguousCancelRetry() {
    if (_isDisposed ||
        !_ambiguousStartCancelRequired ||
        mockDataEnabled ||
        !rosConnected ||
        _ambiguousCancelRetryTimer?.isActive == true) {
      return;
    }
    _ambiguousCancelRetryTimer = Timer(_ambiguousCancelRetryInterval, () {
      _ambiguousCancelRetryTimer = null;
      if (_ambiguousStartCancelRequired &&
          !_cancelRequestInFlight &&
          rosConnected &&
          !mockDataEnabled) {
        unawaited(_cancelRosExecution());
      }
    });
  }

  void _clearAmbiguousCancelRetry() {
    _ambiguousStartCancelRequired = false;
    _ambiguousCancelRetryTimer?.cancel();
    _ambiguousCancelRetryTimer = null;
  }

  Future<void> _pollNavStatus() async {
    if (_navStatusCheckInFlight ||
        _connectionSettingsPending ||
        mockDataEnabled ||
        !rosConnected) {
      return;
    }
    final connectionGeneration = _connectionGeneration;
    final navCommandEpoch = _navCommandEpoch;
    _navStatusCheckInFlight = true;
    late final RosbridgeServiceResponse response;
    try {
      response = await _rosbridge.callService(
        '/check_nav_status',
        timeout: const Duration(seconds: 4),
      );
    } catch (error) {
      if (connectionGeneration == _connectionGeneration &&
          !mockDataEnabled &&
          rosConnected) {
        _handleNavStatusPollFailure('導航狀態查詢失敗: $error');
      }
      return;
    } finally {
      _navStatusCheckInFlight = false;
    }
    if (connectionGeneration != _connectionGeneration ||
        navCommandEpoch != _navCommandEpoch ||
        mockDataEnabled ||
        !rosConnected) {
      return;
    }

    final message = response.message.trim();
    String? state;
    String detail = message;
    bool? admissionReady;
    String? admissionBlockReason;
    final jsonLooking = message.startsWith('{') || message.startsWith('[');
    if (jsonLooking) {
      try {
        final decoded = jsonDecode(message);
        if (decoded is Map) {
          final rawState = decoded['state'];
          state = rawState is String ? rawState.trim().toLowerCase() : null;
          detail = decoded['message']?.toString() ?? message;
          admissionReady = decoded['ready'] is bool
              ? decoded['ready'] as bool
              : null;
          final rawBlockReason = decoded['block_reason'];
          admissionBlockReason = rawBlockReason is String
              ? rawBlockReason.trim()
              : null;
        }
      } on FormatException {
        // JSON-looking responses are never interpreted as legacy text. A
        // truncated payload containing `idle` must remain fail-closed.
      }
    } else {
      state = _legacyNavState(message);
    }
    const validStates = {
      'idle',
      'pending_confirmation',
      'starting',
      'running',
      'canceling',
      'completed',
      'canceled',
      'failed',
      'uncertain',
    };
    if (!response.success || !validStates.contains(state)) {
      _handleNavStatusPollFailure(
        response.success
            ? '導航狀態回應無法辨識'
            : response.message.isEmpty
            ? '無法取得導航狀態'
            : response.message,
      );
      return;
    }

    _navStatusPollFailures = 0;
    _hasNavStatusSnapshot = true;
    _lastNavStatusAt = DateTime.now();
    _navigationAdmissionReady = admissionReady == true;
    _navigationAdmissionBlockReason = admissionBlockReason?.isEmpty == true
        ? null
        : admissionBlockReason;
    final previous = navStatus;
    switch (state) {
      case 'pending_confirmation':
      case 'starting':
      case 'running':
        if (manualControlActive) {
          stopManualControl();
          _addLog('WARN', '偵測到外部導航執行，已停止手動速度輸出');
        }
        navStatus = NavMockStatus.executing;
        _cancelPending = false;
        _cancelRecordingForExternalNavigation();
        break;
      case 'canceling':
        if (manualControlActive) {
          stopManualControl();
          _addLog('WARN', '偵測到外部導航取消中，已停止手動速度輸出');
        }
        navStatus = NavMockStatus.executing;
        _cancelPending = true;
        _cancelRecordingForExternalNavigation();
        break;
      case 'completed':
        _clearAmbiguousCancelRetry();
        _externalRecordCancelAttempted = false;
        navStatus = NavMockStatus.idle;
        _cancelPending = false;
        coverageProgress = 1.0;
        break;
      case 'canceled':
        _clearAmbiguousCancelRetry();
        _externalRecordCancelAttempted = false;
        navStatus = NavMockStatus.idle;
        _cancelPending = false;
        break;
      case 'idle':
        if (_ambiguousStartCancelRequired && !_cancelPending) {
          // `idle` can be an uncorrelated snapshot from before a start/cancel
          // overlap. Only accept it after a later cancel ACK; explicit
          // canceled/completed/failed states remain terminal immediately.
          navStatus = NavMockStatus.paused;
          _navigationAdmissionReady = false;
          _navigationAdmissionBlockReason =
              'navigation start/cancel outcome is still uncertain';
        } else {
          _clearAmbiguousCancelRetry();
          _externalRecordCancelAttempted = false;
          navStatus = NavMockStatus.idle;
          _cancelPending = false;
        }
        break;
      case 'failed':
        _clearAmbiguousCancelRetry();
        _externalRecordCancelAttempted = false;
        navStatus = NavMockStatus.failed;
        _cancelPending = false;
        break;
      case 'uncertain':
        if (manualControlActive) {
          stopManualControl();
          _addLog('WARN', '導航狀態不確定，已停止手動速度輸出');
        }
        navStatus = NavMockStatus.paused;
        _cancelPending = false;
        _cancelRecordingForExternalNavigation();
        break;
    }
    if (_ambiguousStartCancelRequired && state != 'canceling') {
      _addLog('WARN', '開始結果不確定；持續要求取消直到後端確認終止');
      _scheduleAmbiguousCancelRetry();
    }
    if (navStatus != previous ||
        state == 'completed' ||
        state == 'canceled' ||
        state == 'failed') {
      final level = state == 'failed' || state == 'uncertain'
          ? 'ERROR'
          : state == 'pending_confirmation' ||
                state == 'starting' ||
                state == 'running' ||
                state == 'canceling'
          ? 'INFO'
          : 'SUCCESS';
      _addLog(level, detail.isEmpty ? '導航狀態：$state' : detail);
    }
    notifyListeners();
  }

  void _cancelRecordingForExternalNavigation() {
    if (recordingType == null ||
        _recordCommandPending ||
        _externalRecordCancelAttempted) {
      return;
    }
    _externalRecordCancelAttempted = true;
    unawaited(_cancelRecordingAfterExternalNavigation());
  }

  Future<void> _cancelRecordingAfterExternalNavigation() async {
    final canceled = await stopRecording(save: false);
    _addLog(
      canceled ? 'WARN' : 'ERROR',
      canceled ? '偵測到外部導航，已取消手動路徑記錄' : '外部導航已啟動，但記錄取消未獲後端確認',
    );
  }

  void _handleNavStatusPollFailure(String message) {
    final wasAvailable = _hasNavStatusSnapshot || _lastNavStatusAt != null;
    _hasNavStatusSnapshot = false;
    _navigationAdmissionReady = false;
    _navigationAdmissionBlockReason = null;
    _lastNavStatusAt = null;
    _navStatusPollFailures += 1;
    if (_ambiguousStartCancelRequired) {
      _scheduleAmbiguousCancelRetry();
    }
    if (manualControlActive) {
      stopManualControl();
      _addLog('WARN', '導航狀態已失效，已停止手動速度輸出');
    }
    if (_navStatusPollFailures == 3) {
      navStatus = NavMockStatus.paused;
      _cancelPending = false;
      _addLog('ERROR', message.isEmpty ? '連續無法取得導航狀態' : message);
      return;
    }
    if (wasAvailable) {
      notifyListeners();
    }
  }

  String? _legacyNavState(String message) {
    // Compatibility for the old plain-text endpoint is deliberately strict:
    // the state must be the complete message (optionally prefixed by
    // "Navigation" and followed by colon-delimited detail). Substring
    // matching would classify text such as "Navigation is not idle" as a
    // fresh terminal state and could re-enable motion controls.
    final match = RegExp(
      r'^(?:navigation\s+)?(idle|pending_confirmation|starting|running|canceling|completed|canceled|failed|uncertain)(?:\s*:\s*.+)?$',
      caseSensitive: false,
    ).firstMatch(message.trim());
    return match?.group(1)?.toLowerCase();
  }

  void addMockAction(String message) {
    _addLog('INFO', message);
  }

  bool publishManualVelocity({
    required double linearX,
    required double angularZ,
  }) {
    final moving = linearX.abs() > 0.001 || angularZ.abs() > 0.001;
    if (!moving) {
      final sent = _rosbridge.publish(
        manualVelocityTopic,
        type: _manualVelocityType,
        message: _twistStampedMessage(linearX: 0, angularZ: 0),
      );
      final wasActive = manualControlActive;
      manualControlActive = false;
      _manualSessionNeedsNeutral = false;
      if (wasActive) {
        notifyListeners();
      }
      return sent;
    }
    if (!canDriveManually) {
      if (!canControlRobot && !_hasLoggedManualDisconnected) {
        _hasLoggedManualDisconnected = true;
        _addLog('WARN', '手動控制需要 rosbridge 與新鮮的機器人 heartbeat');
      } else if (canControlRobot && !_hasLoggedManualBlocked) {
        _hasLoggedManualBlocked = true;
        _addLog(
          'WARN',
          _recordCommandPending
              ? '記錄命令處理中，暫停手動移動'
              : !_hasFreshManualCommandClock
              ? '尚未收到機器人手動命令時鐘，不輸出速度'
              : !hasFreshNavStatusSnapshot
              ? '導航狀態尚未確認，不能輸出手動速度'
              : '自動導航進行中，不能輸出手動速度',
        );
      }
      return false;
    }
    final sent = _rosbridge.publish(
      manualVelocityTopic,
      type: _manualVelocityType,
      message: _twistStampedMessage(linearX: linearX, angularZ: angularZ),
    );

    if (!sent) {
      if (moving && !_hasLoggedManualDisconnected) {
        _hasLoggedManualDisconnected = true;
        _addLog('WARN', '手動控制需要 rosbridge 連線');
      }
      return false;
    }

    _hasLoggedManualDisconnected = false;
    _hasLoggedManualBlocked = false;
    if (manualControlActive != moving) {
      manualControlActive = moving;
      if (moving) {
        _addLog('INFO', '手動控制輸出 $manualVelocityTopic', notify: false);
      }
      notifyListeners();
    }
    return true;
  }

  void stopManualControl() {
    final wasActive = manualControlActive;
    final sent = _rosbridge.publish(
      manualVelocityTopic,
      type: _manualVelocityType,
      message: _twistStampedMessage(linearX: 0, angularZ: 0),
    );
    manualControlActive = false;
    _manualSessionNeedsNeutral = false;
    _hasLoggedManualBlocked = false;
    if (wasActive) {
      _addLog(
        sent ? 'INFO' : 'WARN',
        sent ? '手動控制已停止' : '手動控制停止命令未送出，rosbridge 未連線',
        notify: false,
      );
      notifyListeners();
    }
  }

  Map<String, dynamic> _twistStampedMessage({
    required double linearX,
    required double angularZ,
  }) {
    return {
      'header': {
        'stamp': {
          // Echo the robot-issued clock. The robot-side manual guard validates
          // freshness and ordering without trusting the phone/browser clock.
          'sec': _manualCommandClockSec ?? 0,
          'nanosec': _manualCommandClockNanosec ?? 0,
        },
        'frame_id': _manualCommandSessionId ?? 'manual-session-unavailable',
      },
      'twist': {
        'linear': {'x': linearX, 'y': 0.0, 'z': 0.0},
        'angular': {'x': 0.0, 'y': 0.0, 'z': angularZ},
      },
    };
  }

  String navStatusLabel() {
    if (_cancelRequestInFlight || _cancelPending) {
      return '取消中';
    }
    if (_navCommandPending && navStatus != NavMockStatus.executing) {
      return '送出中';
    }
    switch (navStatus) {
      case NavMockStatus.idle:
        return '待命';
      case NavMockStatus.executing:
        return '執行中';
      case NavMockStatus.paused:
        return '狀態中斷';
      case NavMockStatus.failed:
        return '異常';
    }
  }

  void _tick() {
    _tickCount += 1;
    _updateRobotOnline();
    if (!mockDataEnabled && rosConnected) {
      unawaited(_pollNavStatus());
    }
    if (mockDataEnabled && !_hasLiveRobotPose) {
      _advanceRobot();
    }
    // Mock fake-counter only in the pure-mock fallback. During a real
    // recording recordPointCount is owned solely by _appendRecordTrail, so
    // gate this on !rosConnected to avoid the two writers fighting.
    if (recordingType != null && mockDataEnabled) {
      recordPointCount += 2;
    }
    if (navStatus == NavMockStatus.executing &&
        mockDataEnabled &&
        !liveDataActive &&
        coverageRows.isNotEmpty) {
      coverageProgress = (coverageProgress + 0.018).clamp(0.0, 1.0).toDouble();
      currentSegment = (coverageProgress * coverageRows.length)
          .ceil()
          .clamp(1, coverageRows.length)
          .toInt();
      if (coverageProgress >= 1.0) {
        navStatus = NavMockStatus.idle;
        _addLog('SUCCESS', 'Zone $selectedZoneId 執行完成', notify: false);
      }
    }
    notifyListeners();
  }

  void _advanceRobot() {
    final route = coverageRows.expand((row) => row).toList();
    if (route.length < 2) {
      return;
    }

    final totalSteps = (route.length - 1) * 8;
    final step = _tickCount % totalSteps;
    final index = (step / 8).floor();
    final localT = (step % 8) / 8.0;
    final from = route[index];
    final to = route[index + 1];
    robotPosition = MapPoint.lerp(from, to, localT);
    robotHeadingRad = math.atan2(to.y - from.y, to.x - from.x);
  }

  void _ensureSelectedZone() {
    if (zones.isEmpty) {
      return;
    }
    if (!zones.any((zone) => zone.id == selectedZoneId)) {
      selectedZoneId = zones.first.id;
    }
  }

  void _clearLiveReadiness() {
    robotOnline = false;
    _lastHeartbeatAt = null;
    _lastHeartbeatData = false;
    _batteryPercent = null;
    _lastBatteryAt = null;
    _clearGpsFix(resetSourceHighWater: true);
    _clearManualCommandClock();
    _hasLiveRobotPose = false;
    _lastRobotPoseAt = null;
    _hasNavStatusSnapshot = false;
    _lastNavStatusAt = null;
    _navStatusPollFailures = 0;
    _cancelPending = false;
    _cancelRequestInFlight = false;
    _cancelRequestedDuringStart = false;
    _clearAmbiguousCancelRetry();
    _loggedRejectedMapDatumSources.clear();
  }

  void _clearMissionData() {
    zones = const <MissionZone>[];
    riskZones = const <MissionZone>[];
    channels = const <ChannelPath>[];
    coverageRows = const <List<MapPoint>>[];
    invalidSegments = const <InvalidSegment>[];
    _zoneCoverageById.clear();
    mapGeoAnchor = null;
    sites = const <SiteInfo>[];
    activeSiteName = null;
    freeSpaceLayer?.dispose();
    freeSpaceLayer = null;
    riskMapLayer?.dispose();
    riskMapLayer = null;
    channelMapLayer?.dispose();
    channelMapLayer = null;
    freeSpaceReady = false;
    riskMapReady = false;
    channelMapReady = false;
    coverageReady = false;
    coverageProgress = 0.0;
    currentSegment = 0;
    selectedZoneId = 0;
    navStatus = NavMockStatus.idle;
    _hasLiveRobotPose = false;
    _lastRobotPoseAt = null;
    robotPosition = const MapPoint(0, 0);
    robotHeadingRad = 0.0;
  }

  void _restoreDemoData() {
    zones = List<MissionZone>.of(_demoZones);
    riskZones = List<MissionZone>.of(_demoRiskZones);
    channels = List<ChannelPath>.of(_demoChannels);
    coverageRows = _copyRows(_demoCoverageRows);
    invalidSegments = List<InvalidSegment>.of(_demoInvalidSegments);
    freeSpaceReady = true;
    riskMapReady = true;
    channelMapReady = true;
    coverageReady = true;
    coverageProgress = 0.42;
    currentSegment = 3;
    selectedZoneId = 1;
    robotPosition = const MapPoint(23, 44);
    robotHeadingRad = 0.3;
    navStatus = NavMockStatus.idle;
    _hasLiveRobotPose = false;
    _lastRobotPoseAt = null;
  }

  void _clearCameraFrames() {
    frontCameraFrame?.dispose();
    frontCameraFrame = null;
    rearCameraFrame?.dispose();
    rearCameraFrame = null;
    frontCameraError = null;
    rearCameraError = null;
  }

  void _addLog(String level, String message, {bool notify = true}) {
    _logs.insert(
      0,
      MissionLogEntry(time: _formatNow(), level: level, message: message),
    );
    if (_logs.length > 24) {
      _logs.removeRange(24, _logs.length);
    }
    if (notify) {
      notifyListeners();
    }
  }

  String _recordTypeName(RecordObjectType type) {
    switch (type) {
      case RecordObjectType.zone:
        return '工作區記錄';
      case RecordObjectType.risk:
        return '禁入區記錄';
      case RecordObjectType.channel:
        return '通道記錄';
    }
  }

  String _formatNow() {
    final now = DateTime.now();
    final hour = now.hour.toString().padLeft(2, '0');
    final minute = now.minute.toString().padLeft(2, '0');
    final second = now.second.toString().padLeft(2, '0');
    return '$hour:$minute:$second';
  }

  @override
  void dispose() {
    _isDisposed = true;
    _timer?.cancel();
    _ambiguousCancelRetryTimer?.cancel();
    _rosMessages?.cancel();
    _rosStates?.cancel();
    if (_ownsRosbridge) {
      _rosbridge.dispose();
    }
    freeSpaceLayer?.dispose();
    riskMapLayer?.dispose();
    channelMapLayer?.dispose();
    _clearCameraFrames();
    super.dispose();
  }
}

double? _asDouble(dynamic value) {
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value);
  }
  return null;
}

bool _receiptIsFresh(DateTime? receivedAt, Duration timeout) {
  if (receivedAt == null) {
    return false;
  }
  final age = DateTime.now().difference(receivedAt);
  // Wall-clock rollback must fail closed until the next telemetry sample
  // establishes a timestamp in the new clock domain.
  return !age.isNegative && age <= timeout;
}

int? _rosStampMicroseconds(dynamic rawStamp) {
  if (rawStamp is! Map) {
    return null;
  }
  final sec = _asEnumInt(rawStamp['sec']);
  final nanosec = _asEnumInt(rawStamp['nanosec']);
  if (sec == null ||
      sec < 0 ||
      nanosec == null ||
      nanosec < 0 ||
      nanosec >= 1000000000 ||
      (sec == 0 && nanosec == 0)) {
    return null;
  }
  // Microseconds keep current epoch values exactly representable on Flutter
  // Web while remaining far finer than the 50 ms robot clock cadence.
  return sec * 1000000 + nanosec ~/ 1000;
}

int? _asInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

int? _asEnumInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    final number = value.toDouble();
    if (number.isFinite && number == number.truncateToDouble()) {
      return number.toInt();
    }
    return null;
  }
  if (value is String) {
    return int.tryParse(value);
  }
  return null;
}

double? _horizontalCovarianceSigma(dynamic rawCovariance) {
  if (rawCovariance is! List || rawCovariance.length < 9) {
    return null;
  }
  final varianceX = _asDouble(rawCovariance[0]);
  final covarianceXY = _asDouble(rawCovariance[1]);
  final covarianceYX = _asDouble(rawCovariance[3]);
  final varianceY = _asDouble(rawCovariance[4]);
  final entries = [varianceX, covarianceXY, covarianceYX, varianceY];
  if (entries.any((entry) => entry == null || !entry.isFinite) ||
      varianceX! < 0 ||
      varianceY! < 0) {
    return null;
  }

  // A covariance matrix must be symmetric. Allow only tiny serialization
  // noise; larger disagreement is malformed telemetry and stays fail-closed.
  final symmetryScale = math.max(
    1.0,
    math.max(
      math.max(varianceX.abs(), varianceY.abs()),
      math.max(covarianceXY!.abs(), covarianceYX!.abs()),
    ),
  );
  if ((covarianceXY - covarianceYX).abs() > 1e-6 * symmetryScale) {
    return null;
  }

  final cross = (covarianceXY + covarianceYX) / 2.0;
  final determinant = varianceX * varianceY - cross * cross;
  final determinantScale = math.max(
    1.0,
    math.max((varianceX * varianceY).abs(), (cross * cross).abs()),
  );
  if (determinant < -1e-9 * determinantScale) {
    return null;
  }

  // The largest eigenvalue is the variance along the major axis of the
  // horizontal uncertainty ellipse. max(varX, varY) can underestimate it
  // when X/Y errors are correlated.
  final halfTrace = (varianceX + varianceY) / 2.0;
  final halfDifference = (varianceX - varianceY) / 2.0;
  final largestEigenvalue =
      halfTrace +
      math.sqrt(math.max(0.0, halfDifference * halfDifference + cross * cross));
  final smallestEigenvalue =
      halfTrace -
      math.sqrt(math.max(0.0, halfDifference * halfDifference + cross * cross));
  if (!largestEigenvalue.isFinite ||
      !smallestEigenvalue.isFinite ||
      smallestEigenvalue <= 1e-12) {
    return null;
  }
  return math.sqrt(largestEigenvalue);
}

double _yawFromQuaternion(Map<String, dynamic> q) {
  final x = _asDouble(q['x']) ?? 0.0;
  final y = _asDouble(q['y']) ?? 0.0;
  final z = _asDouble(q['z']) ?? 0.0;
  final w = _asDouble(q['w']) ?? 1.0;
  final sinyCosp = 2.0 * (w * z + x * y);
  final cosyCosp = 1.0 - 2.0 * (y * y + z * z);
  return math.atan2(sinyCosp, cosyCosp);
}

List<List<MapPoint>> _copyRows(List<List<MapPoint>> rows) {
  return rows.map((row) => List<MapPoint>.of(row)).toList();
}

const _demoZones = [
  MissionZone(
    id: 1,
    name: '主工作區',
    hasCoveragePath: true,
    points: [
      MapPoint(14, 33),
      MapPoint(57, 23),
      MapPoint(83, 49),
      MapPoint(76, 109),
      MapPoint(29, 123),
      MapPoint(10, 83),
    ],
  ),
  MissionZone(
    id: 2,
    name: '棚架示範區',
    hasCoveragePath: true,
    points: [
      MapPoint(58, 17),
      MapPoint(87, 19),
      MapPoint(92, 38),
      MapPoint(74, 47),
      MapPoint(55, 35),
    ],
  ),
];

const _demoRiskZones = [
  MissionZone(
    id: 1,
    name: '禁入區 A',
    points: [
      MapPoint(42, 61),
      MapPoint(56, 57),
      MapPoint(64, 74),
      MapPoint(50, 85),
      MapPoint(38, 73),
    ],
  ),
];

const _demoChannels = [
  ChannelPath(
    id: 1,
    name: '通道 1',
    points: [
      MapPoint(12, 130),
      MapPoint(28, 120),
      MapPoint(52, 126),
      MapPoint(74, 118),
      MapPoint(94, 127),
    ],
  ),
];

const _demoCoverageRows = [
  [MapPoint(20, 42), MapPoint(61, 34)],
  [MapPoint(67, 47), MapPoint(18, 55)],
  [MapPoint(18, 66), MapPoint(72, 58)],
  [MapPoint(74, 70), MapPoint(19, 79)],
  [MapPoint(21, 91), MapPoint(73, 83)],
  [MapPoint(70, 96), MapPoint(25, 107)],
  [MapPoint(31, 117), MapPoint(66, 110)],
];

const _demoInvalidSegments = [
  InvalidSegment(id: 1, points: [MapPoint(52, 76), MapPoint(65, 74)]),
  InvalidSegment(id: 2, points: [MapPoint(34, 103), MapPoint(49, 108)]),
];
