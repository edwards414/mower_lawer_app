import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/paired_robot.dart';
import '../services/pairing_auth.dart';
import '../services/rosbridge_service.dart';

/// Where the paired robots (and their secrets) live. The real one is the
/// iOS keychain via flutter_secure_storage; tests use [MemoryPairingStore].
abstract class PairingStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecurePairingStore implements PairingStore {
  SecurePairingStore([FlutterSecureStorage? storage])
    : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class MemoryPairingStore implements PairingStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

/// "我的機器人": the robots this phone is paired with, which one is active,
/// and the identity check against what the connected robot reports.
///
/// Selecting a robot (or changing its LAN/relay preference) points
/// [RosbridgeService] at it; the pairing headers are generated per
/// connection from the robot's secret and this install's [clientId].
class RobotRegistry extends ChangeNotifier {
  RobotRegistry({
    required RosbridgeService rosbridge,
    PairingStore? store,
  }) : _rosbridge = rosbridge,
       _store = store ?? SecurePairingStore();

  static const _robotsKey = 'paired_robots';
  static const _activeKey = 'active_robot';
  static const _clientKey = 'pairing_client_id';

  final RosbridgeService _rosbridge;
  final PairingStore _store;

  List<PairedRobot> _robots = const [];
  String? _activeId;
  String _clientId = '';
  bool _loaded = false;
  String? _reportedRobotId;

  List<PairedRobot> get robots => _robots;
  bool get loaded => _loaded;
  String get clientId => _clientId;

  PairedRobot? get active {
    final id = _activeId;
    if (id == null) return null;
    for (final r in _robots) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// robot_id the connected robot last reported on /robot/info.
  String? get reportedRobotId => _reportedRobotId;

  /// Connected to a robot other than the paired one (tunnel / IP points at
  /// the wrong machine). The UI blocks operation and says so.
  bool get identityMismatch {
    final a = active;
    final reported = _reportedRobotId;
    return a != null && reported != null && reported != a.id;
  }

  Future<void> load() async {
    try {
      final raw = await _store.read(_robotsKey);
      if (raw != null && raw.isNotEmpty) {
        final list = (jsonDecode(raw) as List)
            .whereType<Map>()
            .map((e) => PairedRobot.fromJson(e.cast<String, dynamic>()))
            .where((r) => PairedRobot.idPattern.hasMatch(r.id))
            .toList();
        _robots = List.unmodifiable(list);
      }
      _activeId = await _store.read(_activeKey);
      _clientId = await _store.read(_clientKey) ?? '';
    } catch (e) {
      debugPrint('RobotRegistry: could not load pairing store: $e');
    }
    if (_clientId.isEmpty) {
      _clientId = PairingAuth.newClientId();
      await _store.write(_clientKey, _clientId);
    }
    if (active == null && _robots.isNotEmpty) {
      _activeId = _robots.first.id;
    }
    _loaded = true;
    _applyActive();
    notifyListeners();
  }

  /// Add (or update) a robot from its QR payload and make it active.
  Future<PairedRobot> pairFromText(String text) async {
    final robot = PairedRobot.fromPairUrl(text);
    await add(robot);
    return robot;
  }

  Future<void> add(PairedRobot robot) async {
    final others = _robots.where((r) => r.id != robot.id).toList();
    _robots = List.unmodifiable([...others, robot]);
    _activeId = robot.id;
    _reportedRobotId = null;
    await _persist();
    _applyActive();
    notifyListeners();
  }

  Future<void> remove(String id) async {
    _robots = List.unmodifiable(_robots.where((r) => r.id != id));
    if (_activeId == id) {
      _activeId = _robots.isEmpty ? null : _robots.first.id;
      _reportedRobotId = null;
    }
    await _persist();
    _applyActive();
    notifyListeners();
  }

  Future<void> select(String id) async {
    if (_activeId == id || !_robots.any((r) => r.id == id)) return;
    _activeId = id;
    _reportedRobotId = null;
    await _persist();
    _applyActive();
    notifyListeners();
  }

  Future<void> update(
    String id, {
    String? name,
    String? lanAddress,
    String? relayUrl,
    bool? preferLan,
  }) async {
    _robots = List.unmodifiable([
      for (final r in _robots)
        if (r.id == id)
          r.copyWith(
            name: name,
            lanAddress: lanAddress,
            relayUrl: relayUrl,
            preferLan: preferLan,
          )
        else
          r,
    ]);
    await _persist();
    if (id == _activeId) _applyActive();
    notifyListeners();
  }

  /// Called with every /robot/info; checks the robot we reached is the one
  /// we paired with.
  void noteReportedRobotId(String? robotId) {
    if (robotId == _reportedRobotId) return;
    _reportedRobotId = robotId;
    notifyListeners();
  }

  /// Pairing headers for the active robot, fresh per connection.
  Map<String, String> authHeaders() {
    final a = active;
    if (a == null || _clientId.isEmpty) return const {};
    return PairingAuth.headers(a, _clientId);
  }

  void _applyActive() {
    final a = active;
    if (a == null) return;
    final url = a.preferredUrl;
    if (url.isEmpty) return;
    _rosbridge.configureEndpoint(url: url, authHeaders: authHeaders);
  }

  Future<void> _persist() async {
    try {
      await _store.write(
        _robotsKey,
        jsonEncode(_robots.map((r) => r.toJson()).toList()),
      );
      final id = _activeId;
      if (id == null) {
        await _store.delete(_activeKey);
      } else {
        await _store.write(_activeKey, id);
      }
    } catch (e) {
      debugPrint('RobotRegistry: could not persist: $e');
    }
  }
}
