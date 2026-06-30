import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/image_mission_draft.dart';
import '../models/mission_mock.dart';
import '../services/image_mission_processor.dart';
import '../services/rosbridge_service.dart';

class MissionMockProvider extends ChangeNotifier {
  static const _mockDataPreferenceKey = 'mock_data_enabled';
  static const manualVelocityTopic = '/joy_cmd';
  static const frontCameraTopic = '/front_depth_camera/image_raw';
  static const rearCameraTopic = '/back_camera/image_raw';
  static const _manualVelocityType = 'geometry_msgs/msg/TwistStamped';
  static const _cameraImageType = 'sensor_msgs/msg/Image';

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
  bool _hasLoggedManualDisconnected = false;

  MissionMode selectedMode = MissionMode.objects;
  RecordObjectType? recordingType;
  CoveragePatternKind coveragePattern = CoveragePatternKind.zigzag;
  // True once a custom image mission has been imported into the backend; used
  // to restore full-freespace coverage when switching back to zigzag/spiral.
  bool _imageMissionActive = false;
  NavMockStatus navStatus = NavMockStatus.idle;
  MissionLayerVisibility layers = const MissionLayerVisibility();

  MapPoint robotPosition = const MapPoint(23, 44);
  double robotHeadingRad = 0.3;
  double coverageProgress = 0.42;
  double stripWidthM = 0.8;
  int selectedZoneId = 1;
  int currentSegment = 3;
  int recordPointCount = 0;
  bool freeSpaceReady = true;
  bool riskMapReady = true;
  bool channelMapReady = true;
  bool coverageReady = true;
  bool rosConnected = false;

  /// Whether the robot itself is alive (LWT-style), from the `/robot/online`
  /// heartbeat. Distinct from [rosConnected] (app<->rosbridge link): the robot
  /// can be offline while rosbridge is still up.
  bool robotOnline = false;
  DateTime? _lastHeartbeatAt;
  bool _lastHeartbeatData = false;
  static const Duration _heartbeatTimeout = Duration(seconds: 3);

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
  DateTime? _coveragePatternEditedAt;
  static const _editGrace = Duration(seconds: 2);
  bool liveDataActive = false;
  bool mockDataEnabled = true;
  bool manualControlActive = false;

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

