import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/providers/phone_location_provider.dart';
import 'package:mower_stdio/providers/recorder_provider.dart';
import 'package:mower_stdio/providers/robot_fleet_provider.dart';
import 'package:mower_stdio/screens/home_screen.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/front_camera_pip.dart';
import 'package:mower_stdio/widgets/map_task_controls.dart';
import 'package:mower_stdio/widgets/mission_map_canvas.dart';
import 'package:mower_stdio/widgets/planning_control_sheet.dart';
import 'package:mower_stdio/widgets/webrtc_camera_view.dart';

/// The map is one page: the joysticks are always on it, the task bar says
/// what comes next, and nothing switches the page into a mode.
void main() {
  testWidgets('the sticks are on the map, with no manual mode to enter', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);

    expect(_joysticks(), findsNWidgets(2));
    expect(find.text('手動模式'), findsNothing);
    expect(find.byTooltip('退出手動模式'), findsNothing);
    // No zone yet: no buttons at all, the + is the way in.
    expect(find.byType(MapTaskControls), findsNothing);
    expect(find.byTooltip('新增物件'), findsOneWidget);
    // The map follows the robot by default; there is no button for it.
    expect(find.byTooltip('跟隨割草機'), findsNothing);
    expect(find.byTooltip('停止跟隨割草機'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('a stick drives right on the map; leaving the page stops it', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);

    final gesture = await tester.startGesture(
      tester.getCenter(_joysticks().first),
    );
    await gesture.moveBy(const Offset(0, -40));
    await tester.pump();
    expect(h.mission.velocities.last.$1, greaterThan(0));

    // Another tab is shown while the stick is still held.
    h.active.value = false;
    await tester.pump();
    expect(h.mission.velocities.last, (0.0, 0.0));
    expect(_joysticks(), findsNothing);
    final sent = h.mission.velocities.length;
    await gesture.up();
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      h.mission.velocities.skip(sent).every((v) => v == (0.0, 0.0)),
      isTrue,
    );

    await h.dispose(tester);
  });

  testWidgets(
    'a tapped zone brings up its buttons; 任務設定 stops the sticks first',
    (tester) async {
      final h = await _Harness.pump(tester);
      h.mission
        ..zones = const [
          MissionZone(
            id: 1,
            name: '前院',
            points: [
              MapPoint(2, 2),
              MapPoint(9, 2),
              MapPoint(9, 9),
              MapPoint(2, 9),
            ],
          ),
        ]
        ..selectedZoneId = 1
        ..poke();
      await tester.pump(const Duration(milliseconds: 300));
      // Selected, but not tapped yet: nothing floats over the map.
      expect(find.text('生成路徑'), findsNothing);

      final projection = tester
          .state<MissionMapCanvasState>(find.byType(MissionMapCanvas))
          .lastProjection!;
      final inZone = projection.project(const MapPoint(5.5, 5.5));
      final outside = projection.project(const MapPoint(-4, -4));
      await tester.tapAt(inZone);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('生成路徑'), findsOneWidget);
      expect(find.byTooltip('任務設定'), findsOneWidget);
      // Above the right stick, clear of it.
      expect(
        tester.getRect(find.text('生成路徑')).bottom,
        lessThan(tester.getRect(_joysticks().last).top),
      );

      // 任務設定 with a stick held: the robot stops before the sheet covers it.
      final gesture = await tester.startGesture(
        tester.getCenter(_joysticks().first),
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(h.mission.velocities.last.$1, greaterThan(0));
      await tester.tap(find.byTooltip('任務設定'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.mission.velocities.last, (0.0, 0.0));
      expect(find.byType(PlanningControlSheet), findsOneWidget);
      await gesture.up();
      Navigator.of(tester.element(find.byType(TaskDetailsSheet))).pop();
      await tester.pump(const Duration(milliseconds: 400));

      // Empty map puts the buttons away.
      await tester.tapAt(outside);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('生成路徑'), findsNothing);

      await h.dispose(tester);
    },
  );

  testWidgets('every map button is in one column on the left', (tester) async {
    var homes = 0;
    var settings = 0;
    final h = await _Harness.pump(
      tester,
      onHome: () => homes++,
      onSettings: () => settings++,
    );
    final home = find.byTooltip('回主畫面');
    final gear = find.byTooltip('設定');
    final column = [
      home,
      gear,
      find.byTooltip('打開衛星圖'),
      find.byTooltip('打開前鏡頭'),
      find.byTooltip('新增物件'),
      find.byTooltip('場地庫'),
    ];
    final stickTop = tester.getRect(_joysticks().first).top;
    Rect? above;
    for (final button in column) {
      final r = tester.getRect(button);
      expect(r.left, lessThan(30));
      expect(r.right, lessThan(70));
      // In this order, top to bottom, none over another or over the sticks.
      if (above != null) expect(r.top, greaterThanOrEqualTo(above.bottom));
      expect(r.bottom, lessThan(stickTop));
      above = r;
    }

    // Landscape: too short for one column above the sticks, so it wraps
    // into a second, still on the left and clear of the sticks.
    tester.view.physicalSize = const Size(844, 390);
    await tester.pump(const Duration(milliseconds: 300));
    final landscapeStickTop = tester.getRect(_joysticks().first).top;
    for (final button in column) {
      final r = tester.getRect(button);
      expect(r.right, lessThan(140));
      expect(r.bottom, lessThan(landscapeStickTop));
    }
    tester.view.physicalSize = const Size(390, 844);
    await tester.pump(const Duration(milliseconds: 300));

    // Home and 設定 stop the robot before they leave the map.
    for (final (button, count) in [
      (gear, () => settings),
      (home, () => homes),
    ]) {
      final gesture = await tester.startGesture(
        tester.getCenter(_joysticks().first),
      );
      await gesture.moveBy(const Offset(0, -40));
      await tester.pump();
      expect(h.mission.velocities.last.$1, greaterThan(0));
      await tester.tap(button);
      await tester.pump();
      expect(h.mission.velocities.last, (0.0, 0.0));
      expect(count(), 1);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));
    }

    await h.dispose(tester);
  });

  testWidgets('the camera stays off until it is turned on', (tester) async {
    final h = await _Harness.pump(tester);
    expect(find.byType(WebrtcCameraView), findsNothing);

    await tester.tap(find.byTooltip('打開前鏡頭'));
    await tester.pump(const Duration(milliseconds: 300));
    final camera = find.byType(WebrtcCameraView);
    expect(camera, findsOneWidget);
    expect(tester.getSize(camera).width, lessThan(390 * 0.4));

    // A tap on the picture enlarges it.
    await tester.tap(camera);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    // The frame (the picture sits inside its white border).
    expect(tester.getSize(find.byType(FrontCameraPip)).width, 390 - 70 - 12);
    // It stays clear of the left-hand buttons, its own switch among them.
    expect(
      tester.getRect(camera).left,
      greaterThan(tester.getRect(find.byTooltip('關閉前鏡頭')).right),
    );

    await tester.tap(find.byTooltip('關閉前鏡頭'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(WebrtcCameraView), findsNothing);

    await h.dispose(tester);
  });

  testWidgets(
    'mowing locks the sticks; a tap on them offers to stop the task',
    (tester) async {
      final h = await _Harness.pump(tester);
      h.mission
        ..drivable = false
        ..lockReason = '割草中'
        ..lockedByMission = true
        ..poke();
      await tester.pump();
      expect(find.textContaining('割草中'), findsNWidgets(2));

      await tester.tap(_joysticks().first);
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('割草中，搖桿已鎖住'), findsOneWidget);
      expect(h.mission.cancels, 0);
      // Nothing drove.
      expect(h.mission.velocities.where((v) => v != (0.0, 0.0)), isEmpty);

      await tester.tap(find.text('停止任務'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(h.mission.cancels, 1);
      // Still locked: only the robot's confirmed stop unlocks them.
      expect(find.textContaining('割草中'), findsNWidgets(2));

      await h.dispose(tester);
    },
  );

  testWidgets('a recording keeps 儲存 over the sticks and its time on top', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    h.mission
      ..recording = RecordObjectType.zone
      ..poke();
    await tester.pump();
    expect(find.textContaining('REC'), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);
    expect(find.byTooltip('取消記錄'), findsOneWidget);
    expect(_joysticks(), findsNWidgets(2));
    // 儲存 floats above the right stick, never under a thumb.
    expect(
      tester.getRect(find.text('儲存')).bottom,
      lessThan(tester.getRect(_joysticks().last).top),
    );

    // RTK not fixed: the bar says so in place of the hint.
    h.mission
      ..rtkWarning = 'RTK 不是固定解，這段不會記進邊界'
      ..poke();
    await tester.pump();
    expect(find.text('RTK 不是固定解，這段不會記進邊界'), findsOneWidget);

    await h.dispose(tester);
  });
}

