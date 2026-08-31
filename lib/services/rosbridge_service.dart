import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'remote_access_config.dart';
import 'websocket_connector.dart';

enum RosbridgeConnectionState { disconnected, connecting, connected, retrying }

typedef RosbridgeConnector =
    WebSocketChannel Function(Uri uri, {Map<String, dynamic> headers});

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
  static const _defaultUrl = String.fromEnvironment(
    'ROSBRIDGE_URL',
    defaultValue: 'wss://control.fxrbindi.com',
  );

  RosbridgeService({
    String url = _defaultUrl,
    RosbridgeConnector connector = connectWebSocket,
  }) : _url = url,
       _connector = connector;

  String _url;
  final RosbridgeConnector _connector;
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
  Completer<void>? _connectionReady;
  int _callSequence = 0;

  String get url => _url;
  String get robotIp {
    final uri = Uri.tryParse(_url);
    return uri?.host ?? '';
  }

  Stream<RosbridgeTopicMessage> get messages => _messages.stream;
  Stream<RosbridgeConnectionState> get states => _states.stream;
  bool get connected => _connected;

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
      connect();
      return;
    }

    _url = nextUrl;
    reconnect();
  }

  static String _urlForRobotIp(String ip) =>
      'ws://${ip.trim()}:$_rosbridgePort';

  void connect() {
    if (_disposed || _connected || _channel != null) {
      return;
    }
    _states.add(RosbridgeConnectionState.connecting);
    try {
      final channel = _connector(
        Uri.parse(_url),
        headers: RemoteAccessConfig.cloudflareAccessHeaders,
      );
      _channel = channel;
      _socketSubscription = channel.stream.listen(
        _handleSocketData,
        onError: (_) => _scheduleReconnect(),
        onDone: _scheduleReconnect,
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
              _send(subscription.toMessage());
            }
            for (final entry in _advertisements.entries) {
              _send({
                'op': 'advertise',
                'topic': entry.key,
                'type': entry.value,
              });
            }
          })
          .catchError((_) {
            if (_channel == channel) {
              _scheduleReconnect();
            }
          });
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void reconnect() {
    _closeSocket();
    _states.add(RosbridgeConnectionState.disconnected);
    connect();
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
      _send(_subscriptions[topic]!.toMessage());
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
    if (raw is! String) {
      return;
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) {
        return;
      }
      final data = decoded.cast<String, dynamic>();
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
      channel.sink.add(jsonEncode(payload));
    } catch (_) {
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_disposed) {
      return;
    }
    _closeSocket();
    _states.add(RosbridgeConnectionState.retrying);
    for (final entry in _pendingCalls.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(
          RosbridgeServiceResponse(
            service: '',
            result: false,
            values: const {
              'success': false,
              'message': 'rosbridge disconnected',
            },
          ),
        );
      }
    }
    _pendingCalls.clear();
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 2), connect);
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

  Map<String, dynamic> toMessage() => {
    'op': 'subscribe',
    'topic': topic,
    if (type != null) 'type': type,
    if (throttleRateMs > 0) 'throttle_rate': throttleRateMs,
    if (qos != null) 'qos': qos,
  };
}
