import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/paired_robot.dart';
import '../services/backend_client.dart';
import '../services/pairing_auth.dart';
import '../services/rosbridge_service.dart';
import '../services/websocket_connector.dart';

/// Tries to open the robot's LAN rosbridge; true when the upgrade succeeds.
typedef LanProbe = Future<bool> Function(String url, Map<String, String> headers);

Future<bool> defaultLanProbe(String url, Map<String, String> headers) async {
  try {
    final channel = connectWebSocket(Uri.parse(url), headers: headers);
    await channel.ready.timeout(const Duration(seconds: 2));
    unawaited(channel.sink.close());
    return true;
  } catch (_) {
    return false;
  }
}

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
    BackendClient? backend,
    LanProbe? lanProbe,
    String? devPairUrl,
  }) : _rosbridge = rosbridge,
       _store = store ?? SecurePairingStore(),
       _backend = backend ?? BackendClient(),
       _lanProbe = lanProbe ?? defaultLanProbe,
       _devPairUrl = devPairUrl ?? _devPairUrlDefine;

  /// Debug builds only: pair with this QR payload on first start, so the
  /// simulator (no camera to scan) can talk to a real robot:
  ///   flutter run --dart-define=DEV_PAIR_URL='https://mower.…/pair?id=…&s=…&l=…'
  static const _devPairUrlDefine = String.fromEnvironment('DEV_PAIR_URL');
  final String _devPairUrl;

  static const _robotsKey = 'paired_robots';
  static const _activeKey = 'active_robot';
  static const _clientKey = 'pairing_client_id';

  final RosbridgeService _rosbridge;
  final PairingStore _store;
  final BackendClient _backend;
  final LanProbe _lanProbe;

  List<PairedRobot> _robots = const [];
  String? _activeId;
  String _clientId = '';
  bool _loaded = false;
  String? _reportedRobotId;
  final Map<String, RobotStatus> _statuses = {};
  final Map<String, String> _statusErrors = {};
  String _activeRoute = '';
  int _routeSeq = 0;

  List<PairedRobot> get robots => _robots;
  bool get loaded => _loaded;
  String get clientId => _clientId;

  /// How the active robot is reached right now: 'lan', 'relay' or '' while
  /// the LAN probe is still running / nothing is configured.
  String get activeRoute => _activeRoute;

  /// Last backend status of a robot (null until [refreshStatus] ran).
  RobotStatus? statusOf(String id) => _statuses[id];
  String? statusErrorOf(String id) => _statusErrors[id];

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
    // Nothing stored (or the store is unreadable, e.g. a simulator keychain
    // without entitlements) counts as a first start.
    var firstStart = true;
    try {
      final raw = await _store.read(_robotsKey);
      firstStart = raw == null;
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
    if (firstStart && _robots.isEmpty && kDebugMode && _devPairUrl.isNotEmpty) {
      try {
        final robot = PairedRobot.fromPairUrl(_devPairUrl);
        _robots = List.unmodifiable([robot]);
        _activeId = robot.id;
        await _persist();
        debugPrint('RobotRegistry: paired ${robot.id} from DEV_PAIR_URL');
      } on FormatException catch (e) {
        debugPrint('RobotRegistry: DEV_PAIR_URL rejected: ${e.message}');
      }
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

  /// Ask the fleet backend whether a robot is online. Robots on a legacy
  /// relay (no backend) are skipped. The LAN address the robot reported
  /// with its heartbeat replaces a stale one.
  Future<void> refreshStatus(String id) async {
    PairedRobot? robot;
    for (final r in _robots) {
      if (r.id == id) robot = r;
    }
    if (robot == null || !robot.usesBackendRelay || _clientId.isEmpty) return;
    try {
      final status = await _backend.status(robot, _clientId);
      _statuses[id] = status;
      _statusErrors.remove(id);
      if (status.lan.isNotEmpty && status.lan != robot.lanAddress) {
        await update(id, lanAddress: status.lan);
        return; // update() already notified
      }
    } on BackendException catch (e) {
      _statusErrors[id] = e.message;
    } catch (e) {
      _statusErrors[id] = '無法連到後台';
      debugPrint('RobotRegistry: status $id: $e');
    }
    notifyListeners();
  }

  Future<void> refreshAll() async {
    await Future.wait([for (final r in _robots) refreshStatus(r.id)]);
  }

  void _applyActive() {
    final a = active;
    if (a == null) return;
    final seq = ++_routeSeq;
    if (a.preferLan && a.hasLan) {
      _useRoute(a, 'lan');
      return;
    }
    if (a.usesBackendRelay && a.hasLan) {
      // LAN first: same Wi-Fi means no relay hop. Probe, then fall back.
      _activeRoute = '';
      unawaited(_routeLanFirst(a, seq));
      return;
    }
    _useRoute(a, a.usesLan ? 'lan' : 'relay');
  }

  Future<void> _routeLanFirst(PairedRobot a, int seq) async {
    final reachable = await _lanProbe(a.lanUrl, PairingAuth.headers(a, _clientId));
    if (seq != _routeSeq) return; // the user picked something else meanwhile
    _useRoute(a, reachable ? 'lan' : 'relay');
    notifyListeners();
  }

  void _useRoute(PairedRobot a, String route) {
    final url = route == 'lan' ? a.lanUrl : a.relayWsUrl;
    if (url.isEmpty) {
      _activeRoute = '';
      return;
    }
    _activeRoute = route;
    _rosbridge.configureEndpoint(
      url: url,
      authHeaders: authHeaders,
      framed: route == 'relay' && a.usesBackendRelay,
      cameraBaseUrl: cameraBaseUrlFor(a, route),
    );
  }

  /// Where the WHEP video of [robot] is served for a route: the QR's `c`
  /// when given, else the robot's MediaMTX on the LAN. Through the fleet
  /// relay there is no video path yet (phase 3), so '' hides the camera.
  static String cameraBaseUrlFor(PairedRobot robot, String route) {
    if (robot.cameraUrl.isNotEmpty) return robot.cameraUrl;
    if (route == 'lan' && robot.hasLan) {
      return 'http://${robot.lanAddress}:${PairedRobot.webrtcPort}';
    }
    if (route == 'relay' && !robot.usesBackendRelay) {
      return ''; // legacy tunnel: MissionMockProvider derives from the host
    }
    return '';
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
