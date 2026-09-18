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
