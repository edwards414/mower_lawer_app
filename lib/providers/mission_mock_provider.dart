import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/mission_mock.dart';
import '../services/rosbridge_service.dart';

class MissionMockProvider extends ChangeNotifier {
  static const _mockDataPreferenceKey = 'mock_data_enabled';

  MissionMockProvider({RosbridgeService? rosbridge})
    : _rosbridge = rosbridge ?? RosbridgeService(),
      _ownsRosbridge = rosbridge == null {
    _addLog('INFO', 'Demo mission data loaded', notify: false);
    _addLog('SUCCESS', 'Self check profile ready', notify: false);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    unawaited(_connectRosbridge());
  }

  final RosbridgeService _rosbridge;
  final bool _ownsRosbridge;
  Timer? _timer;
  StreamSubscription<RosbridgeTopicMessage>? _rosMessages;
  StreamSubscription<RosbridgeConnectionState>? _rosStates;
  int _tickCount = 0;
  DateTime? _recordingStartedAt;
  bool _hasLiveRobotPose = false;
  bool _hasLoggedRosFailure = false;

  MissionMode selectedMode = MissionMode.objects;
  RecordObjectType? recordingType;
  CoveragePatternKind coveragePattern = CoveragePatternKind.zigzag;
  NavMockStatus navStatus = NavMockStatus.idle;
  MissionLayerVisibility layers = const MissionLayerVisibility();

  MapPoint robotPosition = const MapPoint(23, 44);
  double robotHeadingRad = 0.3;
  double coverageProgress = 0.42;
  double stripWidthM = 0.8;
  double waypointSpacingM = 0.2;
  int selectedZoneId = 1;
  int currentSegment = 3;
  int recordPointCount = 0;
  bool freeSpaceReady = true;
  bool riskMapReady = true;
  bool channelMapReady = true;
  bool coverageReady = true;
  bool rosConnected = false;
  bool liveDataActive = false;
  bool mockDataEnabled = true;

  List<MissionZone> zones = List<MissionZone>.of(_demoZones);
  List<MissionZone> riskZones = List<MissionZone>.of(_demoRiskZones);
  List<ChannelPath> channels = List<ChannelPath>.of(_demoChannels);
  List<List<MapPoint>> coverageRows = _copyRows(_demoCoverageRows);
  List<InvalidSegment> invalidSegments = List<InvalidSegment>.of(
    _demoInvalidSegments,
  );

  final List<MissionLogEntry> _logs = [];

  List<MissionLogEntry> get logs => List.unmodifiable(_logs);
  String get rosbridgeUrl => _rosbridge.url;
  String get robotIp => _rosbridge.robotIp;
  bool get shouldShowRobot => mockDataEnabled || _hasLiveRobotPose;

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
    const stringTopics = [
      '/adapter/marker_layers/zones',
      '/adapter/marker_layers/risk_zones',
      '/adapter/marker_layers/channels',
      '/adapter/marker_layers/coverage_path',
      '/adapter/marker_layers/invalid_segments',
      '/adapter/marker_layers/connectors',
      '/adapter/map_layers/map_grid',
      '/adapter/map_layers/free_space_inflated',
      '/adapter/map_layers/risk_map_inflated',
      '/adapter/map_layers/chennal_map_inflated',
      '/adapter/coverage_settings',
      '/adapter/zone_summaries',
    ];

    for (final topic in stringTopics) {
      _rosbridge.subscribe(topic, throttleRateMs: 100);
    }
    _rosbridge.subscribe('/adapter/robot_pose', throttleRateMs: 100);

