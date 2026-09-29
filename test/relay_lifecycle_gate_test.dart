import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/relay_lifecycle_gate.dart';

void main() {
  late List<_FakeWebSocketChannel> channels;
  late RosbridgeService service;

  setUp(() {
    channels = [];
    service = RosbridgeService(
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
  });

  tearDown(() => service.dispose());

  testWidgets('hidden suspends the relay; resumed reconnects', (tester) async {
    service.configureEndpoint(
      url: 'wss://api.robot.test/v1/relay/app/MW-TEST01',
      framed: true,
    );
    var stops = 0;
    await tester.pumpWidget(
      RelayLifecycleGate(
        rosbridge: service,
        beforeSuspend: () => stops++,
        child: const SizedBox(),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(service.suspended, isTrue);
    expect(stops, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(stops, 1, reason: 'already suspended');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(service.suspended, isFalse);
    expect(channels, hasLength(2));
  });

  testWidgets('canSuspend false keeps the relay open', (tester) async {
    service.configureEndpoint(
      url: 'wss://api.robot.test/v1/relay/app/MW-TEST01',
      framed: true,
    );
    await tester.pumpWidget(
      RelayLifecycleGate(
        rosbridge: service,
        canSuspend: () => false,
        child: const SizedBox(),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(service.suspended, isFalse);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  testWidgets('a LAN session is not suspended', (tester) async {
    service.configureEndpoint(url: 'ws://robot.test:9090');
    var stops = 0;
    await tester.pumpWidget(
      RelayLifecycleGate(
        rosbridge: service,
        beforeSuspend: () => stops++,
        child: const SizedBox(),
      ),
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    expect(service.suspended, isFalse);
    expect(stops, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });
}

class _FakeWebSocketChannel implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController<dynamic>();
  final StreamController<dynamic> _sent = StreamController<dynamic>.broadcast(
    sync: true,
  );
  late final WebSocketSink _sink = _FakeWebSocketSink(_sent);

  @override
  Future<void> get ready => Completer<void>().future;

  @override
  Stream<dynamic> get stream => _incoming.stream;

  @override
  WebSocketSink get sink => _sink;

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
