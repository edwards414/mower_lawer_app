import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';

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

      await Future<void>.delayed(const Duration(milliseconds: 150));
      ros.emit('/manual_command_clock', {
        'stamp': {'sec': 123, 'nanosec': 456},
        'frame_id': 'manual-session-v1:test-session',
      });
      await Future<void>.delayed(const Duration(milliseconds: 80));
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