Finder _joysticks() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_ManualJoystick',
);

/// The map page with a drivable (spy) mission, no robot, no network.
class _Harness {
  _Harness(this.mission, this.active, this.fleet, this.phone, this.recorder);

  final _DriveSpy mission;
  final ValueNotifier<bool> active;
  final RobotFleetProvider fleet;
  final PhoneLocationProvider phone;
  final RecorderProvider recorder;

  static Future<_Harness> pump(
    WidgetTester tester, {
    VoidCallback? onHome,
    VoidCallback? onSettings,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final ros = _QuietRosbridge();
    final mission = _DriveSpy();
    // Let the provider finish starting up; it clears the map data then.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    final h = _Harness(
      mission,
      ValueNotifier<bool>(true),
      RobotFleetProvider(rosbridge: ros),
      PhoneLocationProvider(),
      RecorderProvider(rosbridge: ros),
    );
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<MissionMockProvider>.value(value: h.mission),
          ChangeNotifierProvider<RobotFleetProvider>.value(value: h.fleet),
          ChangeNotifierProvider<PhoneLocationProvider>.value(value: h.phone),
          ChangeNotifierProvider<RecorderProvider>.value(value: h.recorder),
        ],
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: h.active,
            builder: (context, active, _) => MissionMapScreen(
              active: active,
              onHome: onHome,
              onSettings: onSettings,
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    return h;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    active.dispose();
    recorder.dispose();
    fleet.dispose();
    phone.dispose();
    mission.dispose();
  }
}