  /// Whether a real `/adapter/robot_pose` has been received (the default robot
  /// has a live pose). Consumed by [RobotFleetProvider.syncFromMission].
  bool get hasLiveRobotPose => _hasLiveRobotPose;

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
      frontCameraTopic,
      type: _cameraImageType,
      throttleRateMs: 150,
    );
    _rosbridge.subscribe(
      rearCameraTopic,
      type: _cameraImageType,
      throttleRateMs: 150,
    );

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
    _clearCameraFrames();
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
      _hasLoggedManualDisconnected = false;
      _addLog('SUCCESS', 'rosbridge 已連線');
    } else {
      manualControlActive = false;
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
    final fresh =
        last != null && DateTime.now().difference(last) <= _heartbeatTimeout;
    final next = rosConnected && fresh && _lastHeartbeatData;
    if (next != robotOnline) {
      robotOnline = next;
      _addLog(next ? 'SUCCESS' : 'WARN', next ? '機器人上線' : '機器人離線');
      notifyListeners();
    }
  }

  void _handleRosMessage(RosbridgeTopicMessage event) {
    try {
      switch (event.topic) {
        case frontCameraTopic:
          unawaited(
            _decodeAndStoreCameraFrame(CameraFeed.front, event.message),
          );
          break;
        case rearCameraTopic:
          unawaited(_decodeAndStoreCameraFrame(CameraFeed.rear, event.message));
          break;
        case '/adapter/robot_pose':
          _applyRobotPose(event.message);
          break;
        case '/robot/online':
          _lastHeartbeatAt = DateTime.now();
          _lastHeartbeatData = event.message['data'] == true;
          _updateRobotOnline();
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
              _applyMapLayer(name, dto);
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

  Future<void> _decodeAndStoreCameraFrame(
    CameraFeed feed,
    Map<String, dynamic> message,
  ) async {
    final topic = cameraTopic(feed);
    try {
      final frame = await _decodeCameraFrame(feed, topic, message);
      if (_isDisposed) {
        frame.dispose();
        return;
      }
      switch (feed) {
        case CameraFeed.front:
          frontCameraFrame?.dispose();
          frontCameraFrame = frame;
          frontCameraError = null;
          break;
        case CameraFeed.rear:
          rearCameraFrame?.dispose();
          rearCameraFrame = frame;
          rearCameraError = null;
          break;
      }
      notifyListeners();
    } on _CameraDecodeException catch (error) {
      if (_isDisposed) {
        return;
      }
      switch (feed) {
        case CameraFeed.front:
          frontCameraError = error.message;
          break;
        case CameraFeed.rear:
          rearCameraError = error.message;
          break;
      }
      notifyListeners();
    } catch (_) {
      if (_isDisposed) {
        return;
      }
      switch (feed) {
        case CameraFeed.front:
          frontCameraError = '影像解碼失敗';
          break;
        case CameraFeed.rear:
          rearCameraError = '影像解碼失敗';
          break;
      }
      notifyListeners();
    }
  }

  static Future<CameraFrame> _decodeCameraFrame(
    CameraFeed feed,
    String topic,
    Map<String, dynamic> message,
  ) async {
    final width = _asInt(message['width']);
    final height = _asInt(message['height']);
    final encoding = message['encoding']?.toString().toLowerCase();
    if (width == null || height == null || width <= 0 || height <= 0) {
      throw const _CameraDecodeException('影像尺寸無效');
    }
    if (encoding == null || encoding.isEmpty) {
      throw const _CameraDecodeException('影像格式未提供');
    }

    final bytes = _imageDataBytes(message['data']);
    final pixelStride = switch (encoding) {
      'rgb8' || 'bgr8' => 3,
      'rgba8' || 'bgra8' => 4,
      'mono8' => 1,
      _ => throw const _CameraDecodeException('影像格式未支援'),
    };
    final step = _asInt(message['step']) ?? width * pixelStride;
    if (step < width * pixelStride ||
        bytes.length < step * math.max(height - 1, 0) + width * pixelStride) {
      throw const _CameraDecodeException('影像資料長度不足');
    }

    final pixels = Uint8List(width * height * 4);
    for (var y = 0; y < height; y += 1) {
      final rowOffset = y * step;
      for (var x = 0; x < width; x += 1) {
        final source = rowOffset + x * pixelStride;
        final target = (y * width + x) * 4;
        switch (encoding) {
          case 'rgb8':
            pixels[target] = bytes[source];
            pixels[target + 1] = bytes[source + 1];
            pixels[target + 2] = bytes[source + 2];
            pixels[target + 3] = 255;
            break;
          case 'bgr8':
            pixels[target] = bytes[source + 2];
            pixels[target + 1] = bytes[source + 1];
            pixels[target + 2] = bytes[source];
            pixels[target + 3] = 255;
            break;
          case 'rgba8':
            pixels[target] = bytes[source];
            pixels[target + 1] = bytes[source + 1];
            pixels[target + 2] = bytes[source + 2];
            pixels[target + 3] = bytes[source + 3];
            break;
          case 'bgra8':
            pixels[target] = bytes[source + 2];
            pixels[target + 1] = bytes[source + 1];
            pixels[target + 2] = bytes[source];
            pixels[target + 3] = bytes[source + 3];
            break;
          case 'mono8':
            final value = bytes[source];
            pixels[target] = value;
            pixels[target + 1] = value;
            pixels[target + 2] = value;
            pixels[target + 3] = 255;
            break;
        }
      }
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
    return CameraFrame(
      feed: feed,
      topic: topic,
      encoding: encoding,
      width: width,
      height: height,
      image: image,
      receivedAt: DateTime.now(),
    );
  }

  static Uint8List _imageDataBytes(dynamic data) {
    if (data is String) {
      return base64Decode(data);
    }
    if (data is List) {
      return Uint8List.fromList(
        data
            .map((value) => _asInt(value) ?? 0)
            .map((value) => value & 0xFF)
            .toList(),
      );
    }
    throw const _CameraDecodeException('影像資料未提供');
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
    if (_coveragePatternEditedAt == null ||
        now.difference(_coveragePatternEditedAt!) > _editGrace) {
      final pattern = dto['coveragePattern']?.toString();
      if (pattern == 'spiral') {
        coveragePattern = CoveragePatternKind.spiral;
      } else if (pattern == 'zigzag') {
        coveragePattern = CoveragePatternKind.zigzag;
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
    _coveragePatternEditedAt = DateTime.now();
    _addLog('INFO', 'Coverage pattern set to ${pattern.name}');
    // 'custom' is the image-mission pipeline, not a boustrophedon sweep — the
    // backend coverage_pattern param only understands zigzag/spiral.
    if (rosConnected && pattern != CoveragePatternKind.custom) {
      unawaited(
        _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'coverage_pattern',
          pattern.name,
          type: 4,
        ),
      );
      // Leaving custom: discard the imported image, restore the full freespace
      // coverage area, and drop the perimeter ring.
      if (_imageMissionActive) {
        _imageMissionActive = false;
        unawaited(_rosbridge.callService('/restore_free_space_coverage'));
        unawaited(
          _setRosDoubleParam(
            '/boustrophedon_coverage/set_parameters',
            'boundary_ring',
            false,
            type: 1,
          ),
        );
        _addLog('INFO', '已切回完整自由空間（捨棄圖片範圍）');
      }
    }
  }

  void setStripWidth(double value) {
    stripWidthM = value;
    _stripWidthEditedAt = DateTime.now();
    if (rosConnected) {
      unawaited(
        _setRosDoubleParam(
          '/boustrophedon_coverage/set_parameters',
          'strip_width_m',
          value,
        ),
      );
    }
    notifyListeners();
  }

  void setImageMissionDraft(ImageMissionDraft draft) {
    imageMissionDraft = draft;
    selectedMode = MissionMode.plan;
    _addLog('INFO', '圖片任務已載入：${draft.sourceName}');
    notifyListeners();
  }

  void clearImageMissionDraft() {
    imageMissionDraft = null;
    _addLog('WARN', '圖片任務草稿已清除');
    notifyListeners();
  }

  void updateImageMissionThreshold(int threshold) {
    final draft = imageMissionDraft;
    if (draft == null) {
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
    if (draft == null) {
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
    if (draft == null) {
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
    if (draft == null) {
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
    if (draft == null) {
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
    if (draft == null) {
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
    if (draft == null || placement == null) {
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
    if (draft == null) {
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
    if (draft == null) {
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

    imageMissionDraft = draft.copyWith(submitting: true);
    notifyListeners();

    if (!rosConnected) {
      if (!mockDataEnabled) {
        imageMissionDraft = draft.copyWith(
          submitting: false,
          submitted: false,
          submitMessage: '請先連上 rosbridge',
        );
        _addLog('WARN', '圖片任務需要 rosbridge 連線');
        notifyListeners();
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
      // Custom missions add an outer-contour perimeter pass; set this BEFORE
      // generating so coverage_node reads it (await to guarantee ordering).
      await _setRosDoubleParam(
        '/boustrophedon_coverage/set_parameters',
        'boundary_ring',
        true,
        type: 1,
      );
      _addLog('SUCCESS', '圖片任務已匯入，準備生成 Coverage Path');
      unawaited(_runRosPlanningStep('coverage'));
    } else {
      _addLog(
        'ERROR',
        response.message.isEmpty ? '圖片任務匯入失敗' : response.message,
      );
    }
    notifyListeners();
    return success;
  }

  Map<String, double> _yawToQuaternion(double yaw) {
    final half = yaw / 2.0;
    return {'x': 0.0, 'y': 0.0, 'z': math.sin(half), 'w': math.cos(half)};
  }

  Future<void> _setRosDoubleParam(
    String service,
    String name,
    dynamic value, {
    int type = 3,
  }) async {
    await _rosbridge.callService(
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

  bool publishManualVelocity({
    required double linearX,
    required double angularZ,
  }) {
    final moving = linearX.abs() > 0.001 || angularZ.abs() > 0.001;
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
    final micros = DateTime.now().toUtc().microsecondsSinceEpoch;
    return {
      'header': {
        'stamp': {
          'sec': micros ~/ Duration.microsecondsPerSecond,
          'nanosec':
              (micros % Duration.microsecondsPerSecond) *
              Duration.microsecondsPerMillisecond,
        },
        'frame_id': 'base_link',
      },
      'twist': {
        'linear': {'x': linearX, 'y': 0.0, 'z': 0.0},
        'angular': {'x': 0.0, 'y': 0.0, 'z': angularZ},
      },
    };
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
    _updateRobotOnline();
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

class _CameraDecodeException implements Exception {
  const _CameraDecodeException(this.message);

  final String message;
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
