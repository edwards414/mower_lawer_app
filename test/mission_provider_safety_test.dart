import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/image_mission_draft.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/add_object_sheet.dart';
import 'package:mower_stdio/widgets/map_record_bar.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  });

  test(
    'live mission requires fresh robot, GPS, pose and selected-zone path',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();

      expect(provider.mockDataEnabled, isFalse);
      expect(provider.canStartMission, isFalse);

      _emitLivePrerequisites(ros);
      await _flushEvents();

      expect(provider.rosConnected, isTrue);
      expect(provider.robotOnline, isTrue);
      expect(provider.hasFreshRobotPose, isTrue);
      expect(provider.hasFreshGpsFix, isTrue);
      expect(provider.coverageReady, isTrue);
      expect(provider.canStartMission, isTrue);

      ros.emit('/adapter/zone_summaries', {
        'data': jsonEncode([
          {'zoneId': 7, 'hasCoveragePath': false},
        ]),
      });
      expect(provider.canStartMission, isFalse);

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'image mission can start its own zone, which the zone layer never has',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.selectedZoneId, 7);

      ros.handlers['/boustrophedon_coverage/set_parameters'] = () =>
          const RosbridgeServiceResponse(
            service: '/boustrophedon_coverage/set_parameters',
            result: true,
            values: {
              'results': [
                {'successful': true, 'reason': ''},
              ],
            },
          );
      provider.imageMissionDraft = ImageMissionDraft(
        sourceName: 'star.png',
        width: 2,
        height: 2,
        grayscale: Uint8List(4),
        freeMask: Uint8List.fromList([255, 255, 255, 255]),
        threshold: 128,
        startPose: const ImageMissionStartPose(
          point: MapPoint(0, 0),
          headingRad: 0,
        ),
        placement: const ImageMissionPlacement(mapAnchor: MapPoint(2, 2)),
      );
      expect(await provider.submitImageMissionDraft(), isTrue);
      expect(ros.callCount['/import_image_mask'], 1);
      expect(ros.callCount['/generate_coverage_path'], 1);
      expect(provider.selectedZoneId, ImageMissionDraft.defaultZoneId);

      // The robot plans the image zone: map_manage reports it in the zone
      // summaries, while the zone layer still holds only the recorded zone.
      ros.emit('/adapter/zone_summaries', {
        'data': jsonEncode([
          {'zoneId': 7, 'hasCoveragePath': false},
          {'zoneId': ImageMissionDraft.defaultZoneId, 'hasCoveragePath': true},
        ]),
      });
      ros.emit('/adapter/marker_layers/coverage_path', {
        'data': jsonEncode({
          'name': 'coverage_path',
          'markers': [
            {
              'type': 'line_strip',
              'points': [
                {'x': 2.0, 'y': 2.0},
                {'x': 2.1, 'y': 2.0},
              ],
            },
          ],
        }),
      });
      ros.emit('/adapter/marker_layers/zones', {
        'data': jsonEncode({
          'name': 'zones',
          'markers': [
            {
              'id': 7,
              'points': [
                {'x': 0.0, 'y': 0.0},
                {'x': 4.0, 'y': 0.0},
                {'x': 4.0, 'y': 4.0},
              ],
            },
          ],
        }),
      });
      await _flushEvents();

      expect(provider.selectedZoneId, ImageMissionDraft.defaultZoneId);
      expect(provider.canStartMission, isTrue);

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'zone sequence needs every zone planned and a channel between each pair',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      _emitTwoZones(ros, channel: false);
      await _flushEvents();

      expect(provider.sequenceZoneIds, [7, 8]);
      expect(provider.canStartZoneSequence, isFalse);
      expect(provider.zoneSequenceBlockReason, contains('通道'));

      _emitTwoZones(ros);
      await _flushEvents();
      expect(provider.zoneSequenceBlockReason, isNull);
      expect(provider.canStartZoneSequence, isTrue);

      ros.emit('/adapter/zone_summaries', {
        'data': jsonEncode([
          {'zoneId': 7, 'hasCoveragePath': true},
          {'zoneId': 8, 'hasCoveragePath': false},
        ]),
      });
      expect(provider.canStartZoneSequence, isFalse);
      expect(provider.zoneSequenceBlockReason, contains('Zone 8'));

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'zone sequence stays locked between legs until its status ends',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      _emitTwoZones(ros);
      await _flushEvents();

      provider.startZoneSequence();
      await _flushEvents();
      final start = ros.calls.singleWhere(
        (c) => c.service == '/run_zone_sequence',
      );
      expect(start.args['zone_ids'], [7, 8]);
      expect(start.args['channel_proximity_m'], 1.5);
      expect(provider.navStatus, NavMockStatus.executing);

      // The service answers before the first leg is dispatched: an idle
      // report in between must not unlock the controls.
      ros.handlers['/check_nav_status'] = () => _navState('idle');
      await _triggerNavPoll(ros);
      expect(provider.navStatus, NavMockStatus.executing);
      expect(provider.canDriveManually, isFalse);

      // Zone 7 finished: the navigation server reports it completed while the
      // sequence is about to drive the channel.
      ros.emit('/zone_sequence_status', _sequenceStatus('running', 0, 'zone'));
      ros.handlers['/check_nav_status'] = () => _navState('completed');
      await _triggerNavPoll(ros);
      expect(provider.navStatus, NavMockStatus.executing);
      expect(provider.canDriveManually, isFalse);
      expect(provider.canStartMission, isFalse);
      ros.emit(
        '/zone_sequence_status',
        _sequenceStatus('running', 0, 'channel'),
      );
      await _triggerNavPoll(ros);
      expect(provider.navStatus, NavMockStatus.executing);

      ros.emit('/zone_sequence_status', _sequenceStatus('completed', 1, ''));
      await _flushEvents();
      expect(provider.navStatus, NavMockStatus.idle);
      expect(provider.coverageProgress, 1.0);
      expect(provider.zoneSequenceRunning, isFalse);

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'generating the path rebuilds the maps first, channels when there are any',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      _emitTwoZones(ros, channel: false);
      await _flushEvents();
      List<String> planningCalls() => ros.calls
          .map((c) => c.service)
          .where(
            (s) => s.startsWith('/create_') || s == '/generate_coverage_path',
          )
          .toList();

      provider.runPlanningStep('coverage');
      await _flushEvents();
      expect(planningCalls(), [
        '/create_free_space',
        '/create_risk_map',
        '/generate_coverage_path',
      ]);

      ros.calls.clear();
      _emitTwoZones(ros);
      await _flushEvents();
      provider.runPlanningStep('coverage');
      await _flushEvents();
      expect(planningCalls(), [
        '/create_free_space',
        '/create_risk_map',
        '/create_chennal_map',
        '/generate_coverage_path',
      ]);

      // An image mission only re-plans: a free-space rebuild would replace
      // its zone.
      ros.handlers['/boustrophedon_coverage/set_parameters'] = () =>
          const RosbridgeServiceResponse(
            service: '/boustrophedon_coverage/set_parameters',
            result: true,
            values: {
              'results': [
                {'successful': true, 'reason': ''},
              ],
            },
          );
      provider.imageMissionDraft = ImageMissionDraft(
        sourceName: 'star.png',
        width: 2,
        height: 2,
        grayscale: Uint8List(4),
        freeMask: Uint8List.fromList([255, 255, 255, 255]),
        threshold: 128,
        startPose: const ImageMissionStartPose(
          point: MapPoint(0, 0),
          headingRad: 0,
        ),
        placement: const ImageMissionPlacement(mapAnchor: MapPoint(2, 2)),
      );
      expect(await provider.submitImageMissionDraft(), isTrue);
      ros.calls.clear();
      provider.runPlanningStep('coverage');
      await _flushEvents();
      expect(planningCalls(), ['/generate_coverage_path']);

      provider.dispose();
      await ros.close();
    },
  );

  test('stopping a zone sequence stops it before the current goal', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    _emitTwoZones(ros);
    await _flushEvents();
    provider.startZoneSequence();
    await _flushEvents();
    ros.emit('/zone_sequence_status', _sequenceStatus('running', 0, 'zone'));

    provider.cancelExecution();
    await _flushEvents();
    final order = ros.calls
        .map((c) => c.service)
        .where((s) => s == '/stop_zone_sequence' || s == '/cancel_nav2')
        .toList();
    expect(order, ['/stop_zone_sequence', '/cancel_nav2']);

    provider.dispose();
    await ros.close();
  });

  test(
    'mission command is single-flight and failed cancel stays active',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();

      final startResponse = Completer<RosbridgeServiceResponse>();
      ros.handlers['/zone_exec_path'] = () => startResponse.future;
      provider.coverageProgress = 1.0;
      provider.currentSegment = 9;
      provider.startExecution();
      provider.startExecution();
      await _flushEvents();

      expect(ros.callCount['/zone_exec_path'], 1);
      expect(provider.navCommandPending, isTrue);

      startResponse.complete(_response('/zone_exec_path', success: true));
      await _flushEvents();
      expect(provider.navStatus, NavMockStatus.executing);
      expect(provider.coverageProgress, 0.0);
      expect(provider.currentSegment, 0);

      provider.startRecording(RecordObjectType.zone);
      expect(ros.callCount['/record_zone_start'], isNull);
      expect(
        provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0),
        isFalse,
      );
      expect(ros.published, isEmpty);
      expect(
        provider.publishManualVelocity(linearX: 0.0, angularZ: 0.0),
        isTrue,
      );
      expect(ros.published, hasLength(1));
      expect(ros.published.single.message['header']['stamp'], {
        'sec': 123,
        'nanosec': 456,
      });
      expect(ros.published.single.topic, '/app_joy_cmd');
      expect(
        ros.published.single.message['header']['frame_id'],
        'manual-session-v1:test-session',
      );

      ros.handlers['/cancel_nav2'] = () =>
          _response('/cancel_nav2', success: false, message: 'cancel rejected');
      provider.cancelExecution();
      await _flushEvents();

      expect(provider.navStatus, NavMockStatus.executing);
      expect(provider.cancelPending, isFalse);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'completed',
          'task': null,
          'message': 'Navigation completed',
        }),
      );
      ros.emit('/robot/online', {'data': false});
      ros.emit('/robot/online', {'data': true});
      await _flushEvents();
      expect(provider.navStatus, NavMockStatus.idle);
      expect(provider.coverageProgress, 1.0);

      provider.dispose();
      await ros.close();
    },
  );

  test('recording UI changes only after backend acknowledgements', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();

    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: false, message: 'busy');
    provider.startRecording(RecordObjectType.zone);
    await _flushEvents();
    expect(provider.recordingType, isNull);

    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    provider.startRecording(RecordObjectType.zone);
    await _flushEvents();
    expect(provider.recordingType, RecordObjectType.zone);
    expect(provider.canStartMission, isFalse);
    expect(provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0), isTrue);
    expect(provider.manualControlActive, isTrue);
    provider.startExecution();
    expect(ros.callCount['/zone_exec_path'], isNull);

    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: false, message: 'not saved');
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.recordingType, RecordObjectType.zone);
    expect(provider.manualControlActive, isFalse);
    expect((ros.published.last.message['twist'] as Map)['linear'], {
      'x': 0.0,
      'y': 0.0,
      'z': 0.0,
    });

    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: true);
    ros.handlers['/save_zone_list'] = () => _response(
      '/save_zone_list',
      success: true,
      message: '部分成功：risk list failed',
    );
    final endCallsBeforePartialSave = ros.callCount['/record_zone_end'] ?? 0;
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.recordingType, isNull);
    expect(provider.hasPendingRecordSave, isTrue);
    expect(ros.callCount['/record_zone_end'], endCallsBeforePartialSave + 1);

    final endCallsBeforeRetry = ros.callCount['/record_zone_end'];
    ros.handlers['/save_zone_list'] = () =>
        _response('/save_zone_list', success: true);
    expect(await provider.retryPendingRecordSave(), isTrue);
    expect(provider.hasPendingRecordSave, isFalse);
    expect(ros.callCount['/record_zone_end'], endCallsBeforeRetry);

    provider.dispose();
    await ros.close();
  });

  test('startRecording says why it did not start', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();

    // Robot not connected yet: nothing is sent, the reason is returned.
    final offline = await provider.startRecording(RecordObjectType.zone);
    expect(offline, contains('無法開始記錄'));
    expect(ros.callCount['/record_zone_start'], isNull);
    expect(provider.recordingType, isNull);

    _emitLivePrerequisites(ros);
    await _flushEvents();

    // The robot refuses: recording UI stays off and the caller is told why.
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: false, message: 'busy');
    expect(await provider.startRecording(RecordObjectType.zone), '無法開始記錄：busy');
    expect(provider.recordingType, isNull);

    // Accepted: null means started; a second start explains it is running.
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    expect(provider.recordingType, RecordObjectType.zone);
    expect(
      await provider.startRecording(RecordObjectType.risk),
      contains('請先儲存或取消'),
    );
    expect(ros.callCount['/risk_zone_start'], isNull);

    // A stopped-but-unsaved recording blocks the next one with its reason.
    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: true);
    ros.handlers['/save_zone_list'] = () =>
        _response('/save_zone_list', success: false, message: 'disk');
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.hasPendingRecordSave, isTrue);
    expect(
      await provider.startRecording(RecordObjectType.channel),
      contains('尚未持久化'),
    );
    expect(ros.callCount['/channel_record_start'], isNull);

    provider.dispose();
    await ros.close();
  });

  test('a refused record start shows the robot\'s own reason', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();

    // mower_record's RTK gate (all three kinds), and the datum gate.
    const rtk = 'RTK 尚未 fixed，無法開始 zone 記錄（GPS status=0，RTK fixed 為 2）';
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: false, message: rtk);
    // it already says 「無法開始」: shown as is, no prefix
    expect(await provider.startRecording(RecordObjectType.zone), rtk);
    expect(provider.recordingType, isNull);
    expect(provider.recordCommandPending, isFalse);
    // The log keeps the robot's answer too.
    expect(
      provider.logs.where((e) => e.level == 'ERROR' && e.message == rtk),
      hasLength(1),
    );

    const datum = 'datum 尚未鎖定（等待 RTK fixed），無法開始 risk 記錄';
    ros.handlers['/risk_zone_start'] = () =>
        _response('/risk_zone_start', success: false, message: datum);
    expect(
      await provider.startRecording(RecordObjectType.risk),
      datum,
    );

    const stale = 'RTK 尚未 fixed，無法開始 channel 記錄（GPS /fix 已 1.1 s 未更新）';
    ros.handlers['/channel_record_start'] = () =>
        _response('/channel_record_start', success: false, message: stale);
    expect(
      await provider.startRecording(RecordObjectType.channel),
      stale,
    );

    // No reason from the robot: the generic text, pointing at the log.
    for (final message in ['', '  ']) {
      ros.handlers['/record_zone_start'] = () =>
          _response('/record_zone_start', success: false, message: message);
      expect(
        await provider.startRecording(RecordObjectType.zone),
        '機器人沒有接受開始記錄，詳見日誌',
      );
    }
    expect(provider.recordingType, isNull);

    provider.dispose();
    await ros.close();
  });

  test(
    'RTK fixed is read from /fix the way the robot recorder reads it',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();

      // Offline: nothing is known, so nothing is claimed.
      expect(provider.recordStartRtkHint, isNull);
      expect(provider.recordingRtkWarning, isNull);

      // Connected, no /fix yet.
      ros.emitState(RosbridgeConnectionState.connected);
      expect(provider.rtkNotFixedReason, '尚未收到 GPS /fix');
      expect(
        provider.recordStartRtkHint,
        'RTK 尚未 fixed，機器人會拒絕開始記錄（尚未收到 GPS /fix）',
      );

      // _emitLivePrerequisites' fix is status 0: RTK float or a plain fix.
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.rtkNotFixedReason, 'GPS status=0，RTK float 或一般定位');
      ros.emit('/fix', _fixWithStatus(-1));
      expect(provider.rtkNotFixedReason, 'GPS 無定位');
      // A status the phone cannot read never counts as fixed.
      ros.emit('/fix', {'latitude': 25.0});
      expect(provider.rtkNotFixedReason, 'GPS 無定位');
      ros.emit('/fix', _fixWithStatus(2));
      expect(provider.rtkNotFixedReason, isNull);
      expect(provider.recordStartRtkHint, isNull);

      // Live zone recording: no warning while fixed.
      ros.handlers['/record_zone_start'] = () =>
          _response('/record_zone_start', success: true);
      expect(await provider.startRecording(RecordObjectType.zone), isNull);
      expect(provider.recordingRtkWarning, isNull);

      // Fixed lost: the warning shows, and listeners hear of it at once.
      var notified = 0;
      provider.addListener(() => notified++);
      ros.emit('/fix', _fixWithStatus(0));
      expect(notified, greaterThan(0));
      expect(provider.recordingRtkWarning, 'RTK 未 fixed，暫停取點（邊界會以直線連接）');
      expect(provider.recordStartRtkHint, isNull, reason: 'already recording');

      // Fixed again: cleared.
      ros.emit('/fix', _fixWithStatus(2));
      expect(provider.recordingRtkWarning, isNull);

      // /fix stops arriving: after the phone's 2 s it counts as not fixed.
      await Future<void>.delayed(const Duration(milliseconds: 2100));
      expect(provider.rtkNotFixedReason, '超過 2 秒沒有收到 GPS /fix');
      expect(provider.recordingRtkWarning, isNotNull);

      // rosbridge down: unknown, so no claim either way.
      ros.emitState(RosbridgeConnectionState.disconnected);
      expect(provider.recordingRtkWarning, isNull);

      provider.dispose();
      await ros.close();
    },
  );

  test('a channel recording warns that its path is joined', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.handlers['/channel_record_start'] = () =>
        _response('/channel_record_start', success: true);
    expect(await provider.startRecording(RecordObjectType.channel), isNull);
    expect(provider.recordingRtkWarning, 'RTK 未 fixed，暫停取點（路徑會以直線連接）');

    provider.dispose();
    await ros.close();
  });

  test('demo mode never claims RTK is missing', () async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    expect(provider.mockDataEnabled, isTrue);
    ros.emitState(RosbridgeConnectionState.connected);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    expect(provider.rtkNotFixedReason, isNull);
    expect(provider.recordStartRtkHint, isNull);
    expect(provider.recordingRtkWarning, isNull);

    provider.dispose();
    await ros.close();
  });

  test('recording and hand-drawing exclude each other', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);

    // Drawing first: recording is refused with a reason and nothing is sent.
    expect(provider.startDrawRisk(), isNull);
    expect(provider.drawMode, isTrue);
    expect(
      await provider.startRecording(RecordObjectType.zone),
      contains('繪製'),
    );
    expect(ros.callCount['/record_zone_start'], isNull);
    provider.cancelDraw();

    // Recording first: drawing is refused and draw mode never turns on.
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    expect(provider.startDrawRisk(), isNotNull);
    expect(provider.drawMode, isFalse);

    provider.dispose();
    await ros.close();
  });

  testWidgets('live: add-object sheet warns of no RTK fixed, shows the '
      'robot\'s refusal', (tester) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    await tester.pumpWidget(_sheetHost(provider, onRecordingStarted: () {}));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // A status 0 fix: the hint is there before any tap.
    _emitLivePrerequisites(ros);
    await tester.pump();
    expect(
      find.text('RTK 尚未 fixed，機器人會拒絕開始記錄（GPS status=0，RTK float 或一般定位）'),
      findsOneWidget,
    );

    // The start stays enabled; the robot answers and its reason is shown.
    const rtk = 'RTK 尚未 fixed，無法開始 zone 記錄（GPS status=0，RTK fixed 為 2）';
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: false, message: rtk);
    await tester.tap(find.text('工作區'));
    await tester.pumpAndSettle();
    expect(ros.callCount['/record_zone_start'], 1);
    expect(find.text(rtk), findsOneWidget);
    expect(find.text('新增地圖物件'), findsOneWidget);
    expect(provider.recordingType, isNull);

    // RTK fixed arrives: the hint goes.
    ros.emit('/fix', _fixWithStatus(2));
    await tester.pump();
    expect(find.byKey(const ValueKey('record-start-rtk-hint')), findsNothing);

    await _endWidgetTest(tester, provider, ros);
  });

  testWidgets('live: the recording bar warns while RTK is not fixed', (
    tester,
  ) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    _emitLivePrerequisites(ros);
    await tester.pump();
    await tester.pump();
    ros.emit('/fix', _fixWithStatus(2));
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);

    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MapRecordBar(onOpenManual: () {})),
        ),
      ),
    );
    const warning = 'RTK 未 fixed，暫停取點（邊界會以直線連接）';
    expect(find.text(warning), findsNothing);

    ros.emit('/fix', _fixWithStatus(0));
    await tester.pump();
    expect(find.text(warning), findsOneWidget);
    expect(find.text('GPS status=0，RTK float 或一般定位'), findsOneWidget);
    // The recording itself goes on: its bar and buttons stay.
    expect(find.textContaining('工作區記錄中'), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);

    ros.emit('/fix', _fixWithStatus(-1));
    await tester.pump();
    expect(find.text(warning), findsOneWidget);
    expect(find.text('GPS 無定位'), findsOneWidget);

    ros.emit('/fix', _fixWithStatus(2));
    await tester.pump();
    expect(find.text(warning), findsNothing);
    expect(find.byKey(const ValueKey('record-rtk-pause')), findsNothing);

    await _endWidgetTest(tester, provider, ros);
  });

  // mower_record refuses to save a recording with an RTK pause over 10 s
  // (max_rtk_pause_s; owner, 2026-11-07) and discards it.
  const rtkPaused = 'RTK 未 fixed，暫停取點（邊界會以直線連接）';
  const rtkNotSaved = 'RTK 已中斷超過 10 秒，這次記錄將無法儲存，請重新記錄';
  const rtkWasNotSaved = 'RTK 曾中斷超過 10 秒，這次記錄將無法儲存，請重新記錄';
  const robotDiscarded = '錄製中 RTK 中斷 23.4 秒（超過 10 秒），邊界可能不準，未儲存，請重新記錄';

  test('a pause over 10 s says the recording will not be saved', () async {
    var now = DateTime(2026, 11, 7, 9);
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros, clock: () => now);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.emit('/fix', _fixWithStatus(2));
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    expect(provider.recordingLongestRtkPause, Duration.zero);

    // The pause runs from the first /fix that is not RTK fixed; 10 s is not
    // over the robot's limit, a moment more is.
    ros.emit('/fix', _fixWithStatus(0));
    expect(provider.recordingRtkWarning, rtkPaused);
    now = now.add(const Duration(seconds: 10));
    ros.emit('/fix', _fixWithStatus(0));
    expect(provider.recordingLongestRtkPause, const Duration(seconds: 10));
    expect(provider.recordingRtkWarning, rtkPaused);
    now = now.add(const Duration(milliseconds: 100));
    expect(provider.recordingRtkWarning, rtkNotSaved);

    // RTK fixed again: the robot will still not save this one, so the
    // notice stays; a new outage says it is going on.
    ros.emit('/fix', _fixWithStatus(2));
    expect(provider.rtkNotFixedReason, isNull);
    expect(provider.recordingRtkWarning, rtkWasNotSaved);
    now = now.add(const Duration(minutes: 1));
    expect(
      provider.recordingLongestRtkPause,
      const Duration(seconds: 10, milliseconds: 100),
    );
    ros.emit('/fix', _fixWithStatus(-1));
    expect(provider.recordingRtkWarning, rtkNotSaved);

    // Cancelled: the next recording starts with none of it.
    ros.emit('/fix', _fixWithStatus(2));
    expect(await provider.stopRecording(save: false), isTrue);
    expect(provider.recordingRtkWarning, isNull);
    expect(await provider.startRecording(RecordObjectType.risk), isNull);
    expect(provider.recordingLongestRtkPause, Duration.zero);
    expect(provider.recordingRtkWarning, isNull);

    provider.dispose();
    await ros.close();
  });

  test('short RTK pauses are not added up', () async {
    var now = DateTime(2026, 11, 7, 9);
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros, clock: () => now);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.emit('/fix', _fixWithStatus(2));
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);

    // 9 s, 9 s and 9 s going on: 27 s in all, none over 10 s.
    for (var i = 0; i < 3; i++) {
      ros.emit('/fix', _fixWithStatus(0));
      now = now.add(const Duration(seconds: 9));
      ros.emit('/fix', _fixWithStatus(i < 2 ? 2 : 0));
      if (i < 2) {
        expect(provider.recordingRtkWarning, isNull);
      }
    }
    expect(provider.recordingLongestRtkPause, const Duration(seconds: 9));
    expect(provider.recordingRtkWarning, rtkPaused);

    provider.dispose();
    await ros.close();
  });

  test('an RTK pause is never timed across a rosbridge gap', () async {
    var now = DateTime(2026, 11, 7, 9);
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros, clock: () => now);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.emit('/fix', _fixWithStatus(2));
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);

    ros.emit('/fix', _fixWithStatus(0));
    now = now.add(const Duration(seconds: 5));
    ros.emitState(RosbridgeConnectionState.disconnected);
    expect(provider.recordingRtkWarning, isNull);
    // 30 s the phone saw nothing of: not counted.
    now = now.add(const Duration(seconds: 30));
    ros.emitState(RosbridgeConnectionState.connected);
    now = now.add(const Duration(seconds: 3));
    expect(provider.recordingType, RecordObjectType.zone);
    expect(provider.recordingLongestRtkPause, const Duration(seconds: 5));
    expect(provider.recordingRtkWarning, rtkPaused);
    ros.emit('/fix', _fixWithStatus(2));
    expect(provider.recordingRtkWarning, isNull);
    expect(provider.recordingLongestRtkPause, const Duration(seconds: 5));

    provider.dispose();
    await ros.close();
  });

  test('a refused end follows what the robot did with the recording', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);

    // Refused, the recording kept (too few points): still recording, and
    // the robot's reason is there for the user.
    const tooFew = '區域點數不足，至少需要 3 個點';
    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: false, message: tooFew);
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.recordingType, RecordObjectType.zone);
    expect(provider.recordEndRefusal, tooFew);
    expect(provider.recordEndDiscarded, isFalse);

    // Refused and discarded (an RTK pause too long): the robot records
    // nothing now, so neither does the app; nothing to save or retry.
    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: false, message: robotDiscarded);
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.recordingType, isNull);
    expect(provider.recordCommandPending, isFalse);
    expect(provider.hasPendingRecordSave, isFalse);
    expect(provider.recordEndRefusal, robotDiscarded);
    expect(provider.recordEndDiscarded, isTrue);
    expect(provider.recordingRtkWarning, isNull);
    expect(ros.callCount['/save_zone_list'], isNull);
    expect(ros.callCount['/record_cancel'], isNull);
    expect(
      provider.logs.where(
        (e) => e.level == 'ERROR' && e.message == robotDiscarded,
      ),
      hasLength(1),
    );

    // A new one starts at once. A channel's answer, with the lease warning
    // the robot appends when the release is unconfirmed, is read the same.
    ros.handlers['/channel_record_start'] = () =>
        _response('/channel_record_start', success: true);
    expect(await provider.startRecording(RecordObjectType.channel), isNull);
    const channel =
        '錄製中 RTK 中斷 12.0 秒（超過 10 秒），路徑可能不準，未儲存，請重新記錄'
        '；操作鎖釋放未確認，導航仍被禁止；請檢查機器後重啟 path_record_node 與 nav_action_server';
    ros.handlers['/channel_record_end'] = () =>
        _response('/channel_record_end', success: false, message: channel);
    expect(await provider.stopRecording(save: true), isFalse);
    expect(provider.recordingType, isNull);
    expect(provider.recordEndDiscarded, isTrue);

    // A cancel never reports an end's refusal.
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    ros.handlers['/record_cancel'] = () =>
        _response('/record_cancel', success: false, message: 'busy');
    expect(await provider.stopRecording(save: false), isFalse);
    expect(provider.recordEndRefusal, isNull);
    expect(provider.recordEndDiscarded, isFalse);

    provider.dispose();
    await ros.close();
  });

  testWidgets('live: a refused save shows the robot\'s reason', (tester) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    _emitLivePrerequisites(ros);
    await tester.pump();
    await tester.pump();
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MapRecordBar(onOpenManual: () {})),
        ),
      ),
    );

    // Kept: the reason, and the bar stays for another try or a cancel.
    const tooFew = '區域點數不足，至少需要 3 個點';
    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: false, message: tooFew);
    await tester.tap(find.text('儲存'));
    await tester.pump();
    await tester.pump();
    expect(find.text('儲存沒有成功，記錄仍在進行：$tooFew'), findsOneWidget);
    expect(find.textContaining('工作區記錄中'), findsOneWidget);
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();

    // Discarded: the robot's own words, and no recording bar left.
    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: false, message: robotDiscarded);
    await tester.tap(find.text('儲存'));
    await tester.pump();
    await tester.pump();
    expect(find.text(robotDiscarded), findsOneWidget);
    expect(find.textContaining('記錄仍在進行'), findsNothing);
    expect(find.textContaining('工作區記錄中'), findsNothing);
    expect(find.text('儲存'), findsNothing);
    expect(find.text('取消'), findsNothing);
    // Up long enough to read: still there after the usual 4 s.
    await tester.pump(const Duration(seconds: 5));
    expect(find.text(robotDiscarded), findsOneWidget);

    await _endWidgetTest(tester, provider, ros);
  });

  testWidgets('live: the recording bar says when a recording cannot be saved', (
    tester,
  ) async {
    var now = DateTime(2026, 11, 7, 9);
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros, clock: () => now);
    await tester.runAsync(_flushEvents);
    _emitLivePrerequisites(ros);
    await tester.pump();
    await tester.pump();
    ros.emit('/fix', _fixWithStatus(2));
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MapRecordBar(onOpenManual: () {})),
        ),
      ),
    );

    ros.emit('/fix', _fixWithStatus(0));
    await tester.pump();
    expect(find.text(rtkPaused), findsOneWidget);
    // 11 s on, with no new /fix status: the bar's own tick redraws it.
    now = now.add(const Duration(seconds: 11));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text(rtkPaused), findsNothing);
    expect(find.text(rtkNotSaved), findsOneWidget);
    expect(find.text('GPS status=0，RTK float 或一般定位'), findsOneWidget);

    // Fixed again: the notice stays, without a reason line; save and
    // cancel stay too (the robot decides).
    ros.emit('/fix', _fixWithStatus(2));
    await tester.pump();
    expect(find.text(rtkWasNotSaved), findsOneWidget);
    expect(find.text('GPS status=0，RTK float 或一般定位'), findsNothing);
    expect(find.byKey(const ValueKey('record-rtk-pause')), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await _endWidgetTest(tester, provider, ros);
  });

  testWidgets('live: add-object sheet hands off once the robot accepts', (
    tester,
  ) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    var handedOff = 0;
    await tester.pumpWidget(
      _sheetHost(provider, onRecordingStarted: () => handedOff++),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Fresh robot state right before the tap: readiness gates are 200 ms wide.
    _emitLivePrerequisites(ros);
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    await tester.tap(find.text('工作區'));
    await tester.pumpAndSettle();

    expect(provider.recordingType, RecordObjectType.zone);
    expect(handedOff, 1);
    expect(find.text('新增地圖物件'), findsNothing);

    await _endWidgetTest(tester, provider, ros);
  });

  testWidgets('live: dismissing the sheet mid-request never pops the page', (
    tester,
  ) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    var handedOff = 0;
    await tester.pumpWidget(
      _sheetHost(provider, onRecordingStarted: () => handedOff++),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    _emitLivePrerequisites(ros);
    final response = Completer<RosbridgeServiceResponse>();
    ros.handlers['/record_zone_start'] = () => response.future;
    await tester.tap(find.text('工作區'));
    await tester.pump();
    expect(provider.recordCommandPending, isTrue);

    // Dismiss via the barrier; the robot answers during the exit animation.
    await tester.tapAt(const Offset(10, 10));
    await tester.pump(const Duration(milliseconds: 60));
    response.complete(_response('/record_zone_start', success: true));
    await tester.pump();
    await tester.pumpAndSettle();

    // The page underneath is intact and the user was not yanked anywhere.
    expect(find.text('open'), findsOneWidget);
    expect(handedOff, 0);
    // The recording did start and is now controllable from the map.
    expect(provider.recordingType, RecordObjectType.zone);

    await _endWidgetTest(tester, provider, ros);
  });

  testWidgets('live: failed save is reported as stopped-unsaved, not running', (
    tester,
  ) async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await tester.runAsync(_flushEvents);
    _emitLivePrerequisites(ros);
    // Let the provider's navigation-status poll answer before starting.
    await tester.pump();
    await tester.pump();
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    expect(await provider.startRecording(RecordObjectType.zone), isNull);

    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MapRecordBar(onOpenManual: () {})),
        ),
      ),
    );
    expect(find.text('儲存'), findsOneWidget);

    ros.handlers['/record_zone_end'] = () =>
        _response('/record_zone_end', success: true);
    ros.handlers['/save_zone_list'] = () =>
        _response('/save_zone_list', success: false, message: 'disk');
    await tester.tap(find.text('儲存'));
    await tester.pump();
    await tester.pump();

    // The recorder stopped; only persisting failed. Say so, offer retry.
    expect(provider.hasPendingRecordSave, isTrue);
    expect(find.textContaining('記錄已停止，但儲存失敗'), findsOneWidget);
    expect(find.textContaining('記錄仍在進行'), findsNothing);
    expect(find.textContaining('已停止，但尚未儲存'), findsOneWidget);

    // A failed retry is reported too (clear the first snackbar so the next
    // one is not queued behind it).
    tester
        .state<ScaffoldMessengerState>(find.byType(ScaffoldMessenger))
        .clearSnackBars();
    await tester.pumpAndSettle();
    await tester.tap(find.text('重試'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('重試儲存沒有成功'), findsOneWidget);

    await _endWidgetTest(tester, provider, ros);
  });

  test('external navigation stops active manual velocity', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();

    expect(provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0), isTrue);
    expect(provider.manualControlActive, isTrue);
    ros.handlers['/check_nav_status'] = () => _response(
      '/check_nav_status',
      success: true,
      message: jsonEncode({
        'state': 'running',
        'task': 'external mission',
        'message': 'Navigation running',
      }),
    );

    await Future<void>.delayed(const Duration(milliseconds: 1100));
    expect(provider.navStatus, NavMockStatus.executing);
    expect(provider.manualControlActive, isFalse);
    final lastTwist = ros.published.last.message['twist'] as Map;
    expect((lastTwist['linear'] as Map)['x'], 0.0);
    expect((lastTwist['angular'] as Map)['z'], 0.0);

    provider.dispose();
    await ros.close();
  });

  test('manual motion requires a fresh robot command clock', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros, includeManualClock: false);
    await _flushEvents();

    expect(provider.canControlRobot, isTrue);
    expect(provider.hasFreshTerminalNavStatus, isTrue);
    expect(provider.canDriveManually, isFalse);
    expect(
      provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0),
      isFalse,
    );
    expect(ros.published, isEmpty);

    provider.dispose();
    await ros.close();
  });

  test('manual session rollover requires neutral before re-arming', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    expect(provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0), isTrue);

    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 124, 'nanosec': 1},
      'frame_id': 'manual-session-v1:replacement',
    });
    expect(provider.manualControlActive, isFalse);
    expect(provider.canDriveManually, isFalse);

    provider.stopManualControl();
    expect(provider.canDriveManually, isTrue);
    expect(
      ros.published.last.message['header']['frame_id'],
      'manual-session-v1:replacement',
    );
    final stoppedTwist = ros.published.last.message['twist'] as Map;
    expect((stoppedTwist['linear'] as Map)['x'], 0.0);

    provider.dispose();
    await ros.close();
  });

  test(
    'manual command clock replay cannot refresh or roll back authority',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.canDriveManually, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 600));
      ros.emit('/manual_command_clock', {
        'stamp': {'sec': 123, 'nanosec': 456},
        'frame_id': 'manual-session-v1:test-session',
      });
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(provider.canDriveManually, isFalse);

      ros.emit('/manual_command_clock', {
        'stamp': {'sec': 124, 'nanosec': 1},
        'frame_id': 'manual-session-v1:test-session',
      });
      ros.emit('/manual_command_clock', {
        'stamp': {'sec': 123, 'nanosec': 999999999},
        'frame_id': 'manual-session-v1:test-session',
      });
      expect(provider.canDriveManually, isTrue);
      expect(
        provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0),
        isTrue,
      );
      expect(ros.published.last.message['header']['stamp'], {
        'sec': 124,
        'nanosec': 1,
      });

      provider.dispose();
      await ros.close();
    },
  );

  test('map datum rejects fallback and preserves trusted source', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();

    final fallback = {
      'data': jsonEncode({
        'origin_lat': 25.0,
        'origin_lon': 121.0,
        'bearing_rad': 0.0,
        'source': 'fallback',
      }),
    };
    ros.emit('/adapter/map_datum', fallback);
    ros.emit('/adapter/map_datum', fallback);
    expect(provider.mapGeoAnchor, isNull);
    expect(
      provider.logs
          .where((entry) => entry.message.contains('source=fallback'))
          .length,
      1,
    );

    ros.emit('/adapter/map_datum', {
      'data': jsonEncode({
        'origin_lat': 25.033,
        'origin_lon': 121.5654,
        'bearing_rad': 0.1,
        'source': 'navsat',
      }),
    });
    expect(provider.mapGeoAnchor?.source, 'navsat');

    provider.dispose();
    await ros.close();
  });

  test('base station: the robot fix minus relpos, on the map', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    ros.emitState(RosbridgeConnectionState.connected);
    // datum at the rover, map +X north (so +Y is west)
    ros.emit('/adapter/map_datum', {
      'data': jsonEncode({
        'origin_lat': 25.033,
        'origin_lon': 121.5654,
        'bearing_rad': 0.0,
        'source': 'navsat',
      }),
    });
    final status = {
      'data': jsonEncode({
        'fix_type': 3,
        'carrier_solution': 'fixed',
        'relpos': {
          'ref_station_id': 0,
          'valid': true,
          'carrier_solution': 'fixed',
          'n_m': 12.0,
          'e_m': -4.0,
          'acc_n_m': 0.012,
          'acc_e_m': 0.011,
          'is_moving': false,
          'ref_pos_miss': false,
          'ref_obs_miss': false,
        },
      }),
    };

    // no /fix to pair it with yet
    ros.emit('/gps/status', status);
    expect(provider.baseStationPosition, isNull);

    for (var i = 0; i < 3; i++) {
      ros.emit('/fix', _rtkFix(25.033, 121.5654));
      ros.emit('/gps/status', status);
    }
    final base = provider.baseStationPosition!;
    // 12 m south and 4 m west of the rover; GeoAnchor's flat-earth metres
    // are within 0.5 % of the ellipsoid's
    expect(base.x, closeTo(-12.0, 0.08));
    expect(base.y, closeTo(-4.0, 0.03));

    // an RTK dropout leaves the dock where it was
    ros.emit('/fix', {
      ..._rtkFix(25.033, 121.5654),
      'status': {'status': -1},
    });
    ros.emit('/gps/status', status);
    expect(provider.baseStationPosition!.x, base.x);

    // another robot: its own base
    expect(await provider.updateRobotIp('10.0.0.2'), isNull);
    expect(provider.baseStationPosition, isNull);

    provider.dispose();
    await ros.close();
  });

  test('demo mode shows a demo base station', () async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    expect(provider.mockDataEnabled, isTrue);
    expect(provider.baseStationPosition, isNotNull);

    provider.dispose();
    await ros.close();
  });

  test(
    'GPS requires nonzero coordinates and known precise covariance',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.hasFreshGpsFix, isTrue);
      expect(provider.gpsHorizontalSigmaM, closeTo(0.01, 0.001));

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 801000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 2,
        'position_covariance': List<double>.filled(9, 0.0),
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 802000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 0,
        'position_covariance': List<double>.filled(9, 0.04),
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 803000000},
        },
        'status': {'status': 0},
        'latitude': 0.0,
        'longitude': 0.0,
        'position_covariance_type': 2,
        'position_covariance': List<double>.filled(9, 0.04),
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 804000000},
        },
        'status': {'status': 99},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 2,
        'position_covariance': List<double>.filled(9, 0.04),
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 805000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 99,
        'position_covariance': List<double>.filled(9, 0.04),
      });
      expect(provider.hasFreshGpsFix, isFalse);

      // Each diagonal sigma is 0.012 m, but correlation raises the major-axis
      // sigma above the 0.015 m production gate.
      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 806000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 3,
        'position_covariance': [
          0.000144,
          0.0001,
          0.0,
          0.0001,
          0.000144,
          0.0,
          0.0,
          0.0,
          0.0004,
        ],
      });
      expect(provider.hasFreshGpsFix, isFalse);

      // A non-positive-semidefinite horizontal covariance is malformed.
      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 807000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 3,
        'position_covariance': [
          0.04,
          0.05,
          0.0,
          0.05,
          0.04,
          0.0,
          0.0,
          0.0,
          0.09,
        ],
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 808000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 3,
        'position_covariance': [
          0.04,
          double.infinity,
          0.0,
          double.infinity,
          0.04,
          0.0,
          0.0,
          0.0,
          0.09,
        ],
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 809000000},
        },
        'status': {'status': 0},
        'latitude': 25.033,
        'longitude': 121.5654,
        'position_covariance_type': 3,
        'position_covariance': [
          0.04,
          0.01,
          0.0,
          0.02,
          0.04,
          0.0,
          0.0,
          0.0,
          0.09,
        ],
      });
      expect(provider.hasFreshGpsFix, isFalse);

      provider.dispose();
      await ros.close();
    },
  );

  test('GPS readiness requires fresh increasing robot source stamps', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    expect(provider.hasFreshGpsFix, isTrue);

    final preciseFix = {
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
    };

    ros.emit('/fix', preciseFix);
    expect(provider.hasFreshGpsFix, isFalse);

    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 124, 'nanosec': 0},
      'frame_id': 'manual-session-v1:test-session',
    });
    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 123, 'nanosec': 500000000},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isFalse);

    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 123, 'nanosec': 400000000},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isFalse);

    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 123, 'nanosec': 800000000},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isTrue);

    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 9999, 'nanosec': 0},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isFalse);
    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 125, 'nanosec': 0},
      'frame_id': 'manual-session-v1:test-session',
    });
    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 124, 'nanosec': 800000000},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isTrue);

    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 10, 'nanosec': 0},
      'frame_id': 'manual-session-v1:new-clock-domain',
    });
    expect(provider.hasFreshGpsFix, isFalse);
    ros.emit('/fix', {
      'header': {
        'stamp': {'sec': 9, 'nanosec': 800000000},
      },
      ...preciseFix,
    });
    expect(provider.hasFreshGpsFix, isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 170));
    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 10, 'nanosec': 50000000},
      'frame_id': 'manual-session-v1:new-clock-domain',
    });
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(provider.hasFreshGpsFix, isFalse);

    provider.dispose();
    await ros.close();
  });

  test(
    'same-clock-domain guard restart retains the GPS replay barrier',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.hasFreshGpsFix, isTrue);

      final preciseFix = {
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
      };
      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 900000000},
        },
        ...preciseFix,
        'status': {'status': -1},
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/manual_command_clock', {
        'stamp': {'sec': 123, 'nanosec': 50000000},
        'frame_id': 'manual-session-v1:restarted-same-clock',
      });
      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 850000000},
        },
        ...preciseFix,
      });
      expect(provider.hasFreshGpsFix, isFalse);

      ros.emit('/fix', {
        'header': {
          'stamp': {'sec': 122, 'nanosec': 950000000},
        },
        ...preciseFix,
      });
      expect(provider.hasFreshGpsFix, isTrue);

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'unknown nav response invalidates freshness and uncertain stays cancelable',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.hasFreshNavStatusSnapshot, isTrue);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({'state': 'mystery', 'message': 'bad state'}),
      );
      await _triggerNavPoll(ros);
      expect(provider.hasFreshNavStatusSnapshot, isFalse);
      expect(provider.canDriveManually, isFalse);
      expect(provider.canStartMission, isFalse);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'uncertain',
          'task': 'zone 7',
          'message': 'goal acceptance unknown',
        }),
      );
      await _triggerNavPoll(ros);
      expect(provider.navStatus, NavMockStatus.paused);
      expect(provider.cancelPending, isFalse);
      expect(provider.canMutatePlanning, isFalse);

      ros.handlers['/cancel_nav2'] = () =>
          _response('/cancel_nav2', success: true);
      provider.cancelExecution();
      await _flushEvents();
      expect(ros.callCount['/cancel_nav2'], 1);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'failed',
          'message': 'terminal failure',
          'ready': true,
          'block_reason': null,
        }),
      );
      await _triggerNavPoll(ros);
      expect(provider.navStatus, NavMockStatus.failed);
      expect(provider.hasFreshTerminalNavStatus, isTrue);
      expect(provider.canStartMission, isTrue);

      provider.dispose();
      await ros.close();
    },
  );

  test(
    'malformed or incomplete nav JSON never falls back to terminal text',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      expect(provider.hasFreshTerminalNavStatus, isTrue);
      expect(
        provider.publishManualVelocity(linearX: 0.2, angularZ: 0.0),
        isTrue,
      );
      expect(provider.manualControlActive, isTrue);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: '{"state":"idle"',
      );
      await _triggerNavPoll(ros);
      expect(provider.hasFreshNavStatusSnapshot, isFalse);
      expect(provider.canDriveManually, isFalse);
      expect(provider.canStartMission, isFalse);
      expect(provider.manualControlActive, isFalse);
      final stoppedTwist = ros.published.last.message['twist'] as Map;
      expect((stoppedTwist['linear'] as Map)['x'], 0.0);
      expect((stoppedTwist['angular'] as Map)['z'], 0.0);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({'message': 'Navigation idle'}),
      );
      await _triggerNavPoll(ros);
      expect(provider.hasFreshNavStatusSnapshot, isFalse);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: 'Navigation is not idle',
      );
      await _triggerNavPoll(ros);
      expect(provider.hasFreshNavStatusSnapshot, isFalse);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: 'Navigation idle',
      );
      await _triggerNavPoll(ros);
      expect(provider.hasFreshTerminalNavStatus, isTrue);

      provider.dispose();
      await ros.close();
    },
  );

  test('active navigation blocks every planning mutation entry', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    provider.startExecution();
    await _flushEvents();
    expect(provider.navStatus, NavMockStatus.executing);

    final previousWidth = provider.stripWidthM;
    provider.setStripWidth(previousWidth + 0.1);
    provider.runPlanningStep('coverage');
    await provider.deleteObject('zone', 7);

    expect(provider.stripWidthM, previousWidth);
    expect(ros.callCount['/boustrophedon_coverage/set_parameters'], isNull);
    expect(ros.callCount['/generate_coverage_path'], isNull);
    expect(ros.callCount['/edit_zone'], isNull);

    provider.dispose();
    await ros.close();
  });

  test('external navigation cancels an active path recording', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.handlers['/record_zone_start'] = () =>
        _response('/record_zone_start', success: true);
    provider.startRecording(RecordObjectType.zone);
    await _flushEvents();
    expect(provider.recordingType, RecordObjectType.zone);

    ros.handlers['/check_nav_status'] = () => _response(
      '/check_nav_status',
      success: true,
      message: jsonEncode({
        'state': 'running',
        'task': 'external',
        'message': 'running',
      }),
    );
    ros.handlers['/record_cancel'] = () =>
        _response('/record_cancel', success: true);
    await _triggerNavPoll(ros);
    await _flushEvents();

    expect(provider.navStatus, NavMockStatus.executing);
    expect(ros.callCount['/record_cancel'], 1);
    expect(provider.recordingType, isNull);

    provider.dispose();
    await ros.close();
  });

  test('rejected ROS parameter result is not treated as an ACK', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    ros.handlers['/boustrophedon_coverage/set_parameters'] = () =>
        const RosbridgeServiceResponse(
          service: '/boustrophedon_coverage/set_parameters',
          result: true,
          values: {
            'results': [
              {'successful': false, 'reason': 'unsafe width'},
            ],
          },
        );

    final previousWidth = provider.stripWidthM;
    provider.setStripWidth(1.1);
    await _flushEvents();
    expect(provider.planningMutationPending, isFalse);
    expect(provider.stripWidthM, previousWidth);
    expect(provider.coverageReady, isFalse);
    expect(
      provider.logs.any((entry) => entry.message.contains('unsafe width')),
      isTrue,
    );

    // SetParameters has no top-level values.success. Its envelope result and
    // every SetParametersResult entry remain the authoritative ACK contract.
    ros.handlers['/boustrophedon_coverage/set_parameters'] = () =>
        const RosbridgeServiceResponse(
          service: '/boustrophedon_coverage/set_parameters',
          result: true,
          values: {
            'results': [
              {'successful': true, 'reason': ''},
            ],
          },
        );
    provider.setStripWidth(1.1);
    await _flushEvents();
    expect(provider.stripWidthM, 1.1);
    expect(provider.planningMutationPending, isFalse);

    provider.dispose();
    await ros.close();
  });

  test('negative start ACK cannot overwrite a newer running status', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();
    final startResponse = Completer<RosbridgeServiceResponse>();
    ros.handlers['/zone_exec_path'] = () => startResponse.future;
    provider.startExecution();
    await _flushEvents();

    ros.handlers['/check_nav_status'] = () => _response(
      '/check_nav_status',
      success: true,
      message: jsonEncode({'state': 'running', 'message': 'goal running'}),
    );
    await _triggerNavPoll(ros);
    expect(provider.navStatus, NavMockStatus.executing);

    startResponse.complete(
      _response('/zone_exec_path', success: false, message: 'timeout'),
    );
    await _flushEvents();
    expect(provider.navStatus, NavMockStatus.executing);
    expect(provider.canDriveManually, isFalse);

    provider.dispose();
    await ros.close();
  });

  test('status response from before start cannot restore idle', () async {
    final ros = _FakeRosbridgeService();
    final provider = MissionMockProvider(rosbridge: ros);
    await _flushEvents();
    _emitLivePrerequisites(ros);
    await _flushEvents();

    final staleStatus = Completer<RosbridgeServiceResponse>();
    ros.handlers['/check_nav_status'] = () => staleStatus.future;
    await _triggerNavPoll(ros);
    ros.handlers['/zone_exec_path'] = () =>
        _response('/zone_exec_path', success: true);

    provider.startExecution();
    await _flushEvents();
    expect(provider.navStatus, NavMockStatus.executing);

    staleStatus.complete(
      _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'idle',
          'message': 'stale idle',
          'ready': true,
          'block_reason': null,
        }),
      ),
    );
    await _flushEvents();

    expect(provider.navStatus, NavMockStatus.executing);
    expect(provider.canDriveManually, isFalse);

    provider.dispose();
    await ros.close();
  });

  test(
    'cancel is immediate during pending start and late ACK cannot resume it',
    () async {
      final ros = _FakeRosbridgeService();
      final provider = MissionMockProvider(rosbridge: ros);
      await _flushEvents();
      _emitLivePrerequisites(ros);
      await _flushEvents();
      final startResponse = Completer<RosbridgeServiceResponse>();
      final cancelResponse = Completer<RosbridgeServiceResponse>();
      ros.handlers['/zone_exec_path'] = () => startResponse.future;
      ros.handlers['/cancel_nav2'] = () => cancelResponse.future;

      provider.startExecution();
      await _flushEvents();
      expect(provider.navCommandPending, isTrue);

      provider.cancelExecution();
      await _flushEvents();
      expect(ros.callCount['/cancel_nav2'], 1);
      expect(provider.cancelRequestInFlight, isTrue);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'uncertain',
          'message': 'start/cancel overlap is not terminal',
          'ready': false,
          'block_reason': 'navigation outcome is uncertain',
        }),
      );
      startResponse.complete(_response('/zone_exec_path', success: true));
      await _flushEvents();
      expect(provider.navStatus, NavMockStatus.paused);
      expect(provider.canDriveManually, isFalse);

      ros.handlers['/check_nav_status'] = () => _response(
        '/check_nav_status',
        success: true,
        message: jsonEncode({
          'state': 'canceled',
          'message': 'terminal cancel',
          'ready': true,
          'block_reason': null,
        }),
      );
      cancelResponse.complete(_response('/cancel_nav2', success: true));
      await _flushEvents();
      expect(provider.navStatus, NavMockStatus.idle);
      expect(provider.cancelPending, isFalse);

      provider.dispose();
      await ros.close();
    },
  );
}

