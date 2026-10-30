import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/services/screen_wake.dart';
import 'package:mower_stdio/widgets/manual_control_overlay.dart';

/// Cruise (定速): the left stick's forward speed held after the stick lets go,
/// the right stick still steering, the screen kept on, and every way out a
/// stop that lets the screen sleep again.
void main() {
  testWidgets('cruise holds the locked speed and the right stick steers', (
    tester,
  ) async {
    final rig = await _Rig.pump(tester);
    final locked = await rig.engage();
    final pill = '定速 ${locked.toStringAsFixed(2)} m/s';

    expect(rig.wake.calls, [true]);
    expect(find.text(pill), findsOneWidget);
    expect(find.byTooltip('取消定速'), findsOneWidget);

    // The left stick is let go: the speed holds, sent every 100 ms.
    var sent = rig.mission.velocities.length;
    await tester.pump(const Duration(milliseconds: 350));
    final held = rig.mission.velocities.skip(sent).toList();
    expect(held, hasLength(3));
    expect(held.every((v) => v == (locked, 0.0)), isTrue);

    // The right stick steers on top of it...
    final steer = await tester.startGesture(tester.getCenter(rig.rightStick));
    await steer.moveBy(const Offset(-40, 0));
    await tester.pump(const Duration(milliseconds: 110));
    expect(rig.mission.velocities.last.$1, locked);
    expect(rig.mission.velocities.last.$2, greaterThan(0.5));

    // ...and letting it go straightens up without slowing down.
    await steer.up();
    await tester.pump();
    expect(rig.mission.velocities.last, (locked, 0.0));
    sent = rig.mission.velocities.length;
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      rig.mission.velocities.skip(sent).every((v) => v == (locked, 0.0)),
      isTrue,
    );
    expect(rig.mission.velocities.length, greaterThan(sent));
    expect(find.text(pill), findsOneWidget);
    expect(rig.wake.calls, [true]);

    await rig.dispose();
  });

  testWidgets('cruise is refused at rest and in reverse', (tester) async {
    final rig = await _Rig.pump(tester);

    // Nothing on the stick: nothing is sent, and a hint says why.
    await tester.tap(find.text('定速'));
    await tester.pump();
    expect(rig.mission.velocities, isEmpty);
    expect(find.text('先把左搖桿往前推，再按定速'), findsOneWidget);

    // A thumb resting mid-stick, inside the deadband, is still at rest.
    var stick = await tester.startGesture(tester.getCenter(rig.leftStick));
    await tester.pump();
    await tester.tap(find.text('定速'));
    await tester.pump();
    await stick.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(rig.mission.velocities.every((v) => v == (0.0, 0.0)), isTrue);

    // In reverse: the release stops it as usual, and nothing runs on.
    stick = await tester.startGesture(tester.getCenter(rig.leftStick));
    await stick.moveBy(const Offset(0, 40));
    await tester.pump();
    expect(rig.mission.velocities.last.$1, lessThan(0));
    await tester.tap(find.text('定速'));
    await tester.pump();
    await stick.up();
    await tester.pump();
    expect(rig.mission.velocities.last, (0.0, 0.0));
    final sent = rig.mission.velocities.length;
    await tester.pump(const Duration(milliseconds: 350));
    expect(rig.mission.velocities.length, sent);

    // The screen was never held, and the pill never said 定速.
    expect(rig.wake.calls, isEmpty);
    expect(find.textContaining('m/s'), findsNothing);
    expect(find.byTooltip('取消定速'), findsNothing);

    await rig.dispose();
  });

  // Each way out of a cruise, as the operator or the app would take it.
  for (final (name, cancel) in <(String, Future<void> Function(_Rig))>[
    (
      'the 定速 button again',
      (rig) async {
        await rig.tester.tap(find.text('定速'));
        await rig.tester.pump();
      },
    ),
    (
      'a touch on the left stick',
      (rig) async {
        final tester = rig.tester;
        final stick = await tester.startGesture(
          tester.getCenter(rig.leftStick),
        );
        await tester.pump();
        // The touch alone stops it, before any release.
        expect(rig.mission.velocities.last, (0.0, 0.0));
        expect(rig.wake.calls, [true, false]);
        // From there the stick drives as usual...
        await stick.moveBy(const Offset(0, -20));
        await tester.pump();
        final v = rig.mission.velocities.last.$1;
        expect(v, greaterThan(0));
        expect(v, lessThan(rig.locked));
        // ...and its release stops as usual.
        await stick.up();
        await tester.pump();
      },
    ),
    (
      'the app paused',
      (rig) async {
        rig.tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.paused,
        );
        await rig.tester.pump();
        expect(rig.mission.velocities.last, (0.0, 0.0));
        // Coming back does not pick the cruise up again.
        rig.tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await rig.tester.pump();
      },
    ),
    (
      'the app inactive',
      (rig) async {
        rig.tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await rig.tester.pump();
        expect(rig.mission.velocities.last, (0.0, 0.0));
        rig.tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await rig.tester.pump();
      },
    ),
    (
      'the drive gate closing',
      (rig) async {
        rig.mission.driveEnabled = false;
        // The next 100 ms tick notices, and says stop instead of the speed.
        await rig.tester.pump(const Duration(milliseconds: 110));
        expect(rig.mission.velocities.last, (0.0, 0.0));
        // The gate opening again does not pick the cruise up.
        rig.mission.driveEnabled = true;
        rig.mission.poke();
        await rig.tester.pump();
      },
    ),
    (
      '✕ leaving manual mode',
      (rig) async {
        await rig.tester.tap(find.byTooltip('退出手動模式'));
        await rig.tester.pump();
        expect(rig.exits, 1);
      },
    ),
    (
      'the overlay going away',
      (rig) async {
        await rig.tester.pumpWidget(const SizedBox.shrink());
      },
    ),
  ]) {
    testWidgets('$name ends a cruise with a stop and lets the screen sleep', (
      tester,
    ) async {
      final rig = await _Rig.pump(tester);
      await rig.engage();
      final before = rig.mission.velocities.length;

      await cancel(rig);

      // Only stops went out from the moment it ended, and stop was the last.
      final after = rig.mission.velocities.skip(before).toList();
      expect(after, isNotEmpty);
      expect(after.last, (0.0, 0.0));
      expect(after.where((v) => v.$1 == rig.locked), isEmpty);
      expect(rig.wake.calls, [true, false]);
      // Nothing runs on.
      final sent = rig.mission.velocities.length;
      await tester.pump(const Duration(milliseconds: 350));
      expect(rig.mission.velocities.length, sent);
      expect(find.textContaining('m/s'), findsNothing);
      expect(find.byTooltip('取消定速'), findsNothing);
      expect(rig.wake.calls, [true, false]);

      await rig.dispose();
    });
  }
}

