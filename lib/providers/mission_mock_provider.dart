import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/mission_mock.dart';

class MissionMockProvider extends ChangeNotifier {
  MissionMockProvider() {
    _addLog('INFO', 'Demo mission data loaded', notify: false);
    _addLog('SUCCESS', 'Self check profile ready', notify: false);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
  }

  Timer? _timer;
  int _tickCount = 0;
  DateTime? _recordingStartedAt;

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

  final List<MissionZone> zones = const [
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

  final List<MissionZone> riskZones = const [
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

  final List<ChannelPath> channels = const [
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

  final List<List<MapPoint>> coverageRows = const [
    [MapPoint(20, 42), MapPoint(61, 34)],
    [MapPoint(67, 47), MapPoint(18, 55)],
    [MapPoint(18, 66), MapPoint(72, 58)],
    [MapPoint(74, 70), MapPoint(19, 79)],
    [MapPoint(21, 91), MapPoint(73, 83)],
    [MapPoint(70, 96), MapPoint(25, 107)],
    [MapPoint(31, 117), MapPoint(66, 110)],
  ];

  final List<InvalidSegment> invalidSegments = const [
    InvalidSegment(id: 1, points: [MapPoint(52, 76), MapPoint(65, 74)]),
    InvalidSegment(id: 2, points: [MapPoint(34, 103), MapPoint(49, 108)]),
  ];

  final List<MissionLogEntry> _logs = [];

  List<MissionLogEntry> get logs => List.unmodifiable(_logs);

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

  void selectMode(MissionMode mode) {
    selectedMode = mode;
    notifyListeners();
  }

  void startRecording(RecordObjectType type) {
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
    navStatus = NavMockStatus.executing;
    selectedMode = MissionMode.run;
    _addLog('INFO', '開始執行 Zone $selectedZoneId');
    notifyListeners();
  }

  void cancelExecution() {
    navStatus = NavMockStatus.idle;
    _addLog('WARN', '導航已取消');
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
    _advanceRobot();
    if (recordingType != null) {
      recordPointCount += 2;
    }
    if (navStatus == NavMockStatus.executing) {
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
    super.dispose();
  }
}