Future<void> _triggerNavPoll(_FakeRosbridgeService ros) async {
  ros.emit('/robot/online', {'data': false});
  ros.emit('/robot/online', {'data': true});
  await _flushEvents();
}

/// Zones 7 (0..4 m) and 8 (10..14 m), both planned, and unless [channel] is
/// false a channel from inside zone 7 to inside zone 8.
void _emitTwoZones(_FakeRosbridgeService ros, {bool channel = true}) {
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
      ],
    }),
  });
  ros.emit('/adapter/zone_summaries', {
    'data': jsonEncode([
      {'zoneId': 7, 'hasCoveragePath': true},
      {'zoneId': 8, 'hasCoveragePath': true},
    ]),
  });
  ros.emit('/adapter/marker_layers/channels', {
    'data': jsonEncode({
      'name': 'channels',
      'markers': [
        if (channel)
          {
            'id': 1,
            'points': [
              {'x': 3.5, 'y': 2.0},
              {'x': 7.0, 'y': 2.0},
              {'x': 10.5, 'y': 2.0},
            ],
          },
      ],
    }),
  });
}

Map<String, dynamic> _sequenceStatus(String state, int index, String leg) => {
  'data': jsonEncode({
    'state': state,
    'zone_ids': [7, 8],
    'index': index,
    'leg': leg,
    'zone_id': leg.isEmpty ? null : [7, 8][index],
    'next_zone_id': leg == 'channel' ? 8 : null,
    'message': '$state $leg',
  }),
};