Finder _joysticks() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_ManualJoystick',
);

/// The overlay alone, on a drivable (spy) mission, with a fake wakelock.
class _Rig {
  _Rig(this.tester, this.mission, this.wake);

  final WidgetTester tester;
  final _ManualMissionSpy mission;
  final _FakeScreenWake wake;
  int exits = 0;

  /// The speed [engage] locked.
  double locked = 0;

  Finder get leftStick => _joysticks().first;
  Finder get rightStick => _joysticks().last;

  static Future<_Rig> pump(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final rig = _Rig(tester, _ManualMissionSpy(), _FakeScreenWake());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(
            mission: rig.mission,
            onExit: () => rig.exits++,
            screenWake: rig.wake,
          ),
        ),
      ),
    );
    return rig;
  }

  /// Holds the left stick forward, presses 定速 with another finger, then
  /// lets the stick go. Returns the locked speed.
  Future<double> engage() async {
    final stick = await tester.startGesture(tester.getCenter(leftStick));
    await stick.moveBy(const Offset(0, -40));
    await tester.pump();
    locked = mission.velocities.last.$1;
    expect(locked, greaterThan(0.1));
    await tester.tap(find.text('定速'));
    await tester.pump();
    await stick.up();
    await tester.pump();
    // The release did not end it.
    expect(mission.velocities.last, (locked, 0.0));
    return locked;
  }

  Future<void> dispose() async {
    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  }
}

class _FakeScreenWake implements ScreenWake {
  final List<bool> calls = [];

  @override
  Future<void> keepOn(bool on) async => calls.add(on);
}

class _ManualMissionSpy extends MissionMockProvider {
  _ManualMissionSpy() : super(rosbridge: _NoopRosbridgeService());

  final List<(double, double)> velocities = [];
  bool driveEnabled = true;

  void poke() => notifyListeners();

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
