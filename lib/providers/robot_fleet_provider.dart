import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/mission_mock.dart';
import '../models/robot_fleet.dart';
import '../services/rosbridge_service.dart';
import 'mission_mock_provider.dart';

/// Discovers robots from the ROS graph (via rosapi) and tracks per-robot
/// liveness/pose/battery.
///
/// Discovery: every [_discoveryInterval] the provider calls `/rosapi/topics`
/// and treats every `std_msgs/msg/Bool` topic ending in `/online` as one robot
/// (namespace = the segment before `/online`). The un-namespaced `/robot/online`
/// is the default robot, whose pose/online are supplied by [MissionMockProvider]
/// (so we don't double-subscribe). Non-default robots get their own
/// `<ns>/online`, `<ns>/robot_pose`, `<ns>/battery_state` subscriptions.
///
/// Liveness: a robot whose heartbeat goes false or stops arriving for
/// [_staleAfter] is marked offline and rendered greyed at its last position
/// (kept in memory only). A robot absent from rosapi for [_removeAfter] is
/// removed and its topics unsubscribed.
///
/// Assumes all robots share the one ROS graph the app's rosbridge is connected
/// to. Robots on separate rosbridges/DOMAINs won't be discovered.
class RobotFleetProvider extends ChangeNotifier {
  RobotFleetProvider({required RosbridgeService rosbridge})
      : _rosbridge = rosbridge {
    _rosMessages = _rosbridge.messages.listen(_handleRosMessage);
    _discoveryTimer =
        Timer.periodic(_discoveryInterval, (_) => unawaited(_pollTopics()));
    _staleTimer = Timer.periodic(const Duration(seconds: 1), (_) => _staleTick());
    unawaited(_pollTopics());
  }

  static const _discoveryInterval = Duration(seconds: 5);
  static const _staleAfter = Duration(seconds: 3);
  static const _removeAfter = Duration(seconds: 60);
  static const _defaultNs = 'robot';
  static const _demoNs = 'demo';

  final RosbridgeService _rosbridge;
  StreamSubscription<RosbridgeTopicMessage>? _rosMessages;
  Timer? _discoveryTimer;
  Timer? _staleTimer;
  bool _isDisposed = false;

  int? _selectedRobotId;
  int _lastRowCount = -1;
  bool _demoActive = false;

  // Per-namespace state.
  final Map<String, int> _idByNs = {};
  final Set<String> _subscribedNs = {};
  final Map<String, DateTime> _lastSeen = {};
  final Map<String, bool> _lastOnlineData = {};
  final Map<String, MapPoint> _poseByNs = {};
  final Map<String, double> _headingByNs = {};
  final Map<String, double> _batteryByNs = {};
  final Map<String, DateTime> _absentSince = {};
  int _nextId = 0;

  // Default-robot fields injected from MissionMockProvider each build.
  MapPoint _defaultPose = const MapPoint(23, 44);
  double _defaultHeading = 0.0;
  bool _defaultHasPose = false;
  bool _defaultOnline = false;
  double _defaultProgress = 0.0;
  RobotWorkStatus _defaultStatus = RobotWorkStatus.idle;

  List<RobotAgent> _robots = const [];

  List<RobotAgent> get robots => _robots;
  int? get selectedRobotId => _selectedRobotId;
  RobotAgent? get selectedRobot => _selectedRobotId == null
      ? null
      : _robots.cast<RobotAgent?>().firstWhere(
            (r) => r?.id == _selectedRobotId,
            orElse: () => null,
          );

  void selectRobot(int? id) {
    if (_selectedRobotId == id) return;
    _selectedRobotId = id;
    notifyListeners();
  }

  /// Called from the ProxyProvider `update` (build phase) — mutates only, never
  /// notifies (the rebuild is already driven by [mission] notifying).
  void syncFromMission(MissionMockProvider mission) {
    _demoActive = mission.mockDataEnabled && !mission.rosConnected;
    if (_demoActive) {
      _robots = [
        RobotAgent(
          id: 0,
          ns: _demoNs,
          name: 'GM-1',
          color: RobotAgent.palette[0],
          batteryPercent: 86,
          progress: mission.coverageProgress,
          workStatus: RobotWorkStatus.working,
          assignedRowIndices: const [],
          position: mission.robotPosition,
          headingRad: mission.robotHeadingRad,
          online: true,
          hasPose: false,
        ),
      ];
      _lastRowCount = -1;
      return;
    }

    // Live mode: capture the default robot's data from mission for the next
    // rebuild, then re-derive the fleet (default robot may or may not exist).
    _defaultPose = mission.robotPosition;
    _defaultHeading = mission.robotHeadingRad;
    _defaultHasPose = mission.hasLiveRobotPose;
    _defaultOnline = mission.robotOnline;
    _defaultProgress = mission.coverageProgress;
    _defaultStatus = _deriveStatus(
      online: mission.robotOnline,
      navStatus: mission.navStatus,
    );
    _robots = _buildRobots();
    distributeRows(mission.coverageRows);
  }

