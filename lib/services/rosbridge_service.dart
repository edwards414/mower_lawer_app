import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

enum RosbridgeConnectionState { disconnected, connecting, connected, retrying }

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

  bool get success {
    final value = values['success'];
    return value is bool ? value : result;
  }

  String get message => values['message']?.toString() ?? '';
}

class RosbridgeService {
  static const _robotIpPreferenceKey = 'robot_ip';
  static const _rosbridgePort = 9090;
  static const _defaultUrl = String.fromEnvironment(
    'ROSBRIDGE_URL',
    defaultValue: 'ws://127.0.0.1:9090',
  );

  RosbridgeService({String url = _defaultUrl}) : _url = url;

  String _url;
  final Map<String, _RosbridgeSubscription> _subscriptions = {};
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
  int _callSequence = 0;

  String get url => _url;
  String get robotIp {
    final uri = Uri.tryParse(_url);
    return uri?.host ?? '';
  }

  Stream<RosbridgeTopicMessage> get messages => _messages.stream;
  Stream<RosbridgeConnectionState> get states => _states.stream;

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
      final channel = WebSocketChannel.connect(Uri.parse(_url));
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
            _states.add(RosbridgeConnectionState.connected);
            for (final subscription in _subscriptions.values) {
              _send(subscription.toMessage());
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

  void subscribe(String topic, {String? type, int throttleRateMs = 0}) {
    _subscriptions[topic] = _RosbridgeSubscription(
      topic: topic,
      type: type,
      throttleRateMs: throttleRateMs,
    );
    if (_connected) {
      _send(_subscriptions[topic]!.toMessage());
    }
  }

  Future<RosbridgeServiceResponse> callService(
    String service, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
  }) {
    connect();
    final id =
        'call_${DateTime.now().millisecondsSinceEpoch}_${_callSequence++}';
    final completer = Completer<RosbridgeServiceResponse>();
    _pendingCalls[id] = completer;
    _send({'op': 'call_service', 'id': id, 'service': service, 'args': args});
    return completer.future.timeout(
      timeout,
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

  void _handleSocketData(dynamic raw) {
    if (raw is! String) {
      return;
    }
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
    _reconnectTimer?.cancel();
    _closeSocket();
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
  });

  final String topic;
  final String? type;
  final int throttleRateMs;

  Map<String, dynamic> toMessage() => {
    'op': 'subscribe',
    'topic': topic,
    if (type != null) 'type': type,
    if (throttleRateMs > 0) 'throttle_rate': throttleRateMs,
  };
}
