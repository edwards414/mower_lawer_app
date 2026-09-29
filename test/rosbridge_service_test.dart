import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/services/rosbridge_service.dart';

void main() {
  test('service success requires explicit transport and domain ACKs', () {
    const missingDomainAck = RosbridgeServiceResponse(
      service: '/test_service',
      result: true,
      values: {'message': 'ok'},
    );
    const malformedDomainAck = RosbridgeServiceResponse(
      service: '/test_service',
      result: true,
      values: {'success': 'true'},
    );
    const failedEnvelope = RosbridgeServiceResponse(
      service: '/test_service',
      result: false,
      values: {'success': true},
    );
    const explicitAck = RosbridgeServiceResponse(
      service: '/test_service',
      result: true,
      values: {'success': true},
    );

    expect(missingDomainAck.success, isFalse);
    expect(malformedDomainAck.success, isFalse);
    expect(failedEnvelope.success, isFalse);
    expect(explicitAck.success, isTrue);
  });

  test('callService waits for WebSocket ready before sending', () async {
    final channel = _FakeWebSocketChannel();
    final sent = <String>[];
    final sentSubscription = channel.sent.stream.cast<String>().listen(
      sent.add,
    );
    final service = RosbridgeService(
      url: 'ws://robot.test:9090',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );

    final responseFuture = service.callService(
      '/test_service',
      timeout: const Duration(seconds: 1),
    );
    await _flushEvents();
    expect(sent, isEmpty);

    channel.markReady();
    await _flushEvents();
    expect(sent, hasLength(1));
    final request = jsonDecode(sent.single) as Map<String, dynamic>;
    expect(request['op'], 'call_service');
    expect(request['service'], '/test_service');

    channel.addIncoming(
      jsonEncode({
        'op': 'service_response',
        'id': request['id'],
        'service': '/test_service',
        'result': true,
        'values': {'success': true, 'message': 'ok'},
      }),
    );
    final response = await responseFuture;
    expect(response.success, isTrue);
    expect(response.message, 'ok');

    service.dispose();
    await sentSubscription.cancel();
  });

  test('malformed frame does not stop later rosbridge messages', () async {
    final channel = _FakeWebSocketChannel();
    final service = RosbridgeService(
      url: 'ws://robot.test:9090',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final received = <RosbridgeTopicMessage>[];
    final messageSubscription = service.messages.listen(received.add);

    service.connect();
    channel.markReady();
    await _flushEvents();
    channel.addIncoming('{invalid-json');
    channel.addIncoming(
      jsonEncode({
        'op': 'publish',
        'topic': '/robot/online',
        'msg': {'data': true},
      }),
    );
    await _flushEvents();

    expect(received, hasLength(1));
    expect(received.single.topic, '/robot/online');
    expect(received.single.message['data'], isTrue);

    service.dispose();
    await messageSubscription.cancel();
  });

  test('relay raises the throttle to its floor; LAN keeps the request', () async {
    final channels = <_FakeWebSocketChannel>[];
    final service = _serviceWith(channels);
    service.subscribe('/adapter/robot_pose', throttleRateMs: 100);
    service.subscribe('/manual_command_clock');
    service.subscribe('/robot/online', throttleRateMs: 200);
    service.subscribe('/battery_state', throttleRateMs: 10000);

    service.configureEndpoint(url: 'ws://robot.test:9090');
    final lan = await _subscribeRequests(channels.last);
    expect(lan['/adapter/robot_pose'], 100);
    expect(lan['/manual_command_clock'], isNull);

    service.configureEndpoint(url: _relayUrl, framed: true);
    final relay = await _subscribeRequests(channels.last, framed: true);
    expect(relay['/adapter/robot_pose'], 1000);
    // Safety-gated streams keep the rate the app asked for.
    expect(relay['/manual_command_clock'], isNull);
    expect(relay['/robot/online'], 200);
    // A request slower than the floor is kept.
    expect(relay['/battery_state'], 10000);

    service.dispose();
  });

  test('suspendRelay closes the relay session until resume re-subscribes', () async {
    final channels = <_FakeWebSocketChannel>[];
    final service = _serviceWith(channels);
    final states = <RosbridgeConnectionState>[];
    final stateSubscription = service.states.listen(states.add);
    service.subscribe('/robot/online', throttleRateMs: 200);
    service.configureEndpoint(url: _relayUrl, framed: true);
    await _subscribeRequests(channels.last, framed: true);
    expect(service.connected, isTrue);

    final pending = service.callService('/test_service');
    await _flushEvents(); // the call is registered once the socket is ready
    expect(service.suspendRelay(), isTrue);
    await _flushEvents();
    expect(service.connected, isFalse);
    expect(service.suspended, isTrue);
    expect(states.last, RosbridgeConnectionState.disconnected);
    expect((await pending).success, isFalse);

    service.connect();
    expect(channels, hasLength(1), reason: 'connect is held while suspended');

    service.resume();
    expect(channels, hasLength(2));
    final again = await _subscribeRequests(channels.last, framed: true);
    expect(again.keys, contains('/robot/online'));
    expect(service.connected, isTrue);

    service.dispose();
    await stateSubscription.cancel();
  });

  test('suspendRelay leaves a LAN session alone', () async {
    final channels = <_FakeWebSocketChannel>[];
    final service = _serviceWith(channels);
    service.configureEndpoint(url: 'ws://robot.test:9090');
    await _subscribeRequests(channels.last);

    expect(service.suspendRelay(), isFalse);
    expect(service.suspended, isFalse);
    expect(service.connected, isTrue);

    service.dispose();
  });
}

const _relayUrl = 'wss://api.robot.test/v1/relay/app/MW-TEST01';

RosbridgeService _serviceWith(List<_FakeWebSocketChannel> channels) =>
    RosbridgeService(
      url: '',
      connector:
          (
            _, {
            headers = const <String, dynamic>{},
            protocols = const <String>[],
          }) {
            final channel = _FakeWebSocketChannel();
            channels.add(channel);
            return channel;
          },
    );

/// Mark [channel] ready and collect `topic -> throttle_rate` of the
/// subscribe requests the service sends on connect.
Future<Map<String, int?>> _subscribeRequests(
  _FakeWebSocketChannel channel, {
  bool framed = false,
}) async {
  final requests = <String, int?>{};
  final subscription = channel.sent.stream.listen((data) {
    final text = framed
        ? utf8.decode((data as List<int>).sublist(1))
        : data as String;
    final message = jsonDecode(text) as Map<String, dynamic>;
    if (message['op'] == 'subscribe') {
      requests[message['topic'] as String] = message['throttle_rate'] as int?;
    }
  });
  channel.markReady();
  await _flushEvents();
  await subscription.cancel();
  return requests;
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final Completer<void> _ready = Completer<void>();
  final StreamController<dynamic> _incoming =
      StreamController<dynamic>.broadcast(sync: true);
  final StreamController<dynamic> sent = StreamController<dynamic>.broadcast(
    sync: true,
  );

  late final WebSocketSink _sink = _FakeWebSocketSink(sent);

  void markReady() {
    if (!_ready.isCompleted) _ready.complete();
  }

  void addIncoming(dynamic value) => _incoming.add(value);

  @override
  Future<void> get ready => _ready.future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeWebSocketSink implements WebSocketSink {
  _FakeWebSocketSink(this._controller);

  final StreamController<dynamic> _controller;

  @override
  void add(dynamic data) => _controller.add(data);

  @override
  Future<void> close([int? closeCode, String? closeReason]) =>
      _controller.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