  void distributeRows(List<List<MapPoint>> coverageRows) {
    if (_lastRowCount == coverageRows.length) return;
    _lastRowCount = coverageRows.length;
    _robots = RobotAgent.distribute(robots: _robots, coverageRows: coverageRows);
  }

  // ── Discovery ──────────────────────────────────────────────────────────────

  Future<void> _pollTopics() async {
    if (_isDisposed || _demoActive) return;
    final resp = await _rosbridge.callService('/rosapi/topics');
    if (_isDisposed) return;
    final topics = (resp.values['topics'] as List?)?.cast<dynamic>();
    if (topics == null) return; // timeout / disconnected — keep current fleet
    final types = (resp.values['types'] as List?)?.cast<dynamic>() ?? const [];

    final found = <String>{};
    for (var i = 0; i < topics.length; i++) {
      final t = topics[i]?.toString() ?? '';
      final ty = i < types.length ? (types[i]?.toString() ?? '') : '';
      if (!t.endsWith('/online') || ty != 'std_msgs/msg/Bool') continue;
      final ns = t.substring(1, t.length - '/online'.length);
      if (ns.isEmpty) continue;
      found.add(ns);
      _ensureRobot(ns);
      _absentSince.remove(ns);
    }
    for (final ns in _idByNs.keys) {
      if (!found.contains(ns)) {
        _absentSince.putIfAbsent(ns, () => DateTime.now());
      }
    }
    _rebuildAndNotify();
  }

  void _ensureRobot(String ns) {
    _idByNs.putIfAbsent(ns, () => _nextId++);
    if (ns == _defaultNs || _subscribedNs.contains(ns)) return;
    _subscribedNs.add(ns);
    _rosbridge.subscribe(
      '/$ns/online',
      type: 'std_msgs/msg/Bool',
      throttleRateMs: 200,
      qos: const {'durability': 'transient_local', 'reliability': 'reliable'},
    );
    _rosbridge.subscribe(
      '/$ns/robot_pose',
      type: 'geometry_msgs/msg/PoseStamped',
      throttleRateMs: 100,
    );
    _rosbridge.subscribe(
      '/$ns/battery_state',
      type: 'sensor_msgs/msg/BatteryState',
      throttleRateMs: 500,
    );
  }

  void _removeRobot(String ns) {
    if (ns == _defaultNs) return; // never remove the default robot's shared subs
    final id = _idByNs.remove(ns);
    _subscribedNs.remove(ns);
    _lastSeen.remove(ns);
    _lastOnlineData.remove(ns);
    _poseByNs.remove(ns);
    _headingByNs.remove(ns);
    _batteryByNs.remove(ns);
    _absentSince.remove(ns);
    if (id != null && _selectedRobotId == id) _selectedRobotId = null;
    _rosbridge.unsubscribe('/$ns/online');
    _rosbridge.unsubscribe('/$ns/robot_pose');
    _rosbridge.unsubscribe('/$ns/battery_state');
  }

  // ── Incoming telemetry (shared broadcast stream) ─────────────────────────────

  void _handleRosMessage(RosbridgeTopicMessage event) {
    final topic = event.topic;
    if (topic == '/battery_state') {
      final pct = _parseBatteryPercent(event.message);
      if (pct != null) _batteryByNs[_defaultNs] = pct;
      _rebuildAndNotify();
      return;
    }
    // Only namespaced fleet topics: /<ns>/online|robot_pose|battery_state.
    if (!topic.startsWith('/')) return;
    final rest = topic.substring(1);
    final slash = rest.indexOf('/');
    if (slash <= 0) return;
    final ns = rest.substring(0, slash);
    final leaf = rest.substring(slash + 1);
    if (!_idByNs.containsKey(ns)) return;
    switch (leaf) {
      case 'online':
        _lastSeen[ns] = DateTime.now();
        _lastOnlineData[ns] = event.message['data'] == true;
        _rebuildAndNotify();
        break;
      case 'robot_pose':
        final parsed = _parsePose(event.message);
        if (parsed != null) {
          _poseByNs[ns] = parsed.$1;
          _headingByNs[ns] = parsed.$2;
          _rebuildAndNotify();
        }
        break;
      case 'battery_state':
        final pct = _parseBatteryPercent(event.message);
        if (pct != null) {
          _batteryByNs[ns] = pct;
          _rebuildAndNotify();
        }
        break;
    }
  }

  // ── Liveness / cleanup ───────────────────────────────────────────────────────

