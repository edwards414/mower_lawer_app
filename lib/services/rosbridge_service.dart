import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'reconnect_backoff.dart';
import 'relay_framing.dart';
import 'remote_access_config.dart';
import 'websocket_connector.dart';

enum RosbridgeConnectionState { disconnected, connecting, connected, retrying }

typedef RosbridgeConnector =
    WebSocketChannel Function(
      Uri uri, {
      Map<String, dynamic> headers,
      List<String> protocols,
    });

/// Extra HTTP headers for the WebSocket upgrade, computed fresh for every
/// connection attempt (the pairing hand-shake carries a time and a nonce).
typedef RosbridgeHeaderProvider = Map<String, String> Function();

class RosbridgeTopicMessage {
  const RosbridgeTopicMessage({required this.topic, required this.message});

  final String topic;
  final Map<String, dynamic> message;
}

class RosbridgeServiceResponse {
  const RosbridgeServiceResponse({
    required this.service,
    required this.result,
    required this.values,
  });

  final String service;
  final bool result;
  final Map<String, dynamic> values;

  /// A domain-level ACK is valid only when both the rosbridge envelope and the
  /// ROS service response explicitly report success. Falling back to
  /// [result] when `values.success` is missing would turn a malformed response
  /// into an accepted mower command.
  bool get success => result && values['success'] == true;

  String get message => values['message']?.toString() ?? '';
}

class RosbridgeService {
  static const _robotIpPreferenceKey = 'robot_ip';
  static const _rosbridgePort = 9090;
  static const _useSavedRobotIp = bool.fromEnvironment(
    'USE_SAVED_ROBOT_IP',
    defaultValue: false,
  );
  // No endpoint until a paired robot configures one (RobotRegistry); a
  // build-time ROSBRIDGE_URL is only for development against a fixed host.
  static const _defaultUrl = String.fromEnvironment('ROSBRIDGE_URL');

  /// Minimum `throttle_rate` (ms) per topic while connected through the fleet
  /// relay, where every relayed rosbridge message is billed as a Durable
  /// Object request. Each floor stays well inside the staleness window the
  /// app applies to that topic (pose 3 s, battery 10 s). Safety-gated streams
  /// keep their full rate and are deliberately not listed: the heartbeat
  /// `/robot/online` (3 s), `/manual_command_clock` (200 ms) and the GPS fix
  /// (300 ms, checked against that clock).
  static const Map<String, int> relayMinThrottleMs = {
    '/adapter/robot_pose': 1000,
    '/battery_state': 5000,
    '/adapter/zone_summaries': 2000,
    '/adapter/coverage_settings': 2000,
    '/adapter/map_datum': 5000,
  };

  /// While the robot stays unreachable, log the first failure and then only
  /// every Nth (a fixed-rate retry once left ~50k lines over 3.5 days).
  static const _logEveryNthFailure = 20;

  /// While [fastRetry] is on, retries wait about the old fixed 2 s instead of
  /// backing off, but only for the first [_fastRetryLimit] failures of an
  /// outage (a few minutes): a robot whose battery died mid-mission must not
  /// be hammered for days.
  static const _fastRetryDelay = Duration(seconds: 2);
  static const _fastRetryLimit = 150;

  RosbridgeService({
    String url = _defaultUrl,
    RosbridgeConnector connector = connectWebSocket,
    ReconnectBackoff? backoff,
  }) : _url = url,
       _connector = connector,
       _backoff = backoff ?? ReconnectBackoff();

  String _url;
  RosbridgeHeaderProvider? _authHeaders;

  /// Connected through the fleet backend relay: mrelay1 framing on the wire.
  bool _framed = false;
  RelayReassembler? _reassembler;

  /// WHEP base URL of the active robot for the current route
  /// (`http://<lan ip>:8889`, the QR's `c`, or the backend's
  /// `/v1/robots/{id}/http`); '' when video is not reachable this way.
  String _cameraBaseUrl = '';

  /// The camera endpoint wants the pairing headers on every request
  /// (backend HTTP relay); false for MediaMTX reached directly.
  bool _cameraAuth = false;

  /// Backend URL that returns ICE (TURN) servers for the camera, '' = none.
  String _cameraIceServersUrl = '';
  final RosbridgeConnector _connector;