class _DriveSpy extends MissionMockProvider {
  _DriveSpy() : super(rosbridge: _QuietRosbridge());

  final List<(double, double)> velocities = [];
  int cancels = 0;

  /// Stands in for a recording the robot accepted.
  RecordObjectType? recording;

  /// Stands in for what `/fix` says about RTK fixed while recording.
  String? rtkWarning;

  @override
  String? get recordingRtkWarning => rtkWarning;

  /// The drive gate, and what the sticks say while it is closed.
  bool drivable = true;
  String? lockReason;
  bool lockedByMission = false;

  void poke() => notifyListeners();

  @override
  RecordObjectType? get recordingType => recording ?? super.recordingType;

  @override
  bool get canDriveManually => drivable;

  @override
  String? get manualDriveBlockReason => drivable ? null : lockReason;

  @override
  bool get manualDriveLockedByMission => lockedByMission;

  // A robot with a pose, so the map has something to follow.
  @override
  bool get shouldShowRobot => true;

  @override
  bool publishManualVelocity({
    required double linearX,
    required double angularZ,
  }) {
    velocities.add((linearX, angularZ));
    return true;
  }

  @override
  void stopManualControl() => velocities.add((0.0, 0.0));

  @override
  void cancelExecution() => cancels++;

  @override
  String whepUrl(CameraFeed feed) => '';
}

class _QuietRosbridge extends RosbridgeService {
  _QuietRosbridge() : super(url: 'ws://robot.test:9090');

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

  // Answers at once, so no 12 s service timeout is left pending.
  @override
  Future<RosbridgeServiceResponse> callService(
    String service, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 12),
  }) async => RosbridgeServiceResponse(
    service: service,
    result: false,
    values: const {},
  );
}
