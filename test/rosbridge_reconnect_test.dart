import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/models/paired_robot.dart';
import 'package:mower_stdio/providers/robot_registry.dart';
import 'package:mower_stdio/services/reconnect_backoff.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/retry_rosbridge_on_resume.dart';

const _url = 'ws://robot.test:9090';
const _secret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';

void main() {
  test('retries wait 1, 2, 4, 8, 16 s, then stay at 30 s', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = _service(robot);
      service.connect();
      expect(robot.attempts, 1);

      for (final seconds in [1, 2, 4, 8, 16, 30, 30, 30]) {
        robot.last.refuse();
        async.flushMicrotasks();
        // Exactly one retry is armed, and nothing happens before it is due.
        expect(async.pendingTimers, hasLength(1));
        final before = robot.attempts;
        async.elapse(Duration(seconds: seconds) - _ms);
        expect(robot.attempts, before, reason: 'retry before $seconds s');
        async.elapse(_ms);
        expect(robot.attempts, before + 1, reason: 'retry at $seconds s');
      }

      service.dispose();
    });
  });

  test('a stream error or close fails the attempt just like a refused '
      'upgrade', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = _service(robot);
      service.connect();
      robot.last.failStream(); // no route to host: error, then done
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, 2);

      robot.last.accept();
      async.flushMicrotasks();
      robot.last.drop();
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));
      async.elapse(const Duration(seconds: 2));
      expect(robot.attempts, 3);

      service.dispose();
    });
  });

  test('jittered retries stay within +-20 % of the nominal delay', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: ReconnectBackoff(random: _FixedRandom(0)), // 20 % early
      );
      service.connect();
      robot.last.refuse();
      async.flushMicrotasks();
      async.elapse(const Duration(milliseconds: 799));
      expect(robot.attempts, 1);
      async.elapse(_ms);
      expect(robot.attempts, 2);
      service.dispose();
    });
  });

  test('an accepted socket that drops without a message does not reset '
      'the backoff', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = _service(robot);
      service.connect();
      robot.last.refuse();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, 2);

      // The relay (stale robot socket) or the auth proxy accepts, then drops.
      robot.last.accept();
      async.flushMicrotasks();
      expect(service.connected, isTrue);
      robot.last.drop();
      async.flushMicrotasks();

      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, 2, reason: 'must not fall back to 1 s');
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, 3);

      service.dispose();
    });
  });

  test('the first rosbridge message resets the backoff', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 6); // next wait 30 s
      async.elapse(const Duration(seconds: 30));
      expect(robot.attempts, 7);

      robot.last.accept();
      async.flushMicrotasks();
      expect(backoff.failures, 6);
      robot.last.receive({
        'op': 'publish',
        'topic': '/robot/online',
        'msg': {'data': true},
      });
      async.flushMicrotasks();
      expect(backoff.failures, 0);

      robot.last.drop(); // a Wi-Fi blip: back in about a second
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, 8);

      service.dispose();
    });
  });

  test('pollers and publishers do not cut the wait short', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 6); // next wait 30 s
      final attempts = robot.attempts;

      RosbridgeServiceResponse? response;
      service
          .callService('/rosapi/topics', timeout: const Duration(seconds: 5))
          .then((value) => response = value);
      service.publish(
        '/cmd_vel',
        message: const {},
        type: 'geometry_msgs/msg/Twist',
      );
      service.connect();
      async.elapse(const Duration(seconds: 29));
      expect(robot.attempts, attempts);
      expect(response?.message, 'rosbridge connection timeout');
      expect(async.pendingTimers, hasLength(1));

      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, attempts + 1);

      service.dispose();
    });
  });

  test('reconnect() connects at once and starts the backoff over', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 8); // next wait 30 s
      final attempts = robot.attempts;

      service.reconnect();
      expect(robot.attempts, attempts + 1);
      expect(async.pendingTimers, isEmpty);

      robot.last.refuse();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, attempts + 2);

      service.dispose();
    });
  });

  test('retryNow() (app resume) skips the wait but leaves an attempt in '
      'flight alone', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 8);
      final attempts = robot.attempts;

      service.retryNow();
      expect(robot.attempts, attempts + 1);
      expect(async.pendingTimers, isEmpty);
      service.retryNow(); // still opening: no second socket
      expect(robot.attempts, attempts + 1);

      robot.last.refuse();
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(robot.attempts, attempts + 2);

      service.dispose();
    });
  });

  test('a new endpoint, relay path or the same endpoint again connects at '
      'once', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 8);

      service.configureEndpoint(url: 'ws://192.168.1.5:9090');
      expect(robot.uris.last, 'ws://192.168.1.5:9090');
      _failUntil(async, robot, backoff, failures: 8);

      const relay = 'wss://api.test/v1/relay/app/MW-7K3Q9P';
      service.configureEndpoint(url: relay, framed: true);
      expect(robot.uris.last, relay);
      expect(robot.last.protocols, ['mrelay1']);
      _failUntil(async, robot, backoff, failures: 8);

      final attempts = robot.attempts;
      service.configureEndpoint(url: relay, framed: true);
      expect(robot.attempts, attempts + 1);
      expect(async.pendingTimers, isEmpty);

      service.dispose();
    });
  });

  test('switching robots connects to the new one at once', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: '',
        connector: robot.connect,
        backoff: backoff,
      );
      final registry = RobotRegistry(
        rosbridge: service,
        store: MemoryPairingStore(),
        lanProbe: (url, headers) async => false,
      );
      registry.load();
      async.flushMicrotasks();
      registry.add(
        PairedRobot(id: 'MW-AAAAAA', secret: _secret, relayUrl: 'wss://a.test'),
      );
      async.flushMicrotasks();
      registry.add(
        PairedRobot(id: 'MW-BBBBBB', secret: _secret, relayUrl: 'wss://b.test'),
      );
      async.flushMicrotasks();
      expect(robot.uris.last, 'wss://b.test');
      _failUntil(async, robot, backoff, failures: 8);

      registry.select('MW-AAAAAA');
      async.flushMicrotasks();
      expect(robot.uris.last, 'wss://a.test');
      expect(async.pendingTimers, isEmpty);

      registry.dispose();
      service.dispose();
    });
  });

  test('dispose cancels the pending retry and later calls are no-ops', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = _service(robot);
      service.connect();
      robot.last.refuse();
      async.flushMicrotasks();
      expect(async.pendingTimers, hasLength(1));

      service.dispose();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 1));
      expect(robot.attempts, 1);

      service.reconnect();
      service.retryNow();
      service.connect();
      service.configureEndpoint(url: 'ws://other.test:9090');
      async.elapse(const Duration(hours: 1));
      expect(robot.attempts, 1);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('an attempt that fails after dispose arms no retry', () {
    fakeAsync((async) {
      final robot = _FakeRobot();
      final service = _service(robot);
      service.connect();
      service.dispose();
      robot.last.refuse();
      async.flushMicrotasks();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(hours: 1));
      expect(robot.attempts, 1);
    });
  });

  test('a long outage logs the first failure, every 20th and the '
      'recovery', () {
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) => lines.add('$message');
    addTearDown(() => debugPrint = originalDebugPrint);

    fakeAsync((async) {
      final robot = _FakeRobot();
      final backoff = ReconnectBackoff(jitter: 0);
      final service = RosbridgeService(
        url: _url,
        connector: robot.connect,
        backoff: backoff,
      );
      service.connect();
      _failUntil(async, robot, backoff, failures: 45);
      expect(lines, hasLength(3));
      expect(lines[0], contains('attempt 1, next in 1.0 s'));
      expect(lines[1], contains('attempt 20, next in 30.0 s'));
      expect(lines[2], contains('attempt 40, next in 30.0 s'));

      async.elapse(const Duration(seconds: 30));
      robot.last.accept();
      async.flushMicrotasks();
      robot.last.receive({'op': 'publish', 'topic': '/t', 'msg': {}});
      async.flushMicrotasks();
      expect(lines, hasLength(4));
      expect(lines.last, contains('back after 45 failures'));

      service.dispose();
    });
  });

  testWidgets('coming back to the foreground retries the robot now', (
    tester,
  ) async {
    final service = _RetrySpy();
    addTearDown(service.dispose);
    await tester.pumpWidget(
      Provider<RosbridgeService>.value(
        value: service,
        child: const RetryRosbridgeOnResume(child: SizedBox()),
      ),
    );

    for (final state in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(service.retries, 0);

    for (final state in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      tester.binding.handleAppLifecycleStateChanged(state);
    }
    expect(service.retries, 1);
  });
}