  /// Wait before each automatic retry: ~1 s doubling to ~30 s, jittered.
  final ReconnectBackoff _backoff;
  final Map<String, _RosbridgeSubscription> _subscriptions = {};
  final Map<String, String> _advertisements = {};
  final Map<String, Completer<RosbridgeServiceResponse>> _pendingCalls = {};
  final StreamController<RosbridgeTopicMessage> _messages =
      StreamController<RosbridgeTopicMessage>.broadcast();
  final StreamController<RosbridgeConnectionState> _states =
      StreamController<RosbridgeConnectionState>.broadcast();

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _socketSubscription;
  Timer? _reconnectTimer;
  bool _disposed = false;
  bool _connected = false;

  /// The current socket delivered a rosbridge message. An accepted upgrade
  /// alone proves nothing: the fleet relay (stale robot socket) or the
  /// robot's auth proxy can accept and then drop, and must not reset the
  /// backoff.
  bool _healthy = false;

  /// Relay session closed on purpose while the app is in the background;
  /// [connect] and reconnects are held until [resume].
  bool _suspended = false;
  bool _fastRetry = false;

  /// The previous failure with per-attempt noise stripped, so the log can
  /// report a new failure reason (relay 503 -> pairing 4401) right away.
  String? _lastFailure;
  Completer<void>? _connectionReady;
  int _callSequence = 0;

  String get url => _url;
  bool get framed => _framed;
  bool get suspended => _suspended;
  String get cameraBaseUrl => _cameraBaseUrl;
  String get cameraIceServersUrl => _cameraIceServersUrl;

  /// Headers for the camera's WHEP / TURN requests: a fresh pairing
  /// signature when the endpoint is the backend, nothing otherwise.
  Map<String, String> cameraHeaders() {
    final provider = _authHeaders;
    if (!_cameraAuth || provider == null) return const {};
    return provider();
  }
  String get robotIp {
    final uri = Uri.tryParse(_url);
    return uri?.host ?? '';
  }

  Stream<RosbridgeTopicMessage> get messages => _messages.stream;
  Stream<RosbridgeConnectionState> get states => _states.stream;
  bool get connected => _connected;

  /// A mission may be running on the robot (or a stop is still owed to it).
  /// While the link is down the operator has no stop button, so retry at
  /// about 2 s instead of backing off towards 30 s (see [_fastRetryLimit]).
  /// Turning it on also retries at once, like [retryNow].
  bool get fastRetry => _fastRetry;
  set fastRetry(bool value) {
    if (value == _fastRetry) {
      return;
    }
    _fastRetry = value;
    if (value) {
      retryNow();
    }
  }

  static String? validateRobotIp(String value) {
    final ip = value.trim();
    if (ip.isEmpty) {
      return '請輸入機器人 IP';
    }
    final segments = ip.split('.');
    if (segments.length != 4) {
      return '請輸入有效的 IPv4 位址';
    }
    for (final segment in segments) {
      final number = int.tryParse(segment);
      if (number == null || number < 0 || number > 255) {
        return '請輸入有效的 IPv4 位址';
      }
    }
    return null;
  }

  Future<void> loadSavedRobotIp() async {
    // Production connects through the authenticated public relay. A saved LAN
    // IP is used only by builds that explicitly opt into local development.
    if (!_useSavedRobotIp) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString(_robotIpPreferenceKey);
    if (savedIp == null || validateRobotIp(savedIp) != null) {
      return;
    }
    _url = _urlForRobotIp(savedIp);
  }

  Future<void> setRobotIp(String value) async {
    final error = validateRobotIp(value);
    if (error != null) {
      throw ArgumentError(error);
    }

    final ip = value.trim();
    final nextUrl = _urlForRobotIp(ip);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_robotIpPreferenceKey, ip);

    if (_url == nextUrl) {
      retryNow();
      return;
    }

