import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/manual_control_overlay.dart';

void main() {
  testWidgets('backgrounding stops manual motion and resume stays neutral', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = _ManualMissionSpy();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(mission: mission, onExit: () {}),
        ),
      ),
    );

    final joystick = find
        .byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_ManualJoystick',
        )
        .first;
    final gesture = await tester.startGesture(tester.getCenter(joystick));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(mission.velocities.any((value) => value.$1.abs() > 0.001), isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(mission.velocities.last, (0.0, 0.0));
    final countAfterPause = mission.velocities.length;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(milliseconds: 350));
    expect(mission.velocities.length, countAfterPause);
    expect(mission.velocities.last, (0.0, 0.0));

    await gesture.up();
    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('held gesture stays neutral after the drive gate rolls over', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = _ManualMissionSpy();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(mission: mission, onExit: () {}),
        ),
      ),
    );

    final joystick = find
        .byWidgetPredicate(
          (widget) => widget.runtimeType.toString() == '_ManualJoystick',
        )
        .first;
    final gesture = await tester.startGesture(tester.getCenter(joystick));
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(mission.velocities.last.$1.abs(), greaterThan(0.001));

    mission.driveEnabled = false;
    await tester.pump(const Duration(milliseconds: 110));
    expect(mission.velocities.last, (0.0, 0.0));
    final countAfterGateLoss = mission.velocities.length;

    mission.driveEnabled = true;
    await tester.pump(const Duration(milliseconds: 350));
    expect(mission.velocities.length, countAfterGateLoss);
    expect(mission.velocities.last, (0.0, 0.0));

    await gesture.up();
    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

class _ManualMissionSpy extends MissionMockProvider {
  _ManualMissionSpy() : super(rosbridge: _NoopRosbridgeService());

  final List<(double, double)> velocities = [];
  bool driveEnabled = true;

  @override
  bool get canDriveManually => driveEnabled;

  @override
  bool publishManualVelocity({
    required double linearX,
    required double angularZ,
  }) {
    velocities.add((linearX, angularZ));
    return true;
  }

  @override
  void stopManualControl() {
    velocities.add((0.0, 0.0));
  }

  @override
  String whepUrl(CameraFeed feed) => '';
}

class _NoopRosbridgeService extends RosbridgeService {
  _NoopRosbridgeService() : super(url: 'ws://robot.test:9090');

  @override
  Stream<RosbridgeTopicMessage> get messages => const Stream.empty();

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
}
