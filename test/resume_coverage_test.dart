// 繼續割草: the button on the 執行 panel that calls the robot's
// /resume_coverage. Everything goes through the real ExecutionControlSheet
// and MissionMockProvider against a fake rosbridge, which answers as the
// robot's mower_nav and mower_coverage do.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/coverage_checkpoint.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/execution_control_sheet.dart';
import 'package:mower_stdio/widgets/mission_next_step.dart';

const _button = ValueKey('resume-coverage');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  });

  group('reading the robot\'s checkpoint', () {
    Map<String, Object?> json({
      Object? zone = 8,
      Object? completed = 2,
      Object? total = 10,
      Object? available = true,
      Object? status = 'canceled',
    }) => {
      'checkpoint_available': available,
      'zone_id': zone,
      'completed_segments': completed,
      'total_segments': total,
      'status_text': status,
      'mission_id': 'm1',
    };

    test('takes what can be continued', () {
      final c = CoverageCheckpoint.fromJson(json())!;
      expect(c.zoneId, 8);
      expect(c.completedSegments, 2);
      expect(c.totalSegments, 10);
      expect(c.missionId, 'm1');
      // Stopped before the first segment ended, or by a restart.
      expect(CoverageCheckpoint.fromJson(json(completed: 0)), isNotNull);
      expect(CoverageCheckpoint.fromJson(json(status: 'running')), isNotNull);
    });

    test('leaves everything else out', () {
      for (final bad in <Object?>[
        null,
        'x',
        json(available: false),
        json(available: null),
        json(zone: -1),
        json(zone: null),
        json(zone: '8'),
        json(completed: 10),
        json(completed: 11),
        json(completed: -1),
        json(completed: null),
        json(total: 0),
        json(total: null),
        json(status: 'succeeded'),
      ]) {
        expect(CoverageCheckpoint.fromJson(bad), isNull, reason: '$bad');
      }
    });

    test('an execution is going while its status is 1, 2 or 3', () {
      expect(coverageProgressIsActive(const {'status': 1}), isTrue);
      expect(coverageProgressIsActive(const {'status': 2}), isTrue);
      expect(coverageProgressIsActive(const {'status': 3}), isTrue);
      for (final status in [0, 4, 5, 6]) {
        expect(coverageProgressIsActive({'status': status}), isFalse);
      }
      expect(coverageProgressIsActive(null), isFalse);
    });
  });

  group('when it shows', () {
    testWidgets(
      'after an app restart: the robot\'s checkpoint is all it needs',
      (tester) async {
        final ros = _FakeRos()..checkpoint(zone: 8, completed: 2, total: 10);

        // The first run of the app knows nothing but what the robot says.
        var provider = await _liveSheet(tester, ros);
        expect(find.byKey(_button), findsOneWidget);
        expect(find.text('Zone 8 還沒割完（已割完 2/10 段）'), findsOneWidget);
        await _freshen(tester, ros);
        expect(_enabled(tester), isTrue);
        // Zone 7 is what the panel has selected; the checkpoint decides.
        expect(provider.selectedZoneId, 7);

        await tester.pumpWidget(const SizedBox.shrink());
        provider.dispose();

        // Same robot, a new process of the app.
        provider = await _liveSheet(tester, ros);
        expect(find.byKey(_button), findsOneWidget);
        expect(find.text('Zone 8 還沒割完（已割完 2/10 段）'), findsOneWidget);
        expect(ros.callCount['/resume_coverage'], isNull);

        await _end(tester, provider, ros);
      },
    );

    testWidgets('after a reconnect it asks again', (tester) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      ros.emitState(RosbridgeConnectionState.disconnected);
      await tester.pump();
      expect(find.byKey(_button), findsNothing);

      // The mission finished while the link was down.
      ros.checkpoint(zone: 8, available: false, statusText: 'succeeded');
      final before = ros.callCount['/coverage_progress_status']!;
      await _prerequisites(tester, ros);
      expect(ros.callCount['/coverage_progress_status'], greaterThan(before));
      expect(find.byKey(_button), findsNothing);

      await _end(tester, provider, ros);
    });

    for (final (name, setup) in <(String, void Function(_FakeRos))>[
      (
        'a finished mission (the robot says so)',
        (ros) => ros.checkpoint(
          zone: 8,
          completed: 10,
          available: false,
          statusText: 'succeeded',
        ),
      ),
      (
        'a checkpoint marked available that says succeeded',
        (ros) => ros.checkpoint(zone: 8, statusText: 'succeeded'),
      ),
      (
        'a checkpoint with every segment done',
        (ros) => ros.checkpoint(zone: 8, completed: 10),
      ),
      ('no checkpoint', (ros) => ros.checkpoint(zone: -1, available: false)),
      (
        'a channel leg of a sequence (zone -1, the robot has no such zone)',
        (ros) => ros.checkpoint(zone: -1),
      ),
      ('a zone that is gone', (ros) => ros.checkpoint(zone: 99)),
      (
        'an old robot without the service',
        (ros) => ros.handlers['/coverage_progress_status'] = () => _response(
          '/coverage_progress_status',
          success: false,
          message: '/coverage_progress_status: service unavailable',
        ),
      ),
      (
        'an execution still reported as running',
        (ros) => ros.checkpoint(zone: 8, progressStatus: 2),
      ),
    ]) {
      testWidgets('not for $name', (tester) async {
        final ros = _FakeRos();
        setup(ros);
        final provider = await _liveSheet(tester, ros);
        expect(ros.callCount['/coverage_progress_status'], isNotNull);
        expect(find.byKey(_button), findsNothing);
        expect(find.textContaining('還沒割完'), findsNothing);
        await _end(tester, provider, ros);
      });
    }

    testWidgets('not for a zone with no path any more', (tester) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      ros.emit('/adapter/zone_summaries', {
        'data': jsonEncode([
          {'zoneId': 7, 'pointCount': 48, 'hasCoveragePath': true},
          {'zoneId': 8, 'pointCount': 0, 'hasCoveragePath': false},
        ]),
      });
      await tester.pump();
      expect(find.byKey(_button), findsNothing);

      await _end(tester, provider, ros);
    });

    testWidgets('not for a stale checkpoint: the zone\'s path changed size', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8, mission: 'm1');
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      // Regenerated: another path, which /resume_coverage would refuse. The
      // robot still says checkpoint_available, it never compares the paths.
      ros.emitSummaries(zone8Points: 60);
      await tester.pump();
      expect(find.byKey(_button), findsNothing);

      // Generated back to the same path: the robot would accept it again.
      ros.emitSummaries(zone8Points: 48);
      await tester.pump();
      expect(find.byKey(_button), findsOneWidget);

      // A new mission on the new path is a new checkpoint.
      ros.emitSummaries(zone8Points: 60);
      await tester.pump();
      ros.checkpoint(zone: 8, mission: 'm2');
      ros.handlers['/check_nav_status'] = () => _navState('failed');
      await _triggerNavPoll(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('goes while a mission runs and comes back when it stops', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      ros.handlers['/check_nav_status'] = () => _navState('running');
      await _triggerNavPoll(tester, ros);
      expect(provider.navStatus, NavMockStatus.executing);
      expect(find.byKey(_button), findsNothing);

      // No traffic for it during a mission, which matters on 4G.
      final asked = ros.callCount['/coverage_progress_status'];
      await _triggerNavPoll(tester, ros);
      await tester.pump(const Duration(seconds: 40));
      expect(ros.callCount['/coverage_progress_status'], asked);

      ros.checkpoint(zone: 7, completed: 3, total: 12, mission: 'm2');
      ros.handlers['/check_nav_status'] = () => _navState('failed');
      await _triggerNavPoll(tester, ros);
      expect(provider.navStatus, NavMockStatus.failed);
      expect(find.text('Zone 7 還沒割完（已割完 3/12 段）'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('goes when the navigation state can no longer be read', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      // Three lost answers: the app no longer knows whether the mower moves.
      ros.handlers['/check_nav_status'] = () =>
          _response('/check_nav_status', success: false, message: 'timeout');
      for (var i = 0; i < 3; i++) {
        await _triggerNavPoll(tester, ros);
      }
      expect(provider.navStatus, NavMockStatus.paused);
      expect(find.byKey(_button), findsNothing);

      await _end(tester, provider, ros);
    });

    testWidgets('asks again while the robot has not finished the progress', (
      tester,
    ) async {
      // mower_nav reports `canceled` a moment before it finishes the progress.
      final ros = _FakeRos()..checkpoint(zone: 8, progressStatus: 3);
      ros.handlers['/check_nav_status'] = () => _navState('canceled');
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsNothing);

      // No new navigation state to go by: the next tick asks again.
      ros.checkpoint(zone: 8, progressStatus: 4);
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_button), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('an answer from before a start is dropped', (tester) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);

      // The periodic check is on its way when a mission starts.
      final oldAnswer = Completer<RosbridgeServiceResponse>();
      ros.handlers['/coverage_progress_status'] = () => oldAnswer.future;
      final asked = ros.callCount['/coverage_progress_status']!;
      await tester.pump(const Duration(seconds: 31));
      expect(ros.callCount['/coverage_progress_status'], asked + 1);
      // Let the status poll of that tick finish: it would overwrite the start.
      await tester.pump();
      ros.emitSensors();
      provider.startExecution();
      await tester.pump();
      await tester.pump();
      expect(provider.navStatus, NavMockStatus.executing);

      // The mission ends quickly, and only then the old answer comes in. It
      // says the zone can be continued, which is no longer true.
      ros.handlers['/check_nav_status'] = () => _navState('completed');
      await _triggerNavPoll(tester, ros);
      expect(provider.navStatus, NavMockStatus.idle);
      oldAnswer.complete(_status(zone: 8));
      await tester.pump();
      await tester.pump();
      expect(find.byKey(_button), findsNothing);

      // The next tick asks about this run.
      ros.checkpoint(zone: 8, available: false, statusText: 'succeeded');
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      await tester.pump();
      expect(ros.callCount['/coverage_progress_status'], asked + 2);
      expect(find.byKey(_button), findsNothing);

      await _end(tester, provider, ros);
    });

    testWidgets('a lost answer on a bad link does not take the button away', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      final asked = ros.callCount['/coverage_progress_status']!;
      ros.handlers['/coverage_progress_status'] = () =>
          const RosbridgeServiceResponse(
            service: '/coverage_progress_status',
            result: false,
            values: {'success': false, 'message': 'rosbridge service timeout'},
          );
      await tester.pump(const Duration(seconds: 31));
      await tester.pump();
      expect(ros.callCount['/coverage_progress_status'], asked + 1);
      expect(find.byKey(_button), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('asks again every so often while it stays idle', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      // Another client (Studio) finished it, and the state read the same.
      ros.checkpoint(zone: 8, available: false, statusText: 'succeeded');
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.byKey(_button), findsOneWidget);
      await tester.pump(const Duration(seconds: 25));
      await tester.pump();
      expect(find.byKey(_button), findsNothing);

      await _end(tester, provider, ros);
    });

    testWidgets(
      'goes during a recording, a recording save and manual driving',
      (tester) async {
        final ros = _FakeRos()..checkpoint(zone: 8);
        final provider = await _liveSheet(tester, ros);
        expect(find.byKey(_button), findsOneWidget);

        ros.emitSensors();
        expect(await provider.startRecording(RecordObjectType.zone), isNull);
        await tester.pump();
        expect(provider.recordingType, RecordObjectType.zone);
        expect(find.byKey(_button), findsNothing);
        await provider.stopRecording(save: false);
        await tester.pump();
        expect(find.byKey(_button), findsOneWidget);

        ros.emitSensors();
        expect(
          provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0),
          isTrue,
        );
        await tester.pump();
        expect(provider.manualControlActive, isTrue);
        expect(find.byKey(_button), findsNothing);
        provider.publishManualVelocity(linearX: 0.0, angularZ: 0.0);
        await tester.pump();
        expect(find.byKey(_button), findsOneWidget);

        await _end(tester, provider, ros);
      },
    );

    testWidgets('scrolls into view when it appears: 取消 is at the bottom', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: -1, available: false);
      final provider = MissionMockProvider(rosbridge: ros);
      await tester.runAsync(_flushEvents);
      await tester.pumpWidget(_host(provider, height: 160));
      _emitLive(ros);
      await tester.pump();
      await tester.pump();
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pump();
      expect(position.pixels, greaterThan(0));

      ros.checkpoint(zone: 8);
      ros.handlers['/check_nav_status'] = () => _navState('failed');
      await _triggerNavPoll(tester, ros);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      final viewport = tester.getRect(find.byType(Scrollable).first);
      final title = tester.getRect(find.textContaining('還沒割完'));
      final button = tester.getRect(find.byKey(_button));
      expect(title.top, greaterThanOrEqualTo(viewport.top));
      expect(button.bottom, lessThanOrEqualTo(viewport.bottom));

      await _end(tester, provider, ros);
    });

    testWidgets('the map\'s next-step banner says so, ahead of a new start', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);

      // After an app restart the map opens on another panel.
      provider.selectMode(MissionMode.objects);
      var step = MissionNextStep.of(provider)!;
      expect(step.text, 'Zone 8 還沒割完，可以繼續割草');
      expect(step.actionLabel, '前往執行');
      expect(step.targetMode, MissionMode.run);

      provider.selectMode(MissionMode.run);
      step = MissionNextStep.of(provider)!;
      expect(step.text, 'Zone 8 還沒割完，可以繼續割草');
      expect(step.actionLabel, isNull);

      ros.checkpoint(zone: 8, available: false, statusText: 'succeeded');
      ros.handlers['/check_nav_status'] = () => _navState('completed');
      await _triggerNavPoll(tester, ros);
      expect(MissionNextStep.of(provider)!.text, startsWith('路徑已就緒'));

      await _end(tester, provider, ros);
    });

    testWidgets('never in demo mode, which has no robot', (tester) async {
      SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = MissionMockProvider(rosbridge: ros);
      await tester.runAsync(_flushEvents);
      await tester.pumpWidget(_host(provider));
      _emitLive(ros);
      await tester.pump();
      await tester.pump();
      expect(provider.mockDataEnabled, isTrue);
      expect(find.byKey(_button), findsNothing);
      expect(ros.callCount['/coverage_progress_status'], isNull);
      await _end(tester, provider, ros);
    });

    testWidgets('shows disabled, saying why, until the start checks pass', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = MissionMockProvider(rosbridge: ros);
      await tester.runAsync(_flushEvents);
      await tester.pumpWidget(_host(provider));
      _emitLive(ros, gps: false);
      await tester.pump();
      await tester.pump();
      await tester.pump();

      expect(find.byKey(_button), findsOneWidget);
      expect(_enabled(tester), isFalse);
      expect(find.text('機器人尚未就緒：GPS'), findsOneWidget);

      // The robot's own admission check blocks it the same way.
      await _freshen(tester, ros);
      expect(_enabled(tester), isTrue);
      expect(find.text('機器人尚未就緒：GPS'), findsNothing);
      ros.handlers['/check_nav_status'] = () => _navState(
        'failed',
        ready: false,
        blockReason: 'navigation health: pose is stale',
      );
      await _triggerNavPoll(tester, ros);
      await _freshen(tester, ros);
      expect(_enabled(tester), isFalse);
      expect(
        find.text('機器人尚未就緒：navigation health: pose is stale'),
        findsOneWidget,
      );

      await _end(tester, provider, ros);
    });
  });

  group('what it sends', () {
    testWidgets('asks first; confirmed, it is a normal start of that zone', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8, completed: 2, total: 10);
      final provider = await _liveSheet(tester, ros);

      await _tapButton(tester, ros);
      final dialog = find.byType(AlertDialog);
      expect(dialog, findsOneWidget);
      expect(
        find.descendant(
          of: dialog,
          matching: find.textContaining('Zone 8 已割完 2/10 段'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: dialog, matching: find.textContaining('機器人會開始移動')),
        findsOneWidget,
      );
      expect(ros.callCount['/resume_coverage'], isNull);

      // Not confirmed: nothing moves.
      await tester.tap(find.descendant(of: dialog, matching: find.text('取消')));
      await tester.pumpAndSettle();
      expect(ros.callCount['/resume_coverage'], isNull);
      expect(find.byKey(_button), findsOneWidget);

      await _tapButton(tester, ros);
      await _confirm(tester, ros);
      expect(
        ros.calls.where((c) => c.service == '/resume_coverage').single.args,
        // Named, not -1: a checkpoint moved on to another zone is refused.
        {'zone_id': 8},
      );

      // As after a normal start: running, the status, the stop button, and
      // the panel on the zone that is running.
      expect(provider.navStatus, NavMockStatus.executing);
      expect(provider.selectedMode, MissionMode.run);
      expect(provider.selectedZoneId, 8);
      expect(find.text('執行中'), findsOneWidget);
      expect(find.byKey(_button), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await tester.pump();
      await tester.pump();
      expect(ros.callCount['/cancel_nav2'], 1);

      await _end(tester, provider, ros);
    });

    testWidgets('a double tap opens one dialog and sends one call', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);

      await _freshen(tester, ros);
      await tester.tap(find.byKey(_button));
      await tester.tap(find.byKey(_button), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await _confirm(tester, ros);
      expect(find.byType(AlertDialog), findsNothing);
      expect(ros.callCount['/resume_coverage'], 1);

      await _end(tester, provider, ros);
    });

    testWidgets('a second call while the first is on its way sends nothing', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      final answer = Completer<RosbridgeServiceResponse>();
      ros.handlers['/resume_coverage'] = () => answer.future;

      ros.emitSensors();
      unawaited(provider.resumeCoverage(8));
      unawaited(provider.resumeCoverage(8));
      await tester.pump();
      expect(ros.callCount['/resume_coverage'], 1);
      expect(find.byKey(_button), findsNothing);
      expect(find.text('送出中'), findsOneWidget);
      expect(provider.resumeRefusal, isNull);

      answer.complete(_response('/resume_coverage', success: true));
      await tester.pump();
      await tester.pump();
      expect(provider.navStatus, NavMockStatus.executing);

      await _end(tester, provider, ros);
    });

    testWidgets('sends nothing if the checkpoint or the checks moved on while '
        'the dialog was open', (tester) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);

      await _tapButton(tester, ros);
      ros.emit('/adapter/zone_summaries', {
        'data': jsonEncode([
          {'zoneId': 7, 'pointCount': 48, 'hasCoveragePath': true},
          {'zoneId': 8, 'pointCount': 0, 'hasCoveragePath': false},
        ]),
      });
      await tester.pump();
      await _confirm(tester, ros);
      expect(ros.callCount['/resume_coverage'], isNull);
      expect(find.textContaining('狀態已改變'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('the robot\'s refusal is shown, and nothing is left running', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      ros.handlers['/resume_coverage'] = () =>
          _refusal('Cannot resume a coverage mission: navigation is active');

      await _tapButton(tester, ros);
      await _confirm(tester, ros);
      await tester.pump();

      expect(ros.callCount['/resume_coverage'], 1);
      expect(
        find.text(
          '無法繼續割草：Cannot resume a coverage mission: navigation is active',
        ),
        findsOneWidget,
      );
      expect(find.text('待命'), findsOneWidget);
      expect(provider.navStatus, NavMockStatus.idle);
      expect(
        provider.logs.where((l) => l.message.contains('navigation is active')),
        isNotEmpty,
      );
      // The checkpoint is still there: the person can try again.
      expect(find.byKey(_button), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('a refusal stays readable when the checkpoint goes with it', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      const reason =
          'No resumable coverage checkpoint (No coverage checkpoint)';
      ros.handlers['/resume_coverage'] = () {
        ros.checkpoint(zone: -1, available: false);
        return _refusal(reason);
      };

      await _tapButton(tester, ros);
      await _confirm(tester, ros);
      await tester.pump();

      expect(find.byKey(_button), findsNothing);
      expect(find.text('無法繼續割草：$reason'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('a rejected goal says what the robot does not: a new path', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      // What mower_coverage answers when mower_nav's admission finds another
      // path; the reason itself only reaches the robot's log.
      ros.handlers['/resume_coverage'] = () => _refusal(
        'Navigation action goal rejected: busy or a safety precondition failed',
      );

      await _tapButton(tester, ros);
      await _confirm(tester, ros);
      await tester.pump();

      expect(find.textContaining('goal rejected'), findsOneWidget);
      expect(find.text('如果這個區域的路徑重新生成過，就只能重新開始。'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets(
      'an unanswered call stays locked and keeps stopping, as a start',
      (tester) async {
        final ros = _FakeRos()..checkpoint(zone: 8);
        final provider = await _liveSheet(tester, ros);
        ros.handlers['/resume_coverage'] = () => const RosbridgeServiceResponse(
          service: '/resume_coverage',
          result: false,
          values: {'success': false, 'message': 'rosbridge service timeout'},
        );
        ros.handlers['/check_nav_status'] = () => _navState('uncertain');

        await _tapButton(tester, ros);
        await _confirm(tester, ros);
        await tester.pump();

        expect(provider.navStatus, NavMockStatus.paused);
        expect(provider.canDriveManually, isFalse);
        expect(find.byKey(_button), findsNothing);
        await tester.pump(const Duration(seconds: 2));
        await tester.pump();
        await tester.pump();
        expect(ros.callCount['/cancel_nav2'], greaterThanOrEqualTo(1));

        await _end(tester, provider, ros);
      },
    );

    testWidgets('a stop while the answer is on its way wins, as for a start', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros);
      final answer = Completer<RosbridgeServiceResponse>();
      ros.handlers['/resume_coverage'] = () => answer.future;

      await _tapButton(tester, ros);
      await _confirm(tester, ros);
      await tester.tap(find.widgetWithText(OutlinedButton, '取消'));
      await tester.pump();
      await tester.pump();
      expect(ros.callCount['/cancel_nav2'], 1);

      answer.complete(_response('/resume_coverage', success: true));
      await tester.pump();
      await tester.pump();
      expect(provider.navStatus, isNot(NavMockStatus.executing));
      expect(provider.selectedZoneId, 7);

      await _end(tester, provider, ros);
    });

    testWidgets('nothing resumes by itself', (tester) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      ros.handlers['/check_nav_status'] = () => _navState('failed');
      final provider = await _liveSheet(tester, ros);
      expect(find.byKey(_button), findsOneWidget);

      for (var i = 0; i < 5; i++) {
        await _triggerNavPoll(tester, ros);
        await tester.pump(const Duration(seconds: 31));
      }
      expect(ros.callCount['/resume_coverage'], isNull);
      expect(ros.callCount['/zone_exec_path'], isNull);
      expect(ros.callCount['/run_zone_sequence'], isNull);

      await _end(tester, provider, ros);
    });
  });

  group('zone sequences', () {
    testWidgets('says the zones after it will not follow, and runs only it', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8, completed: 1, total: 4);
      final provider = await _liveSheet(tester, ros, threeZones: true);
      provider.setRunAllZones(true);
      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'failed',
          'zone_ids': [7, 8, 9],
          'index': 1,
          'leg': 'zone',
          'zone_id': 8,
          'next_zone_id': null,
          'message': 'Zone 8 覆蓋路徑執行失敗或被取消，任務序列中止',
        }),
      });
      await tester.pump();

      const scope = '只會割完 Zone 8；Zone 9 不會接著割，之後要另外開始。';
      expect(find.text(scope), findsOneWidget);

      await _tapButton(tester, ros);
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining(scope),
        ),
        findsOneWidget,
      );
      await _confirm(tester, ros);

      expect(
        ros.calls.where((c) => c.service == '/resume_coverage').single.args,
        {'zone_id': 8},
      );
      expect(ros.callCount['/run_zone_sequence'], isNull);
      // The panel stops showing the plan of the sequence that ended.
      expect(provider.runAllZones, isFalse);
      expect(find.text('通道'), findsNothing);

      await _end(tester, provider, ros);
    });

    testWidgets('names no other zones when none is left or none is known', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros, threeZones: true);
      expect(find.text('只會割完 Zone 8。'), findsOneWidget);

      // The last zone of a sequence.
      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'canceled',
          'zone_ids': [7, 8],
          'index': 1,
          'leg': 'zone',
          'message': 'stop',
        }),
      });
      await tester.pump();
      expect(find.text('只會割完 Zone 8。'), findsOneWidget);

      // A sequence that stopped at another zone says nothing about this one.
      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'failed',
          'zone_ids': [7, 8, 9],
          'index': 0,
          'leg': 'zone',
          'message': 'stop',
        }),
      });
      await tester.pump();
      expect(find.text('只會割完 Zone 8。'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('no button while a sequence runs, even between two legs', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 8);
      final provider = await _liveSheet(tester, ros, threeZones: true);
      expect(find.byKey(_button), findsOneWidget);

      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'running',
          'zone_ids': [7, 8, 9],
          'index': 0,
          'leg': 'channel',
          'zone_id': 7,
          'next_zone_id': 8,
          'message': '走通道 zone 7 → zone 8',
        }),
      });
      // The navigation server reports the last leg as finished in the gap.
      ros.handlers['/check_nav_status'] = () => _navState('completed');
      await _triggerNavPoll(tester, ros);
      expect(find.byKey(_button), findsNothing);
      expect(provider.zoneSequenceRunning, isTrue);

      await _end(tester, provider, ros);
    });

    testWidgets('no button until the sequence has said it ended', (
      tester,
    ) async {
      final ros = _FakeRos()..checkpoint(zone: 7);
      final provider = await _liveSheet(tester, ros, threeZones: true);

      // The leg failed: the navigation state says so first. /resume_coverage
      // does not check for a sequence, so this side has to wait.
      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'running',
          'zone_ids': [7, 8, 9],
          'index': 0,
          'leg': 'zone',
          'zone_id': 7,
          'next_zone_id': null,
          'message': '[1/3] 割 zone 7',
        }),
      });
      ros.handlers['/check_nav_status'] = () => _navState('failed');
      await _triggerNavPoll(tester, ros);
      expect(provider.navStatus, NavMockStatus.failed);
      expect(find.byKey(_button), findsNothing);

      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'failed',
          'zone_ids': [7, 8, 9],
          'index': 0,
          'leg': 'zone',
          'zone_id': 7,
          'next_zone_id': null,
          'message': 'Zone 7 覆蓋路徑執行失敗或被取消，任務序列中止',
        }),
      });
      await tester.pump();
      expect(find.byKey(_button), findsOneWidget);
      expect(find.textContaining('Zone 8、Zone 9 不會接著割'), findsOneWidget);

      await _end(tester, provider, ros);
    });

    testWidgets('no button when the sequence stopped on a channel', (
      tester,
    ) async {
      // The channel's goal has zone -1, and its checkpoint replaced the zone's.
      final ros = _FakeRos()..checkpoint(zone: -1, completed: 0, total: 1);
      final provider = await _liveSheet(tester, ros, threeZones: true);
      ros.emit('/zone_sequence_status', {
        'data': jsonEncode({
          'state': 'failed',
          'zone_ids': [7, 8, 9],
          'index': 0,
          'leg': 'channel',
          'zone_id': 7,
          'next_zone_id': 8,
          'message': '通道 7→8 導航失敗或被取消，任務序列中止',
        }),
      });
      await tester.pump();
      expect(find.byKey(_button), findsNothing);
      await _end(tester, provider, ros);
    });
  });
}

