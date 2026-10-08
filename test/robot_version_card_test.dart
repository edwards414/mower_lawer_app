import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mower_stdio/models/robot_info.dart';
import 'package:mower_stdio/providers/robot_info_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/robot_version_card.dart';

/// The 版本與更新 card says one thing: whether the robot has the latest
/// version. No version numbers, no per-part rows, no small print.
void main() {
  testWidgets('says "已是最新版" and offers nothing to update', (tester) async {
    final h = await _Harness.pump(tester);
    h.push(_info());
    await tester.pump();

    expect(h.provider.versionStatus, VersionStatus.upToDate);
    expect(find.text('版本與更新'), findsOneWidget);
    expect(find.text('已是最新版'), findsOneWidget);
    expect(find.text('更新機器人'), findsNothing);
    expect(find.text('檢查更新'), findsNothing);
    // Restart stays, taking the whole row.
    expect(find.text('重新啟動'), findsOneWidget);
    expect(tester.getSize(find.byType(OutlinedButton)).width, greaterThan(300));

    // None of the old detail lines or chips.
    for (final gone in [
      'App',
      '機器人軟體',
      'STM32 韌體',
      '更新狀態',
      '相容',
      '最新',
      '支援機器人 API',
      '尚未收到 /robot/info',
    ]) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
    expect(find.textContaining('sha256'), findsNothing);
    expect(find.textContaining('016e4a7'), findsNothing);
    expect(find.textContaining('main'), findsNothing);
    expect(find.textContaining('API'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('says "有新版本" and updates after a confirmation', (tester) async {
    final h = await _Harness.pump(tester);
    h.push(_info(update: {'state': 'idle', 'available': true}));
    await tester.pump();

    expect(find.text('有新版本'), findsOneWidget);
    expect(find.text('更新機器人'), findsOneWidget);

    await tester.tap(find.text('更新機器人'));
    await tester.pumpAndSettle();
    // Nothing is sent before the operator agrees.
    expect(h.calls, isEmpty);
    await tester.tap(find.text('確定'));
    await tester.pump();
    expect(h.calls, ['/system/update']);

    // The robot starts pulling: the card says so, and holds the buttons.
    h.push(_info(update: {'state': 'pulling', 'available': true}));
    await tester.pump();
    expect(find.text('更新中…'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );

    await h.dispose(tester);
  });

  testWidgets('a refused request is reported once, not left as small print', (
    tester,
  ) async {
    final h = await _Harness.pump(tester)
      ..failWith = 'robot is busy';
    h.push(_info(update: {'state': 'idle', 'available': true}));
    await tester.pump();

    await tester.tap(find.text('更新機器人'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('確定'));
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('robot is busy'), findsOneWidget);
    expect(find.byType(SnackBar), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('a moving robot greys the update out and says why', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    h.push(_info(update: {'state': 'idle', 'available': true}, busy: true));
    await tester.pump();

    expect(find.text('有新版本'), findsOneWidget);
    expect(find.text('更新機器人'), findsNothing);
    expect(find.text('機器人忙碌中'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );

    await h.dispose(tester);
  });

  testWidgets('before the first check it offers one, which works on the move', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    // No update-check fields yet; the robot is also busy (moving).
    h.push(_info(update: {'state': 'idle'}, busy: true));
    await tester.pump();

    expect(h.provider.versionStatus, VersionStatus.notChecked);
    expect(find.text('尚未檢查更新'), findsOneWidget);
    expect(find.text('更新機器人'), findsNothing);

    await tester.tap(find.text('檢查更新'));
    await tester.pump();
    // No dialog: looking the channel up changes nothing on the robot.
    expect(find.byType(AlertDialog), findsNothing);
    expect(h.calls, ['/system/check_update']);

    await h.dispose(tester);
  });

  testWidgets('an API 1 robot cannot check, so it keeps the plain update', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    h.push(_info(api: 1, update: {'state': 'idle'}));
    await tester.pump();

    expect(find.text('尚未檢查更新'), findsOneWidget);
    expect(find.text('檢查更新'), findsNothing);
    expect(find.text('更新機器人'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('says nothing about versions while the robot is out of reach', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    expect(find.text('尚未連線到機器人'), findsOneWidget);
    expect(find.text('更新機器人'), findsNothing);
    expect(
      tester.widget<OutlinedButton>(find.byType(OutlinedButton)).onPressed,
      isNull,
    );

    await h.dispose(tester);
  });

  testWidgets('a robot without the checker falls back to the plain update', (
    tester,
  ) async {
    final h = await _Harness.pump(tester)
      ..failWith = 'service does not exist';
    // API 2, but its software predates the checker: no check fields at all.
    h.push(_info(update: {'state': 'idle'}));
    await tester.pump();
    expect(find.text('檢查更新'), findsOneWidget);
    expect(find.text('更新機器人'), findsNothing);

    await tester.tap(find.text('檢查更新'));
    await tester.pump();
    await tester.pump();
    // Said once, and the way out (a plain update pulls the build that has the
    // checker) is offered instead of a button that can only fail.
    expect(find.textContaining('service does not exist'), findsOneWidget);
    expect(h.provider.checkUpdateUnsupported, isTrue);
    expect(find.text('檢查更新'), findsNothing);
    expect(find.text('更新機器人'), findsOneWidget);

    // Once the robot does report a check, the card trusts it again.
    h.push(_info());
    await tester.pump();
    expect(h.provider.checkUpdateUnsupported, isFalse);
    expect(find.text('已是最新版'), findsOneWidget);

    await h.dispose(tester);
  });

  group('the too-old banner', () {
    testWidgets('updates through the same ask-first, say-if-refused path', (
      tester,
    ) async {
      final h = await _Harness.pump(tester, child: const CompatibilityNotice())
        ..failWith = 'robot is busy';
      h.push(_info(api: 0));
      await tester.pump();
      expect(find.text('機器人軟體太舊，請更新機器人'), findsOneWidget);

      await tester.tap(find.text('更新機器人'));
      await tester.pumpAndSettle();
      // It asks first, and sends nothing until the operator agrees.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(h.calls, isEmpty);
      await tester.tap(find.text('確定'));
      await tester.pump();
      await tester.pump();

      expect(h.calls, ['/system/update']);
      // A refusal is no longer lost: this banner does not print it.
      expect(find.textContaining('robot is busy'), findsOneWidget);

      await h.dispose(tester);
    });

    testWidgets('does not offer an update to a robot that is busy', (
      tester,
    ) async {
      final h = await _Harness.pump(tester, child: const CompatibilityNotice());
      h.push(_info(api: 0, busy: true));
      await tester.pump();

      final button = tester.widget<TextButton>(
        find.widgetWithText(TextButton, '更新機器人'),
      );
      expect(button.onPressed, isNull);

      await h.dispose(tester);
    });
  });

  group('versionStatus', () {
    // [info] -> what the card should say.
    final cases = <String, (Map<String, dynamic>, VersionStatus, String)>{
      'checked, nothing newer': (_info(), VersionStatus.upToDate, '已是最新版'),
      'newer on the channel': (
        _info(update: {'state': 'idle', 'available': true}),
        VersionStatus.newerAvailable,
        '有新版本',
      ),
      'pulling': (
        _info(update: {'state': 'pulling', 'available': true}),
        VersionStatus.updating,
        '更新中…',
      ),
      'restarting': (
        _info(update: {'state': 'restarting'}),
        VersionStatus.updating,
        '更新中…',
      ),
      // API 1 robots only report the state of their last update attempt.
      'API 1, nothing to pull': (
        _info(api: 1, update: {'state': 'up_to_date'}),
        VersionStatus.upToDate,
        '已是最新版',
      ),
      'last update failed, still behind': (
        _info(update: {'state': 'failed', 'available': true}),
        VersionStatus.newerAvailable,
        '有新版本',
      ),
      'last update failed, unknown': (
        _info(update: {'state': 'failed'}),
        VersionStatus.updateFailed,
        '上次更新失敗',
      ),
      // A failure an up-to-date robot no longer cares about.
      'last update failed, but nothing newer': (
        _info(update: {'state': 'failed', 'available': false}),
        VersionStatus.upToDate,
        '已是最新版',
      ),
      'registry unreachable': (
        _info(update: {'state': 'idle', 'check_error': 'timeout'}),
        VersionStatus.checkFailed,
        '無法檢查更新',
      ),
      // A failed check does not make an old "nothing newer" true.
      'registry unreachable after an old all-clear': (
        _info(
          update: {
            'state': 'idle',
            'available': false,
            'check_error': 'timeout',
          },
        ),
        VersionStatus.checkFailed,
        '無法檢查更新',
      ),
      'firmware would not flash': (
        _info(firmwareSync: {'action': 'failed', 'error': 'crc'}),
        VersionStatus.firmwareFailed,
        '韌體燒錄失敗',
      ),
      // Firmware and software disagree with nothing newer out: not "latest".
      'firmware differs, nothing newer': (
        _info(firmwareUpToDate: false),
        VersionStatus.firmwareMismatch,
        '韌體版本不符，請重新啟動',
      ),
      'but something newer comes first': (
        _info(
          firmwareUpToDate: false,
          update: {'state': 'idle', 'available': true},
        ),
        VersionStatus.newerAvailable,
        '有新版本',
      ),
      // An update under way is what the robot is doing, whatever else holds.
      'too old, and pulling': (
        _info(api: 0, update: {'state': 'pulling'}),
        VersionStatus.updating,
        '更新中…',
      ),
      'robot too old for the app': (
        _info(api: 0),
        VersionStatus.robotTooOld,
        '機器人版本太舊，請更新',
      ),
      'app too old for the robot': (
        _info(api: 9),
        VersionStatus.appTooOld,
        'App 版本太舊，請更新 App',
      ),
    };
    for (final entry in cases.entries) {
      testWidgets(entry.key, (tester) async {
        final (info, status, label) = entry.value;
        final h = await _Harness.pump(tester);
        h.push(info);
        await tester.pump();

        expect(h.provider.versionStatus, status);
        expect(find.text(label), findsOneWidget);

        await h.dispose(tester);
      });
    }
  });
}

/// A `/robot/info` payload; by default a current, idle, API 2 robot.
Map<String, dynamic> _info({
  int api = 2,
  Map<String, dynamic>? update,
  Map<String, dynamic>? firmwareSync,
  bool firmwareUpToDate = true,
  bool busy = false,
}) => {
  'robot_id': 'MW-0CFP37',
  'api_version': api,
  'software': {
    'version': '016e4a7',
    'tag': 'main',
    'digest': 'sha256:b1f275a6921f',
  },
  'firmware': {
    'up_to_date': firmwareUpToDate,
    'sync': firmwareSync ?? {'action': 'up_to_date', 'error': null},
  },
  'update':
      update ??
      {
        'state': 'idle',
        'message': 'updated to docker.io/fxrbindi/mower_path_planning:main',
        'available': false,
        'check_error': null,
        'checked_at': 1791449795,
        'remote_digest': 'sha256:b1f275a6921f',
      },
  'busy': busy,
};

class _Harness {
  _Harness(this.provider, this.ros);

  final RobotInfoProvider provider;
  final _InfoRosbridge ros;

  List<String> get calls => ros.calls;
  set failWith(String? message) => ros.failWith = message;

  void push(Map<String, dynamic> info) => ros.push(info);

  static Future<_Harness> pump(
    WidgetTester tester, {
    Widget child = const RobotVersionCard(),
  }) async {
    final ros = _InfoRosbridge();
    final provider = RobotInfoProvider(rosbridge: ros);
    await tester.pumpWidget(
      ChangeNotifierProvider<RobotInfoProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: Padding(padding: const EdgeInsets.all(16), child: child),
          ),
        ),
      ),
    );
    return _Harness(provider, ros);
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    provider.dispose();
    await ros.close();
  }
}

class _InfoRosbridge extends RosbridgeService {
  _InfoRosbridge() : super(url: 'ws://robot.test:9090');

  final _messages = StreamController<RosbridgeTopicMessage>.broadcast();
  final List<String> calls = [];

  /// Make service calls fail with this message.
  String? failWith;

  void push(Map<String, dynamic> info) => _messages.add(
    RosbridgeTopicMessage(
      topic: '/robot/info',
      message: {'data': jsonEncode(info)},
    ),
  );

  Future<void> close() => _messages.close();

  @override
  Stream<RosbridgeTopicMessage> get messages => _messages.stream;

  @override
  Stream<RosbridgeConnectionState> get states => const Stream.empty();

  @override
  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {}

  @override
  void unsubscribe(String topic) {}

  @override
  Future<RosbridgeServiceResponse> callService(
    String service, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    calls.add(service);
    final failure = failWith;
    return RosbridgeServiceResponse(
      service: service,
      result: true,
      values: {'success': failure == null, 'message': failure ?? 'ok'},
    );
  }
}