  void _staleTick() {
    if (_isDisposed || _demoActive) return;
    final now = DateTime.now();
    var changed = false;
    for (final ns in _absentSince.keys.toList()) {
      if (now.difference(_absentSince[ns]!) > _removeAfter) {
        _removeRobot(ns);
        changed = true;
      }
    }
    // Online state is recomputed in _buildRobots from _lastSeen; tick rebuilds
    // so a robot flips to offline once its heartbeat is older than _staleAfter.
    if (changed || _idByNs.isNotEmpty) _rebuildAndNotify();
  }

  // ── Fleet assembly ───────────────────────────────────────────────────────────

  List<RobotAgent> _buildRobots() {
    final now = DateTime.now();
    final prevById = {for (final r in _robots) r.id: r};
    final entries = _idByNs.entries.toList()
      ..sort((a, b) => a.value.compareTo(b.value));

    return [
      for (final e in entries)
        _agentFor(e.key, e.value, now, prevById[e.value]),
    ];
  }

  RobotAgent _agentFor(String ns, int id, DateTime now, RobotAgent? prev) {
    final isDefault = ns == _defaultNs;
    final color = RobotAgent.palette[id % RobotAgent.palette.length];
    final name = isDefault ? 'GM-1' : ns.toUpperCase();

    final bool online;
    final MapPoint position;
    final double heading;
    final bool hasPose;
    final double progress;
    final RobotWorkStatus status;
    final DateTime? lastSeen;

    if (isDefault) {
      online = _defaultOnline;
      position = _defaultPose;
      heading = _defaultHeading;
      hasPose = _defaultHasPose;
      progress = _defaultProgress;
      status = _defaultStatus;
      lastSeen = _lastSeen[ns];
    } else {
      final seen = _lastSeen[ns];
      final fresh = seen != null && now.difference(seen) <= _staleAfter;
      online = fresh && (_lastOnlineData[ns] ?? false);
      // Keep last position when offline (memory only).
      position = _poseByNs[ns] ?? prev?.position ?? const MapPoint(0, 0);
      heading = _headingByNs[ns] ?? prev?.headingRad ?? 0.0;
      hasPose = _poseByNs.containsKey(ns);
      progress = prev?.progress ?? _defaultProgress;
      status = online ? RobotWorkStatus.working : RobotWorkStatus.idle;
      lastSeen = seen;
    }

    final battery = _batteryByNs[ns] ?? prev?.batteryPercent ?? 0.0;
    return RobotAgent(
      id: id,
      ns: ns,
      name: name,
      color: color,
      batteryPercent: battery,
      progress: progress,
      workStatus: status,
      assignedRowIndices: prev?.assignedRowIndices ?? const [],
      position: position,
      headingRad: heading,
      online: online,
      lastSeen: lastSeen,
      hasPose: hasPose,
    );
  }

  void _rebuildAndNotify() {
    if (_isDisposed || _demoActive) return;
    _robots = _buildRobots();
    _lastRowCount = -1; // force row re-distribution against the new fleet
    notifyListeners();
  }

  // ── Parsing helpers ──────────────────────────────────────────────────────────

  static RobotWorkStatus _deriveStatus({
    required bool online,
    required NavMockStatus navStatus,
  }) {
    if (!online) return RobotWorkStatus.idle;
    if (navStatus == NavMockStatus.executing) return RobotWorkStatus.working;
    return RobotWorkStatus.idle;
  }

  static double? _parseBatteryPercent(Map<String, dynamic> message) {
    final raw = message['percentage'];
    if (raw is! num) return null;
    final pct = raw.toDouble() * 100.0;
    if (pct.isNaN || pct < 0) return null;
    return pct.clamp(0.0, 100.0);
  }

  /// Returns (position, headingRad) from a PoseStamped JSON, or null.
  static (MapPoint, double)? _parsePose(Map<String, dynamic> message) {
    final pose = message['pose'];
    if (pose is! Map) return null;
    final position = pose['position'];
    if (position is! Map) return null;
    final x = (position['x'] as num?)?.toDouble();
    final y = (position['y'] as num?)?.toDouble();
    if (x == null || y == null) return null;
    var heading = 0.0;
    final orientation = pose['orientation'];
    if (orientation is Map) {
      final qz = (orientation['z'] as num?)?.toDouble() ?? 0.0;
      final qw = (orientation['w'] as num?)?.toDouble() ?? 1.0;
      final qx = (orientation['x'] as num?)?.toDouble() ?? 0.0;
      final qy = (orientation['y'] as num?)?.toDouble() ?? 0.0;
      final siny = 2.0 * (qw * qz + qx * qy);
      final cosy = 1.0 - 2.0 * (qy * qy + qz * qz);
      heading = math.atan2(siny, cosy);
    }
    return (MapPoint(x, y), heading);
  }

  @override
  void dispose() {
    _isDisposed = true;
    _discoveryTimer?.cancel();
    _staleTimer?.cancel();
    _rosMessages?.cancel();
    super.dispose();
  }
}
