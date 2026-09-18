import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:mower_stdio/models/robot_info.dart';
import 'package:mower_stdio/providers/robot_info_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';

const _sample = {
  'robot_id': 'lubancat',
  'api_version': 1,
  'software': {
    'version': '0.6.0',
    'git_sha': 'c81a511deadbeef',
    'build_unix': 1789571662,
    'image': 'ghcr.io/edwards414/mower_path_planning:stable',
    'tag': 'stable',
    'digest': 'sha256:abc',
  },
  'firmware': {
    'running': {
      'version': '0.6.0',
      'git_sha': 'f22f2465',
      'build_unix': 1789571662,
      'dirty': false,
      'unversioned': false,
    },
    'bundled': {
      'version': '0.6.0',
      'git_sha': 'f22f2465aaaaaaaa',
      'build_unix': 1789571662,
      'dirty': false,
    },
    'sync': {'action': 'up_to_date', 'time': 1789571712, 'error': null},
    'up_to_date': true,
  },
  'update': {'state': 'idle', 'message': 'updated', 'time': 1789571700},
  'busy': false,
  'uptime_s': 12.5,
};

void main() {
  test('RobotInfo parses /robot/info and formats versions', () {
    final info = RobotInfo.tryParse(jsonEncode(_sample))!;
    expect(info.robotId, 'lubancat');
    expect(info.apiVersion, 1);
    expect(info.compatibility, RobotCompatibility.compatible);
    expect(info.software.label, '0.6.0+c81a511d');
    expect(info.imageTag, 'stable');
    expect(info.firmwareRunning.label, '0.6.0+f22f2465');
    expect(info.firmwareUpToDate, isTrue);
    expect(info.firmwareSyncAction, 'up_to_date');
    expect(info.firmwareSyncError, '');
    expect(info.update.state, 'idle');
    expect(info.update.inProgress, isFalse);
    expect(info.busy, isFalse);
    expect(info.uptimeS, 12.5);
  });

  test('RobotInfo tolerates missing sections and bad payloads', () {
    final info = RobotInfo.tryParse('{"api_version": 3}')!;
    expect(info.compatibility, RobotCompatibility.appTooOld);
    expect(info.software.isEmpty, isTrue);
    expect(info.software.label, '—');
    expect(info.firmwareUpToDate, isNull);
    expect(info.update.state, '');

    expect(RobotInfo.tryParse('{"api_version": 0}')!.compatibility,
        RobotCompatibility.robotTooOld);
    expect(RobotInfo.tryParse('not json'), isNull);
    expect(RobotInfo.tryParse('[1,2]'), isNull);
  });

  test('dirty / unversioned firmware is labelled', () {
    final v = ComponentVersion.fromJson({
      'version': '0.0.0',
      'git_sha': '00000000',
      'dirty': true,
      'unversioned': true,
    });
    expect(v.label, '0.0.0+00000000 (dirty, unversioned)');
  });

  test('provider subscribes, tracks compatibility and staleness', () async {
    final channel = _FakeWebSocketChannel();
    final sent = <Map<String, dynamic>>[];
    final sentSub = channel.sent.stream.cast<String>().listen(
      (s) => sent.add(jsonDecode(s) as Map<String, dynamic>),
    );
    final service = RosbridgeService(
      url: 'ws://robot.test:9090',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final provider = RobotInfoProvider(
      rosbridge: service,
      staleAfter: const Duration(milliseconds: 50),
      tick: const Duration(milliseconds: 10),
    );
    expect(provider.compatibility, RobotCompatibility.unknown);
    expect(provider.blocksOperation, isFalse);

    service.connect();
    channel.markReady();
    await _flushEvents();
    final subscribe = sent.firstWhere((m) => m['op'] == 'subscribe');
    expect(subscribe['topic'], '/robot/info');
    expect(subscribe['type'], 'std_msgs/msg/String');

    channel.addIncoming(
      jsonEncode({
        'op': 'publish',
        'topic': '/robot/info',
        'msg': {'data': jsonEncode(_sample)},
      }),
    );
    await _flushEvents();
    expect(provider.info?.robotId, 'lubancat');
    expect(provider.stale, isFalse);
    expect(provider.compatibility, RobotCompatibility.compatible);
    expect(provider.blocksOperation, isFalse);

    // a robot that is too old blocks operation until overridden
    channel.addIncoming(
      jsonEncode({
        'op': 'publish',
        'topic': '/robot/info',
        'msg': {
          'data': jsonEncode({..._sample, 'api_version': 0}),
        },
      }),
    );
    await _flushEvents();
    expect(provider.compatibility, RobotCompatibility.robotTooOld);
    expect(provider.blocksOperation, isTrue);
    provider.setOverrideCompatibility(true);
    expect(provider.blocksOperation, isFalse);
    provider.setOverrideCompatibility(false);

    // no message for a while -> stale -> unknown, and nothing is blocked
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(provider.stale, isTrue);
    expect(provider.compatibility, RobotCompatibility.unknown);
    expect(provider.blocksOperation, isFalse);

    provider.dispose();
    service.dispose();
    await sentSub.cancel();
  });

  test('requestUpdate calls /system/update and reports the answer', () async {
    final channel = _FakeWebSocketChannel();
    final sent = <Map<String, dynamic>>[];
    final sentSub = channel.sent.stream.cast<String>().listen(
      (s) => sent.add(jsonDecode(s) as Map<String, dynamic>),
    );
    final service = RosbridgeService(
      url: 'ws://robot.test:9090',
      connector: (_, {headers = const <String, dynamic>{}, protocols = const <String>[]}) => channel,
    );
    final provider = RobotInfoProvider(rosbridge: service);
    service.connect();
    channel.markReady();
    await _flushEvents();

    final future = provider.requestUpdate();
    await _flushEvents();
    expect(provider.actionPending, isTrue);
    final call = sent.firstWhere((m) => m['op'] == 'call_service');
    expect(call['service'], '/system/update');
    channel.addIncoming(
      jsonEncode({
        'op': 'service_response',
        'id': call['id'],
        'service': '/system/update',
        'result': true,
        'values': {'success': false, 'message': 'robot is busy'},
      }),
    );
    final response = await future;
    expect(response.success, isFalse);
    expect(provider.actionPending, isFalse);
    expect(provider.lastActionResult, contains('robot is busy'));

    provider.dispose();
    service.dispose();
    await sentSub.cancel();
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