Widget _host(MissionMockProvider provider, {double? height}) {
  return ChangeNotifierProvider<MissionMockProvider>.value(
    value: provider,
    child: MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topCenter,
          child: SizedBox(
            height: height,
            child: const SingleChildScrollView(child: ExecutionControlSheet()),
          ),
        ),
      ),
    ),
  );
}

/// The sheet on a connected robot with zones 7 and 8 (and 9) planned.
Future<MissionMockProvider> _liveSheet(
  WidgetTester tester,
  _FakeRos ros, {
  bool threeZones = false,
}) async {
  final provider = MissionMockProvider(rosbridge: ros);
  await tester.runAsync(_flushEvents);
  await tester.pumpWidget(_host(provider));
  _emitLive(ros, threeZones: threeZones);
  await tester.pump();
  await tester.pump();
  await tester.pump();
  return provider;
}

Future<void> _prerequisites(WidgetTester tester, _FakeRos ros) async {
  _emitLive(ros);
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _end(
  WidgetTester tester,
  MissionMockProvider provider,
  _FakeRos ros,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  provider.dispose();
  await tester.runAsync(ros.close);
}

bool _enabled(WidgetTester tester) =>
    tester.widget<ButtonStyleButton>(find.byKey(_button)).onPressed != null;

Future<void> _tapButton(WidgetTester tester, _FakeRos ros) async {
  await _freshen(tester, ros);
  await tester.tap(find.byKey(_button));
  await tester.pumpAndSettle();
  await _freshen(tester, ros);
}

Future<void> _confirm(WidgetTester tester, _FakeRos ros) async {
  ros.emitSensors();
  await tester.tap(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, '繼續割草'),
    ),
  );
  // Not pumpAndSettle: the progress bar of a running mission never settles.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