const _ms = Duration(milliseconds: 1);

RosbridgeService _service(_FakeRobot robot) => RosbridgeService(
  url: _url,
  connector: robot.connect,
  backoff: ReconnectBackoff(jitter: 0),
);

/// Let the current attempt and every retry fail until [backoff] has counted
/// [failures] in a row; the next retry is then armed but not yet due.
void _failUntil(
  FakeAsync async,
  _FakeRobot robot,
  ReconnectBackoff backoff, {
  required int failures,
}) {
  while (true) {
    robot.last.refuse();
    async.flushMicrotasks();
    expect(async.pendingTimers, hasLength(1));
    if (backoff.failures >= failures) {
      return;
    }
    final before = robot.attempts;
    async.elapse(const Duration(seconds: 30));
    expect(robot.attempts, before + 1);
  }
}

/// Hands out a fresh fake socket per connection attempt.
class _FakeRobot {
  final List<_FakeWebSocketChannel> channels = [];
  final List<String> uris = [];

  int get attempts => channels.length;
  _FakeWebSocketChannel get last => channels.last;

  WebSocketChannel connect(
    Uri uri, {
    Map<String, dynamic> headers = const {},
    List<String> protocols = const [],
  }) {
    uris.add(uri.toString());
    final channel = _FakeWebSocketChannel(protocols);
    channels.add(channel);
    return channel;
  }
}

class _FakeWebSocketChannel implements WebSocketChannel {
  _FakeWebSocketChannel(this.protocols);

  final List<String> protocols;
  final Completer<void> _ready = Completer<void>();
  final StreamController<dynamic> _incoming = StreamController<dynamic>(
    sync: true,
  );
  late final WebSocketSink _sink = _FakeWebSocketSink();

  /// The upgrade succeeded.
  void accept() => _ready.complete();

  /// The upgrade was refused (HTTP 503 from the relay, 401 from the proxy).
  void refuse() {
    _ready.completeError(WebSocketChannelException('HTTP 503 robot offline'));
  }

  /// The connection failed below the upgrade, reported on the stream.
  void failStream() {
    _incoming.addError(WebSocketChannelException('no route to host'));
    unawaited(_incoming.close());
  }

  /// The server closed an accepted socket.
  void drop() => unawaited(_incoming.close());

  void receive(Map<String, dynamic> message) =>
      _incoming.add(jsonEncode(message));

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
  @override
  void add(dynamic data) {}

  @override
  Future<void> close([int? closeCode, String? closeReason]) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RetrySpy extends RosbridgeService {
  _RetrySpy() : super(url: '');

  int retries = 0;

  @override
  void retryNow() => retries += 1;
}

class _FixedRandom implements math.Random {
  _FixedRandom(this.value);

  final double value;

  @override
  double nextDouble() => value;

  @override
  bool nextBool() => value >= 0.5;

  @override
  int nextInt(int max) => (value * max).floor();
}
