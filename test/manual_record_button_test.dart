import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/providers/recorder_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/manual_control_overlay.dart';

void main() {
  testWidgets('record button toggles /mower_recorder start and stop', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final rosbridge = _RecorderRosbridgeFake();
    final mission = _MissionStub(rosbridge);
    final recorder = RecorderProvider(rosbridge: rosbridge);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(
            mission: mission,
            onExit: () {},
            recorder: recorder,
          ),
        ),
      ),
    );

    await tester.tap(find.text('錄話題'));
    await tester.pump();
    expect(rosbridge.calls, ['/mower_recorder/start']);
    expect(find.text('開始錄製 run=mower_1'), findsOneWidget);

    rosbridge.pushStatus({
      'recording': true,
      'run_id': 'mower_1',
      'elapsed_s': 65,
    });
    await tester.pump();
    expect(find.text('REC 01:05'), findsOneWidget);

    await tester.tap(find.text('REC 01:05'));
    await tester.pump();
    expect(rosbridge.calls, ['/mower_recorder/start', '/mower_recorder/stop']);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    mission.dispose();
    await rosbridge.close();
  });

  testWidgets('a failed start is reported, not shown as recording', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final rosbridge = _RecorderRosbridgeFake()..succeed = false;
    final mission = _MissionStub(rosbridge);
    final recorder = RecorderProvider(rosbridge: rosbridge);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(
            mission: mission,
            onExit: () {},
            recorder: recorder,
          ),
        ),
      ),
    );

    await tester.tap(find.text('錄話題'));
    await tester.pump();
    expect(find.text('錄製失敗：已在錄製中'), findsOneWidget);
    expect(find.text('錄話題'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    mission.dispose();
    await rosbridge.close();
  });

  testWidgets('no recorder on the robot says how to start one', (tester) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final rosbridge = _RecorderRosbridgeFake()..bridgeRejects = true;
    final mission = _MissionStub(rosbridge);
    final recorder = RecorderProvider(rosbridge: rosbridge);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(
            mission: mission,
            onExit: () {},
            recorder: recorder,
          ),
        ),
      ),
    );

    await tester.tap(find.text('錄話題'));
    await tester.pump();
    expect(
      find.textContaining('sudo mower-data-collection.sh start'),
      findsOneWidget,
    );
    expect(find.text('錄話題'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    mission.dispose();
    await rosbridge.close();
  });
}

class _MissionStub extends MissionMockProvider {
  _MissionStub(RosbridgeService rosbridge) : super(rosbridge: rosbridge);

  @override
  bool get canDriveManually => true;

  @override
  void stopManualControl() {}

  @override
  String whepUrl(CameraFeed feed) => '';
}

class _RecorderRosbridgeFake extends RosbridgeService {
  _RecorderRosbridgeFake() : super(url: 'ws://robot.test:9090');

  final _messages = StreamController<RosbridgeTopicMessage>.broadcast();
  final List<String> calls = [];
  bool succeed = true;

  /// The bridge answers without a Trigger response (service not running).
  bool bridgeRejects = false;

  void pushStatus(Map<String, dynamic> status) => _messages.add(
    RosbridgeTopicMessage(
      topic: '/mower_recorder/status',
      message: {'data': jsonEncode(status)},
    ),
  );

  Future<void> close() => _messages.close();

  @override
  Stream<RosbridgeTopicMessage> get messages => _messages.stream;

  @override
  Stream<RosbridgeConnectionState> get states => const Stream.empty();

  @override
  Future<void> loadSavedRobotIp() async {}

  @override
  void connect() {}

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
    if (bridgeRejects) {
      return RosbridgeServiceResponse(
        service: service,
        result: false,
        values: const {},
      );
    }
    return RosbridgeServiceResponse(
      service: service,
      result: true,
      values: {
        'success': succeed,
        'message': succeed
            ? (service.endsWith('start') ? '開始錄製 run=mower_1' : '已停止')
            : '已在錄製中',
      },
    );
  }
}