/// Freshness is on the wall clock (GPS: 300 ms), which goes on while a test
/// runs, also on a machine that is busy. So everything that needs it sends the
/// sensors again just before.
Future<void> _freshen(WidgetTester tester, _FakeRos ros) async {
  ros.emitSensors();
  await tester.pump();
}

Future<void> _triggerNavPoll(WidgetTester tester, _FakeRos ros) async {
  ros.emit('/robot/online', {'data': false});
  ros.emit('/robot/online', {'data': true});
  await tester.pump();
  await tester.pump();
  await tester.pump();
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

void _emitLive(_FakeRos ros, {bool gps = true, bool threeZones = false}) {
  ros.emitState(RosbridgeConnectionState.connected);
  ros.emit('/robot/online', {'data': true});
  ros.emitSensors(gps: gps);
  List<Map<String, double>> square(double x0) => [
    {'x': x0, 'y': 0.0},
    {'x': x0 + 4, 'y': 0.0},
    {'x': x0 + 4, 'y': 4.0},
    {'x': x0, 'y': 4.0},
  ];
  ros.emit('/adapter/marker_layers/zones', {
    'data': jsonEncode({
      'name': 'zones',
      'markers': [
        {'id': 7, 'points': square(0)},
        {'id': 8, 'points': square(10)},
        if (threeZones) {'id': 9, 'points': square(20)},
      ],
    }),
  });
  ros.emitSummaries(zone8Points: 48, zone9: threeZones);
  ros.emit('/adapter/marker_layers/coverage_path', {
    'data': jsonEncode({
      'name': 'coverage_path',
      'markers': [
        {
          'type': 'line_strip',
          'points': [
            {'x': 0.0, 'y': 0.0},
            {'x': 4.0, 'y': 0.0},
          ],
        },
      ],
    }),
  });
}

RosbridgeServiceResponse _response(
  String service, {
  required bool success,
  String message = '',
}) {
  return RosbridgeServiceResponse(
    service: service,
    result: success,
    values: {'success': success, 'message': message},
  );
}

/// What the robot's "no" looks like through ws_bridge: the call worked.
RosbridgeServiceResponse _refusal(String message) => RosbridgeServiceResponse(
  service: '/resume_coverage',
  result: true,
  values: {'success': false, 'message': message},
);

RosbridgeServiceResponse _navState(
  String state, {
  bool ready = true,
  String? blockReason,
}) => _response(
  '/check_nav_status',
  success: true,
  message: jsonEncode({
    'state': state,
    'task': null,
    'message': 'Navigation $state',
    'ready': ready,
    'block_reason': blockReason,
  }),
);

/// A /coverage_progress_status answer. [progressStatus] 4 = canceled.
RosbridgeServiceResponse _status({
  required int zone,
  int completed = 2,
  int total = 10,
  bool available = true,
  String statusText = 'canceled',
  String mission = 'm1',
  int progressStatus = 4,
}) {
  return RosbridgeServiceResponse(
    service: '/coverage_progress_status',
    result: true,
    values: {
      'success': true,
      'message': '',
      'progress': {'status': progressStatus, 'zone_id': zone},
      'checkpoint': {
        'status_text': statusText,
        'mission_id': mission,
        'zone_id': zone,
        'current_segment_index': completed + 1,
        'completed_segments': completed,
        'total_segments': total,
        'checkpoint_available': available,
        // floats it cannot send arrive as null (ws_bridge's JSON)
        'remaining_distance_m': null,
        'message': 'Resumable at segment ${completed + 1}/$total',
      },
    },
  );
}

class _FakeRos extends RosbridgeService {
  _FakeRos() : super(url: 'ws://robot.test:9090');

  final StreamController<RosbridgeTopicMessage> _messageController =
      StreamController<RosbridgeTopicMessage>.broadcast(sync: true);
  final StreamController<RosbridgeConnectionState> _stateController =
      StreamController<RosbridgeConnectionState>.broadcast(sync: true);
  final Map<String, FutureOr<RosbridgeServiceResponse> Function()> handlers =
      {};
  final Map<String, int> callCount = {};
  final List<({String service, Map<String, dynamic> args})> calls = [];
  int _sensorTick = 0;

  /// The robot's checkpoint from now on.
  void checkpoint({
    required int zone,
    int completed = 2,
    int total = 10,
    bool available = true,
    String statusText = 'canceled',
    String mission = 'm1',
    int progressStatus = 4,
  }) {
    handlers['/coverage_progress_status'] = () => _status(
      zone: zone,
      completed: completed,
      total: total,
      available: available,
      statusText: statusText,
      mission: mission,
      progressStatus: progressStatus,
    );
  }

  void emitSummaries({required int zone8Points, bool zone9 = false}) {
    emit('/adapter/zone_summaries', {
      'data': jsonEncode([
        {'zoneId': 7, 'pointCount': 48, 'hasCoveragePath': true},
        {'zoneId': 8, 'pointCount': zone8Points, 'hasCoveragePath': true},
        if (zone9) {'zoneId': 9, 'pointCount': 48, 'hasCoveragePath': true},
      ]),
    });
  }

  /// Pose, robot clock and /fix, one later than the last.
  void emitSensors({bool gps = true}) {
    _sensorTick += 1;
    final nanosec = 100000000 + _sensorTick * 1000;
    emit('/manual_command_clock', {
      'stamp': {'sec': 123, 'nanosec': nanosec},
      'frame_id': 'manual-session-v1:test-session',
    });
    emit('/adapter/robot_pose', {
      'pose': {
        'position': {'x': 1.0, 'y': 2.0, 'z': 0.0},
        'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
      },
    });
    if (gps) {
      emit('/fix', {
        'header': {
          'stamp': {'sec': 123, 'nanosec': nanosec},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 2,
        'position_covariance': [
          0.0001,
          0.0,
          0.0,
          0.0,
          0.0001,
          0.0,
          0.0,
          0.0,
          0.0004,
        ],
      });
    }
  }

  @override
  Stream<RosbridgeTopicMessage> get messages => _messageController.stream;

  @override
  Stream<RosbridgeConnectionState> get states => _stateController.stream;

  @override
  Future<void> loadSavedRobotIp() async {}

  @override
  void connect() {}

  @override
  void reconnect() {}

  @override
  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {}

  @override
  bool publish(
    String topic, {
    required Map<String, dynamic> message,
    String? type,
  }) => true;

  @override
  Future<RosbridgeServiceResponse> callService(
    String service, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async {
    callCount[service] = (callCount[service] ?? 0) + 1;
    calls.add((service: service, args: args));
    final handler = handlers[service];
    if (handler != null) return handler();
    if (service == '/check_nav_status') return _navState('idle');
    if (service == '/resume_coverage' || service == '/zone_exec_path') {
      // Accepted: the navigation server is running it from here on.
      handlers['/check_nav_status'] = () => _navState('running');
    }
    return _response(service, success: true);
  }

  void emitState(RosbridgeConnectionState state) => _stateController.add(state);

  void emit(String topic, Map<String, dynamic> message) => _messageController
      .add(RosbridgeTopicMessage(topic: topic, message: message));

  Future<void> close() async {
    await _messageController.close();
    await _stateController.close();
    super.dispose();
  }
}