RosbridgeServiceResponse _navState(String state) => _response(
  '/check_nav_status',
  success: true,
  message: jsonEncode({
    'state': state,
    'task': null,
    'message': 'Navigation $state',
    'ready': true,
    'block_reason': null,
  }),
);

void _emitLivePrerequisites(
  _FakeRosbridgeService ros, {
  bool includeManualClock = true,
}) {
  ros.emitState(RosbridgeConnectionState.connected);
  ros.emit('/robot/online', {'data': true});
  if (includeManualClock) {
    ros.emit('/manual_command_clock', {
      'stamp': {'sec': 123, 'nanosec': 456},
      'frame_id': 'manual-session-v1:test-session',
    });
  }
  ros.emit('/adapter/robot_pose', {
    'pose': {
      'position': {'x': 1.0, 'y': 2.0, 'z': 0.0},
      'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
    },
  });
  ros.emit('/fix', {
    'header': {
      'stamp': {'sec': 122, 'nanosec': 800000000},
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
  ros.emit('/adapter/marker_layers/zones', {
    'data': jsonEncode({
      'name': 'zones',
      'markers': [
        {
          'id': 7,
          'points': [
            {'x': 0.0, 'y': 0.0},
            {'x': 4.0, 'y': 0.0},
            {'x': 4.0, 'y': 4.0},
          ],
        },
      ],
    }),
  });
  ros.emit('/adapter/zone_summaries', {
    'data': jsonEncode([
      {'zoneId': 7, 'hasCoveragePath': true},
    ]),
  });
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

/// Host with a button that opens the real [AddObjectSheet] the way the map
/// does (full-height modal sheet).
Widget _sheetHost(
  MissionMockProvider provider, {
  required VoidCallback onRecordingStarted,
}) {
  return ChangeNotifierProvider<MissionMockProvider>.value(
    value: provider,
    child: MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  AddObjectSheet(onRecordingStarted: onRecordingStarted),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
}

/// The provider owns a periodic timer; end it before the framework checks for
/// pending timers.
Future<void> _endWidgetTest(
  WidgetTester tester,
  MissionMockProvider provider,
  _FakeRosbridgeService ros,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  provider.dispose();
  await tester.runAsync(ros.close);
}

Map<String, dynamic> _rtkFix(double latitude, double longitude) => {
  'header': {
    'stamp': {'sec': 122, 'nanosec': 800000000},
  },
  'status': {'status': 2},
  'latitude': latitude,
  'longitude': longitude,
  'position_covariance_type': 2,
  'position_covariance': [0.0002, 0.0, 0.0, 0.0, 0.0002, 0.0, 0.0, 0.0, 0.0004],
};

/// A `/fix` with NavSatStatus [status] (2 = RTK fixed, 0 = float or a plain
/// fix, -1 = none).
Map<String, dynamic> _fixWithStatus(int status) => {
  ..._rtkFix(25.033, 121.5654),
  'status': {'status': status},
};

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _FakeRosbridgeService extends RosbridgeService {
  _FakeRosbridgeService() : super(url: 'ws://robot.test:9090');

  final StreamController<RosbridgeTopicMessage> _messageController =
      StreamController<RosbridgeTopicMessage>.broadcast(sync: true);
  final StreamController<RosbridgeConnectionState> _stateController =
      StreamController<RosbridgeConnectionState>.broadcast(sync: true);
  final Map<String, FutureOr<RosbridgeServiceResponse> Function()> handlers =
      {};
  final Map<String, int> callCount = {};
  final List<({String service, Map<String, dynamic> args})> calls = [];
  final List<({String topic, Map<String, dynamic> message})> published = [];

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
  }) {
    published.add((topic: topic, message: message));
    return true;
  }

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
    if (service == '/check_nav_status') {
      return _response(
        service,
        success: true,
        message: jsonEncode({
          'state': 'idle',
          'task': null,
          'message': 'Navigation idle',
          'ready': true,
          'block_reason': null,
        }),
      );
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
