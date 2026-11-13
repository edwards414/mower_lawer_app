import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/services/screen_wake.dart';
import 'package:mower_stdio/widgets/manual_control_overlay.dart';
import 'package:mower_stdio/widgets/manual_speed_setting.dart';

const _key = 'manual_single_stick';

void main() {
  test('two sticks by default; the pick is saved and restored', () async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    var mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
    await _flushEvents();
    expect(mission.manualSingleStick, isFalse);
    await mission.setManualSingleStick(true);
    expect(mission.manualSingleStick, isTrue);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(_key), isTrue);
    mission.dispose();

    mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
    await _flushEvents();
    expect(mission.manualSingleStick, isTrue);
    mission.dispose();
  });

  testWidgets('設定: 雙搖桿 / 單搖桿 switches the layout', (tester) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: mission,
        child: const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: ManualStickLayoutSetting(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('單搖桿'));
    await tester.pump();
    expect(mission.manualSingleStick, isTrue);
    await tester.tap(find.text('雙搖桿'));
    await tester.pump();
    expect(mission.manualSingleStick, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('one stick drives forward / back and turns', (tester) async {
    final mission = await _pump(tester, single: true);
    expect(_joysticks(), findsOneWidget);
    expect(find.text('行駛'), findsOneWidget);
    expect(find.text('轉向'), findsNothing);

    final stick = await tester.startGesture(tester.getCenter(_joysticks()));
    // Up and to the right: forward, turning right (negative z).
    await stick.moveBy(const Offset(30, -30));
    await tester.pump();
    var (linear, angular) = mission.velocities.last;
    expect(linear, greaterThan(0.05));
    expect(angular, lessThan(-0.05));

    // Straight ahead with a little sideways in it: no turn at all.
    await stick.moveBy(const Offset(-27, -5));
    await tester.pump();
    (linear, angular) = mission.velocities.last;
    expect(linear, greaterThan(0.05));
    expect(angular, 0.0);

    // Down: reverse.
    await stick.moveBy(const Offset(0, 70));
    await tester.pump();
    expect(mission.velocities.last.$1, lessThan(-0.05));

    await stick.up();
    await tester.pump();
    expect(mission.velocities.last, (0.0, 0.0));

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('one stick: the cruise is steered, and pulling back brakes', (
    tester,
  ) async {
    final mission = await _pump(tester, single: true);
    final centre = tester.getCenter(_joysticks());

    var stick = await tester.startGesture(centre);
    await stick.moveBy(const Offset(0, -40));
    await tester.pump();
    final locked = mission.velocities.last.$1;
    expect(locked, greaterThan(0.1));
    await tester.tap(find.text('定速'));
    await tester.pump();
    await stick.up();
    await tester.pump();
    expect(mission.velocities.last, (locked, 0.0));

    // A new touch steers; the speed stays locked.
    stick = await tester.startGesture(centre);
    await stick.moveBy(const Offset(-40, 0));
    await tester.pump();
    expect(mission.velocities.last.$1, locked);
    expect(mission.velocities.last.$2, greaterThan(0.05));
    await tester.pump(const Duration(milliseconds: 250));
    expect(mission.velocities.last.$1, locked);

    // Pulled well back: the cruise ends, and the stick held there does not
    // go on into reverse.
    await stick.moveBy(const Offset(40, 40));
    await tester.pump();
    expect(mission.velocities.last, (0.0, 0.0));
    await stick.moveBy(const Offset(0, 5));
    await tester.pump(const Duration(milliseconds: 250));
    expect(mission.velocities.last, (0.0, 0.0));

    // Back through the middle, it drives again.
    await stick.moveBy(const Offset(0, -45));
    await stick.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(mission.velocities.last.$1, lessThan(-0.05));

    await stick.up();
    await tester.pump();
    expect(mission.velocities.last, (0.0, 0.0));
    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('changing the layout under a held stick stops the robot', (
    tester,
  ) async {
    final mission = await _pump(tester, single: false);
    expect(_joysticks(), findsNWidgets(2));
    expect(find.text('前進 / 後退'), findsOneWidget);

    final stick = await tester.startGesture(
      tester.getCenter(_joysticks().first),
    );
    await stick.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(mission.velocities.last.$1, greaterThan(0.1));

    await mission.setManualSingleStick(true);
    await tester.pump();
    expect(mission.velocities.last, (0.0, 0.0));
    expect(_joysticks(), findsOneWidget);
    final count = mission.velocities.length;
    await tester.pump(const Duration(milliseconds: 350));
    expect(mission.velocities.length, count);

    await stick.up();
    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

Finder _joysticks() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_ManualJoystick',
);

Future<_ManualMissionSpy> _pump(
  WidgetTester tester, {
  required bool single,
}) async {
  SharedPreferences.setMockInitialValues({
    'mock_data_enabled': false,
    _key: single,
  });
  final mission = _ManualMissionSpy();
  await tester.runAsync(_flushEvents);
  expect(mission.manualSingleStick, single);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ManualControlOverlay(
          mission: mission,
          screenWake: const _NoScreenWake(),
        ),
      ),
    ),
  );
  return mission;
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

class _NoScreenWake implements ScreenWake {
  const _NoScreenWake();

  @override
  Future<void> keepOn(bool on) async {}
}

class _ManualMissionSpy extends MissionMockProvider {
  _ManualMissionSpy() : super(rosbridge: _NoopRosbridgeService());

  final List<(double, double)> velocities = [];

  @override
  bool get canDriveManually => true;

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