    _rosMessages = _rosbridge.messages.listen(_handleRosMessage);
    _rosStates = _rosbridge.states.listen(_handleRosState);
    _rosbridge.connect();
    notifyListeners();
  }

  Future<void> _loadMockDataPreference() async {
    final prefs = await SharedPreferences.getInstance();
    mockDataEnabled = prefs.getBool(_mockDataPreferenceKey) ?? true;
    if (!mockDataEnabled && !liveDataActive) {
      _clearMissionData();
      _addLog('INFO', 'Mock 資料已關閉，等待 ROS 真實資料', notify: false);
    }
  }

  Future<String?> updateRobotIp(String value) async {
    final error = RosbridgeService.validateRobotIp(value);
    if (error != null) {
      return error;
    }
    await _rosbridge.setRobotIp(value);
    rosConnected = false;
    liveDataActive = false;
    _hasLiveRobotPose = false;
    if (mockDataEnabled) {
      _restoreDemoData();
    } else {
      _clearMissionData();
    }
    _addLog('INFO', '機器人 IP 已設定為 ${_rosbridge.robotIp}');
    notifyListeners();
    return null;
  }

  Future<void> setMockDataEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_mockDataPreferenceKey, enabled);
    mockDataEnabled = enabled;

    if (!liveDataActive) {
      if (enabled) {
        _restoreDemoData();
      } else {
        _clearMissionData();
      }
    }

    _addLog(
      'INFO',
      enabled ? 'Mock 資料已開啟' : 'Mock 資料已關閉，等待 ROS 真實資料',
      notify: false,
    );
    notifyListeners();
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
      _addLog('SUCCESS', 'rosbridge 已連線');
    } else {
      _addLog('WARN', 'rosbridge 連線中斷，保留最後資料');
    }
    notifyListeners();
  }

  void _handleRosMessage(RosbridgeTopicMessage event) {
    try {
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
        default:
          final dto = _decodeStringMessage(event.message);
          if (dto is Map<String, dynamic>) {
            final name = dto['name']?.toString();
            if (dto.containsKey('markers')) {
              _applyMarkerLayer(name, dto);
            } else if (dto['type'] == 'occupancy_grid') {
              _applyMapLayer(name);
            }
          }
      }
    } catch (error) {
      _addLog('ERROR', 'rosbridge 資料解析失敗: $error');
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

  void _applyMapLayer(String? name) {
    switch (name) {
      case 'free_space_inflated':
        freeSpaceReady = true;
        break;
      case 'risk_map_inflated':
        riskMapReady = true;
        break;
      case 'chennal_map_inflated':
        channelMapReady = true;
        break;
    }
    liveDataActive = true;
    notifyListeners();
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
    stripWidthM = _asDouble(dto['stripWidthM']) ?? stripWidthM;
    waypointSpacingM = _asDouble(dto['waypointSpacingM']) ?? waypointSpacingM;
    final pattern = dto['coveragePattern']?.toString();
    if (pattern == 'spiral') {
      coveragePattern = CoveragePatternKind.spiral;
    } else if (pattern == 'zigzag') {
      coveragePattern = CoveragePatternKind.zigzag;
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
    liveDataActive = true;
    notifyListeners();
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
    if (!mockDataEnabled) {
      _addLog('WARN', 'Mock 記錄已關閉，等待 ROS 記錄流程串接');
      return;
    }
    recordingType = type;
    selectedMode = MissionMode.record;
    recordPointCount = 8;
    _recordingStartedAt = DateTime.now();
    _addLog('INFO', '開始${_recordTypeName(type)}');
  }

  void stopRecording({required bool save}) {
    final type = recordingType;
    if (type == null) {
      return;
    }
    _addLog(
      save ? 'SUCCESS' : 'WARN',
      '${_recordTypeName(type)}${save ? '已儲存' : '已取消'}',
    );
    recordingType = null;
    recordPointCount = 0;
    _recordingStartedAt = null;
    selectedMode = MissionMode.objects;
    notifyListeners();
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

  void setCoveragePattern(CoveragePatternKind pattern) {
    coveragePattern = pattern;
    _addLog('INFO', 'Coverage pattern set to ${pattern.name}');
  }

  void setStripWidth(double value) {
    stripWidthM = value;
    notifyListeners();
  }

  void setWaypointSpacing(double value) {
    waypointSpacingM = value;
    notifyListeners();
  }

  void runPlanningStep(String step) {
    if (rosConnected) {
      unawaited(_runRosPlanningStep(step));
      return;
    }
    if (!mockDataEnabled) {
      _addLog('WARN', 'Mock 資料已關閉，請先連上 rosbridge');
      return;
    }
    _runMockPlanningStep(step);
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
      switch (step) {
        case 'free_space':
          freeSpaceReady = true;
          break;
        case 'risk_map':
          riskMapReady = true;
          break;
        case 'channel_map':
          channelMapReady = true;
          break;
        case 'coverage':
          coverageReady = true;
          break;
      }
      _addLog(
        'SUCCESS',
        response.message.isEmpty ? '$service 完成' : response.message,
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
    selectedZoneId = zoneId;
    notifyListeners();
  }

  void startExecution() {
    if (rosConnected) {
      unawaited(_startRosExecution());
      return;
    }
    if (!mockDataEnabled) {
      _addLog('WARN', 'Mock 資料已關閉，請先連上 rosbridge');
      return;
    }
    navStatus = NavMockStatus.executing;
    selectedMode = MissionMode.run;
    _addLog('INFO', '開始執行 Zone $selectedZoneId');
    notifyListeners();
  }

  Future<void> _startRosExecution() async {
    _addLog('INFO', '呼叫 /zone_exec_path Zone $selectedZoneId');
    final response = await _rosbridge.callService(
      '/zone_exec_path',
      args: {'zone_id': selectedZoneId},
    );
    if (response.success) {
      navStatus = NavMockStatus.executing;
      selectedMode = MissionMode.run;
      _addLog(
        'SUCCESS',
        response.message.isEmpty
            ? '開始執行 Zone $selectedZoneId'
            : response.message,
      );
    } else {
      navStatus = NavMockStatus.failed;
      _addLog(
        'ERROR',
        response.message.isEmpty
            ? 'Zone $selectedZoneId 執行失敗'
            : response.message,
      );
    }
    notifyListeners();
  }

  void cancelExecution() {
    if (rosConnected) {
      unawaited(_cancelRosExecution());
      return;
    }
    navStatus = NavMockStatus.idle;
    _addLog('WARN', '導航已取消');
    notifyListeners();
  }

  Future<void> _cancelRosExecution() async {
    final response = await _rosbridge.callService('/cencel_nav2');
    navStatus = NavMockStatus.idle;
    _addLog(
      response.success ? 'WARN' : 'ERROR',
      response.message.isEmpty ? '導航已取消' : response.message,
    );
    notifyListeners();
  }

  void addMockAction(String message) {
    _addLog('INFO', message);
  }

  String navStatusLabel() {
    switch (navStatus) {
      case NavMockStatus.idle:
        return '待命';
      case NavMockStatus.executing:
        return '執行中';
      case NavMockStatus.paused:
        return '暫停';
      case NavMockStatus.failed:
        return '異常';
    }
  }

  void _tick() {
    _tickCount += 1;
    if (mockDataEnabled && !_hasLiveRobotPose) {
      _advanceRobot();
    }
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

  void _clearMissionData() {
    zones = const <MissionZone>[];
    riskZones = const <MissionZone>[];
    channels = const <ChannelPath>[];
    coverageRows = const <List<MapPoint>>[];
    invalidSegments = const <InvalidSegment>[];
    freeSpaceReady = false;
    riskMapReady = false;
    channelMapReady = false;
    coverageReady = false;
    coverageProgress = 0.0;
    currentSegment = 0;
    selectedZoneId = 0;
    navStatus = NavMockStatus.idle;
    _hasLiveRobotPose = false;
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
    _timer?.cancel();
    _rosMessages?.cancel();
    _rosStates?.cancel();
    if (_ownsRosbridge) {
      _rosbridge.dispose();
    }
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