    _url = nextUrl;
    reconnect();
  }

  static String _urlForRobotIp(String ip) =>
      'ws://${ip.trim()}:$_rosbridgePort';

  /// Point the service at a paired robot: its rosbridge URL plus the
  /// per-connection pairing headers. [framed] selects the fleet backend
  /// relay (mrelay1 chunk framing, `Sec-WebSocket-Protocol: mrelay1`).
  /// Reconnects when the URL or framing changes; either way this is an
  /// explicit choice of robot / route, so it skips any pending backoff.
  void configureEndpoint({
    required String url,
    RosbridgeHeaderProvider? authHeaders,
    bool framed = false,
    String cameraBaseUrl = '',
    bool cameraAuth = false,
    String cameraIceServersUrl = '',
  }) {
    _authHeaders = authHeaders;
    _cameraBaseUrl = cameraBaseUrl.replaceFirst(RegExp(r'/+$'), '');
    _cameraAuth = cameraAuth;
    _cameraIceServersUrl = cameraIceServersUrl;
    if (url.isEmpty) {
      return;
    }
    if (_url == url && _framed == framed) {
      retryNow();
      return;
    }
    _url = url;
    _framed = framed;
    reconnect();
  }

  Map<String, String> _upgradeHeaders() {
    final provider = _authHeaders;
    return {
      // The legacy tunnel sits behind Cloudflare Access; the fleet backend
      // authenticates with the pairing headers alone.
      if (!_framed) ...RemoteAccessConfig.cloudflareAccessHeaders,
      if (provider != null) ...provider(),
    };
  }

  /// Opens the socket unless one is open or opening. While an automatic
  /// retry is scheduled this leaves it to that timer: pollers reach here
  /// through [callService] / [publish] every few seconds and must not undo
  /// the backoff. Explicit user/app actions use [reconnect] or [retryNow].
  void connect() {
    if (_disposed ||
        _suspended ||
        _connected ||
        _channel != null ||
        _reconnectTimer != null ||
        _url.isEmpty) {
      return;
    }
    _states.add(RosbridgeConnectionState.connecting);
    try {
      final channel = _connector(
        Uri.parse(_url),
        headers: _upgradeHeaders(),
        protocols: _framed ? const [RelayFraming.subprotocol] : const [],
      );
      _channel = channel;
      _reassembler = _framed ? RelayReassembler() : null;
      _socketSubscription = channel.stream.listen(
        _handleSocketData,
        onError: (Object error) => _scheduleReconnect(error),
        onDone: () => _scheduleReconnect(_closedReason(channel)),
        cancelOnError: true,
      );
      channel.ready
          .then((_) {
            if (_disposed || _channel != channel) {
              return;
            }
            _connected = true;
            final ready = _connectionReady;
            if (ready != null && !ready.isCompleted) {
              ready.complete();
            }
            _states.add(RosbridgeConnectionState.connected);
            for (final subscription in _subscriptions.values) {
              _send(subscription.toMessage(relay: _framed));
            }
            for (final entry in _advertisements.entries) {
              _send({
                'op': 'advertise',
                'topic': entry.key,
                'type': entry.value,
              });
            }
          })
          .catchError((Object error) {
            if (_channel == channel) {
              _scheduleReconnect('upgrade failed: $error');
            }
          });
    } catch (error) {
      _scheduleReconnect(error);
    }
  }

  /// Drop the current socket (if any) and connect again right away, with the
  /// backoff started over: an explicit user/app action (new endpoint,
  /// re-subscribe after demo mode).
  void reconnect() {
    if (_disposed) {
      return;
    }
    _closeSocket();
    _backoff.reset();
    _states.add(RosbridgeConnectionState.disconnected);
    connect();
  }

  /// Skip the pending backoff wait and try now, starting the backoff over
  /// (the app came back to the foreground, the user re-selected the robot).
  /// A socket that is open or still opening is left alone.
  void retryNow() {
    if (_disposed) {
      return;
    }
    _backoff.reset();
    if (_connected || _channel != null) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    connect();
  }

  /// Close the relay session while the app is in the background, so the robot
  /// stops streaming through the backend. Subscriptions and advertisements
  /// are kept and re-sent by [resume]. No-op on a LAN route (not billed) or
  /// when already suspended; returns whether the session was suspended.
  bool suspendRelay() {
    if (_disposed || _suspended || !_framed) {
      return false;
    }
    _suspended = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _closeSocket();
    _failPendingCalls('rosbridge suspended');
    _states.add(RosbridgeConnectionState.disconnected);
    return true;
  }

  /// Undo [suspendRelay] and connect now, with the backoff started over: the
  /// app is visible again, so there is no reason to wait out a retry delay.
  void resume() {
    if (!_suspended) {
      return;
    }
    _suspended = false;
    retryNow();
  }

  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {
    _subscriptions[topic] = _RosbridgeSubscription(
      topic: topic,
      type: type,
      throttleRateMs: throttleRateMs,
      qos: qos,
    );
    if (_connected) {
      _send(_subscriptions[topic]!.toMessage(relay: _framed));
    }
  }

  void unsubscribe(String topic) {
    _subscriptions.remove(topic);
    if (_connected) {
      _send({'op': 'unsubscribe', 'topic': topic});
    }
  }

  Future<RosbridgeServiceResponse> callService(
    String service, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final startedAt = DateTime.now();
    if (!await _waitForConnection(timeout)) {
      return RosbridgeServiceResponse(
        service: service,
        result: false,
        values: const {
          'success': false,
          'message': 'rosbridge connection timeout',
        },
      );
    }
    final remaining = timeout - DateTime.now().difference(startedAt);
    if (remaining <= Duration.zero) {
      return RosbridgeServiceResponse(
        service: service,
        result: false,
        values: const {
          'success': false,
          'message': 'rosbridge connection timeout',
        },
      );
    }
    final id =
        'call_${DateTime.now().millisecondsSinceEpoch}_${_callSequence++}';
    final completer = Completer<RosbridgeServiceResponse>();
    _pendingCalls[id] = completer;
    _send({'op': 'call_service', 'id': id, 'service': service, 'args': args});
    return completer.future.timeout(
      remaining,
      onTimeout: () {
        _pendingCalls.remove(id);
        return RosbridgeServiceResponse(
          service: service,
          result: false,
          values: const {
            'success': false,
            'message': 'rosbridge service timeout',
          },
        );
      },
    );
  }

  Future<bool> _waitForConnection(Duration timeout) async {
    if (_disposed) {
      return false;
    }
    if (_connected) {
      return true;
    }
    final current = _connectionReady;
    final ready = current == null || current.isCompleted
        ? (_connectionReady = Completer<void>())
        : current;
    connect();
    try {
      await ready.future.timeout(timeout);
      return !_disposed && _connected;
    } on TimeoutException {
      return false;
    }
  }

  bool publish(
    String topic, {
    required Map<String, dynamic> message,
    String? type,
  }) {
    connect();
    if (type != null) {
      final currentType = _advertisements[topic];
      _advertisements[topic] = type;
      if (_connected && currentType != type) {
        _send({'op': 'advertise', 'topic': topic, 'type': type});
      }
    }
    if (!_connected) {
      return false;
    }
    _send({'op': 'publish', 'topic': topic, 'msg': message});
    return true;
  }

  void _handleSocketData(dynamic raw) {
    final String text;
    if (raw is String) {
      text = raw;
    } else if (raw is List<int> && _framed) {
      final reassembler = _reassembler;
      if (reassembler == null) {
        return;
      }
      final Object? message;
      try {
        message = reassembler.feed(raw);
      } on FormatException {
        return;
      }
      if (message is! String) {
        return; // still collecting chunks, or a binary rosbridge message
      }
      text = message;
    } else {
      return;
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        return;
      }
      final data = decoded.cast<String, dynamic>();
      _markHealthy();
      switch (data['op']) {
        case 'publish':
          final topic = data['topic']?.toString();
          final message = data['msg'];
          if (topic != null && message is Map) {
            _messages.add(
              RosbridgeTopicMessage(
                topic: topic,
                message: message.cast<String, dynamic>(),
              ),
            );
          }
          break;
        case 'service_response':
          final id = data['id']?.toString();
          final completer = id == null ? null : _pendingCalls.remove(id);
          if (completer == null || completer.isCompleted) {
            return;
          }
          final values = data['values'] is Map
              ? (data['values'] as Map).cast<String, dynamic>()
              : <String, dynamic>{};
          completer.complete(
            RosbridgeServiceResponse(
              service: data['service']?.toString() ?? '',
              result: data['result'] == true,
              values: values,
            ),
          );
          break;
      }
    } on FormatException {
      // A malformed rosbridge frame must not terminate the socket listener.
      return;
    } on TypeError {
      // Ignore structurally-invalid payloads and keep processing later frames.
      return;
    }
  }

  void _send(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    try {
      final text = jsonEncode(payload);
      if (_framed) {
        for (final frame in RelayFraming.encodeText(text)) {
          channel.sink.add(frame);
        }
      } else {
        channel.sink.add(text);
      }
    } catch (error) {
      _scheduleReconnect(error);
    }
  }

  void _markHealthy() {
    if (_healthy) {
      return;
    }
    _healthy = true;
    final failures = _backoff.failures;
    if (failures > 0 && kDebugMode) {
      debugPrint('RosbridgeService: $_url back after $failures failures');
    }
    _backoff.reset();
  }

  static String _closedReason(WebSocketChannel channel) {
    final code = channel.closeCode;
    if (code == null) {
      return 'closed';
    }
    final reason = channel.closeReason ?? '';
    return reason.isEmpty ? 'closed ($code)' : 'closed ($code $reason)';
  }

  void _scheduleReconnect(Object failure) {
    if (_disposed || _suspended) {
      return;
    }
    if (_channel == null && _reconnectTimer != null) {
      return; // this failure already has its retry scheduled
    }
    _closeSocket();
    _states.add(RosbridgeConnectionState.retrying);
    _failPendingCalls('rosbridge disconnected');
    final fast = _fastRetry && _backoff.failures < _fastRetryLimit;
    final delay = _backoff.nextDelay(cap: fast ? _fastRetryDelay : null);
    _logRetry(delay, failure);
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      connect();
    });
  }

  /// [failure] without what changes on every attempt: the "upgrade failed"
  /// prefix (the same error can arrive via `ready` or via the stream) and
  /// the local port of a refused socket.
  static String _failureSignature(Object failure) => '$failure'
      .replaceFirst('upgrade failed: ', '')
      .replaceAll(RegExp(r'port = \d+'), 'port');

  void _logRetry(Duration delay, Object failure) {
    final failures = _backoff.failures;
    final signature = _failureSignature(failure);
    final changed = signature != _lastFailure;
    _lastFailure = signature;
    if (!kDebugMode ||
        (failures != 1 && !changed && failures % _logEveryNthFailure != 0)) {
      return;
    }
    final seconds = (delay.inMilliseconds / 1000).toStringAsFixed(1);
    debugPrint(
      'RosbridgeService: $_url unreachable (attempt $failures, '
      'next in $seconds s): $failure',
    );
  }

  void _failPendingCalls(String message) {
    for (final entry in _pendingCalls.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          RosbridgeServiceResponse(
            service: '',
            result: false,
            values: {'success': false, 'message': message},
          ),
        );
      }
    }
    _pendingCalls.clear();
  }

  void dispose() {
    _disposed = true;
    final ready = _connectionReady;
    if (ready != null && !ready.isCompleted) {
      ready.complete();
    }
    _reconnectTimer?.cancel();
    _closeSocket();
    for (final entry in _pendingCalls.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          RosbridgeServiceResponse(
            service: entry.key,
            result: false,
            values: const {'success': false, 'message': 'rosbridge disposed'},
          ),
        );
      }
    }
    _pendingCalls.clear();
    _messages.close();
    _states.close();
  }

  void _closeSocket() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _connected = false;
    _healthy = false;
    final subscription = _socketSubscription;
    final channel = _channel;
    _socketSubscription = null;
    _channel = null;
    final cancelFuture = subscription?.cancel();
    if (cancelFuture != null) {
      unawaited(cancelFuture);
    }
    final closeFuture = channel?.sink.close();
    if (closeFuture != null) {
      unawaited(closeFuture);
    }
  }
}

class _RosbridgeSubscription {
  const _RosbridgeSubscription({
    required this.topic,
    required this.type,
    required this.throttleRateMs,
    this.qos,
  });

  final String topic;
  final String? type;
  final int throttleRateMs;
  final Map<String, dynamic>? qos;

  /// [relay] raises the throttle to [RosbridgeService.relayMinThrottleMs].
  Map<String, dynamic> toMessage({bool relay = false}) {
    final floor = relay ? RosbridgeService.relayMinThrottleMs[topic] ?? 0 : 0;
    final throttle = throttleRateMs > floor ? throttleRateMs : floor;
    return {
      'op': 'subscribe',
      'topic': topic,
      if (type != null) 'type': type,
      if (throttle > 0) 'throttle_rate': throttle,
      if (qos != null) 'qos': qos,
    };
  }
}
