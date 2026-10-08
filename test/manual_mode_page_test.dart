import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/providers/phone_location_provider.dart';
import 'package:mower_stdio/providers/recorder_provider.dart';
import 'package:mower_stdio/providers/robot_fleet_provider.dart';
import 'package:mower_stdio/screens/home_screen.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/manual_control_overlay.dart';
import 'package:mower_stdio/widgets/mission_map_canvas.dart';
import 'package:mower_stdio/widgets/mission_mode_bar.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';
import 'package:mower_stdio/widgets/webrtc_camera_view.dart';

/// Manual mode is part of the map page: one map, with the joysticks and the
/// camera laid over it, instead of a second page with a second map.
void main() {
  for (final (name, size) in [
    ('portrait', const Size(390, 844)),
    ('landscape', const Size(844, 390)),
  ]) {
    group(name, () {
      testWidgets('manual mode floats over the one map and ✕ gives it back', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);

        // Normal map page: the panel, and the way in.
        expect(find.byType(ManualControlOverlay), findsNothing);
        expect(find.byType(MissionModeBar), findsOneWidget);
        expect(find.byType(WebrtcCameraView), findsNothing);
        expect(find.byType(MissionMapCanvas), findsOneWidget);

        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        // Still exactly one map; the panel is gone, not hidden.
        expect(h.driveMode.value, isTrue);
        expect(find.byType(MissionMapCanvas), findsOneWidget);
        expect(find.byType(MissionModeBar), findsNothing);
        expect(find.byType(ManualControlOverlay), findsOneWidget);
        expect(find.byType(WebrtcCameraView), findsOneWidget);
        expect(_joysticks(), findsNWidgets(2));
        expect(find.text('前鏡頭'), findsOneWidget);
        expect(find.text('手動模式'), findsNothing);

        await tester.tap(find.byTooltip('退出手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        expect(h.driveMode.value, isFalse);
        expect(find.byType(ManualControlOverlay), findsNothing);
        // The camera session ends with manual mode.
        expect(find.byType(WebrtcCameraView), findsNothing);
        expect(find.byType(MissionModeBar), findsOneWidget);
        expect(find.byType(MissionMapCanvas), findsOneWidget);
        // And the robot was told to stop on the way out.
        expect(h.mission.velocities.last, (0.0, 0.0));

        await h.dispose(tester);
      });

      testWidgets('the camera is a picture-in-picture that a tap enlarges', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);
        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        final camera = find.byType(WebrtcCameraView);
        final small = tester.getSize(camera);
        expect(small.width, lessThan(size.width * 0.4));

        await tester.tap(camera);
        await _settle(tester);
        final big = tester.getSize(camera);
        expect(big.width, greaterThan(small.width * 1.5));
        if (size.width < size.height) {
          // Portrait: a full-width banner at the top of the screen.
          expect(big.width, size.width);
          expect(tester.getTopLeft(camera), Offset.zero);
        } else {
          // Landscape: a corner view that stops short of the middle, where
          // the followed robot is.
          expect(
            tester.getTopLeft(camera).dx,
            greaterThan(size.width / 2 + 24),
          );
        }

        await tester.tap(camera);
        await _settle(tester);
        expect(tester.getSize(camera), small);

        await h.dispose(tester);
      });

      testWidgets('a stick drives in manual mode and ✕ stops it', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);
        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        final gesture = await tester.startGesture(
          tester.getCenter(_joysticks().first),
        );
        await gesture.moveBy(const Offset(0, -40));
        await tester.pump();
        expect(h.mission.velocities.last.$1, greaterThan(0));

        // A second finger leaves while the stick is still held.
        await tester.tap(find.byTooltip('退出手動模式'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(h.mission.velocities.last, (0.0, 0.0));
        final sent = h.mission.velocities.length;
        await gesture.up();
        await tester.pump(const Duration(milliseconds: 350));
        // Nothing more goes out for the released stick.
        expect(
          h.mission.velocities.skip(sent).every((v) => v == (0.0, 0.0)),
          isTrue,
        );

        await h.dispose(tester);
      });

      testWidgets('the way in stays clear of the tools and the robot', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);

        final entry = tester.getRect(
          find.ancestor(of: find.text('手動模式'), matching: find.byType(InkWell)),
        );
        if (size.width < size.height) {
          // Portrait: centred above the panel, between the tool columns.
          expect(entry.center.dx, closeTo(size.width / 2, 1));
        } else {
          // Landscape has hardly any map above the panel: the top-right
          // corner, not on top of the (centred) robot.
          expect(entry.right, closeTo(size.width - 12, 1));
          expect(entry.top, lessThan(24));
        }
        for (final tool in ['新增物件', '場地庫', '圖層', '停止跟隨割草機', '顯示我的位置']) {
          expect(
            entry.overlaps(tester.getRect(find.byTooltip(tool))),
            isFalse,
            reason: tool,
          );
        }

        await h.dispose(tester);
      });

      testWidgets('manual mode keeps the scale pill out from under the stick', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);
        bool scalePill() => tester
            .widget<MissionMapCanvas>(find.byType(MissionMapCanvas))
            .showScalePill;
        expect(scalePill(), isTrue);

        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(scalePill(), isFalse);

        await tester.tap(find.byTooltip('退出手動模式'));
        await tester.pump(const Duration(milliseconds: 400));
        expect(scalePill(), isTrue);

        await h.dispose(tester);
      });

      testWidgets('on the satellite map it is the same map, zoom only', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size, satellite: true);
        final map = find.byType(SatelliteMapView);
        int flags() => tester
            .widget<FlutterMap>(find.byType(FlutterMap))
            .options
            .interactionOptions
            .flags;
        expect(map, findsOneWidget);
        expect(InteractiveFlag.hasDrag(flags()), isTrue);
        // Above the panel, with its rounded corners tucked under.
        final withPanel = tester.getSize(map).height;
        expect(withPanel, lessThan(size.height));

        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        // Still one satellite map: it fills the page, follows the robot and
        // takes pinch / double-tap zoom, but a drag cannot pull it away.
        expect(map, findsOneWidget);
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(tester.getSize(map), size);
        expect(InteractiveFlag.hasDrag(flags()), isFalse);
        expect(InteractiveFlag.hasPinchZoom(flags()), isTrue);
        expect(InteractiveFlag.hasDoubleTapZoom(flags()), isTrue);
        expect(tester.widget<SatelliteMapView>(map).followRobot, isTrue);
        // Its attribution is lifted above the sticks, and nothing on the map
        // pulses (a pulse repaints the whole map every frame).
        expect(
          tester.widget<SatelliteMapView>(map).bottomInset,
          ManualControlOverlay.controlsClearance(size),
        );
        expect(tester.widget<SatelliteMapView>(map).animateMarker, isFalse);

        await tester.tap(find.byTooltip('退出手動模式'));
        // A first frame starts the map easing back down to the panel.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(InteractiveFlag.hasDrag(flags()), isTrue);
        expect(tester.getSize(map).height, withPanel);
        expect(tester.widget<SatelliteMapView>(map).bottomInset, 0);
        expect(tester.widget<SatelliteMapView>(map).animateMarker, isTrue);

        await h.dispose(tester);
      });

      testWidgets('moving a stick repaints the stick, not the map', (
        tester,
      ) async {
        final h = await _Harness.pump(tester, size);
        await tester.tap(find.text('手動模式'));
        await tester.pump(const Duration(milliseconds: 400));

        // The map paints a fresh projection each time it is redrawn.
        final map = tester.state<MissionMapCanvasState>(
          find.byType(MissionMapCanvas),
        );
        final painted = map.lastProjection;
        expect(painted, isNotNull);

        final gesture = await tester.startGesture(
          tester.getCenter(_joysticks().first),
        );
        await gesture.moveBy(const Offset(0, -30));
        for (var i = 0; i < 10; i++) {
          await gesture.moveBy(Offset(0, i.isEven ? -3 : 3));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(h.mission.velocities.any((v) => v.$1 > 0), isTrue);
        expect(identical(map.lastProjection, painted), isTrue);

        await gesture.up();
        await tester.pump();
        await h.dispose(tester);
      });
    });
  }

  testWidgets('landscape controls stay out of the notch and the corners', (
    tester,
  ) async {
    // A notched phone on its side: 62 pt taken at both ends, 21 at the bottom.
    tester.view.padding = const FakeViewPadding(
      left: 62,
      right: 62,
      bottom: 21,
    );
    tester.view.viewPadding = tester.view.padding;
    final h = await _Harness.pump(tester, const Size(844, 390));
    await tester.tap(find.text('手動模式'));
    await tester.pump(const Duration(milliseconds: 400));

    Rect rect(Finder f) => tester.getRect(f);
    expect(rect(find.byTooltip('退出手動模式')).left, greaterThanOrEqualTo(62));
    expect(
      rect(find.byType(WebrtcCameraView)).right,
      lessThanOrEqualTo(844 - 62),
    );
    expect(rect(_joysticks().first).left, greaterThanOrEqualTo(62));
    expect(rect(_joysticks().last).right, lessThanOrEqualTo(844 - 62));
    // The bottom safe area is respected too.
    expect(rect(_joysticks().first).bottom, lessThanOrEqualTo(390 - 21));

    // Enlarged, the camera still keeps off the notch, and off the robot.
    await tester.tap(find.byType(WebrtcCameraView));
    await _settle(tester);
    expect(
      rect(find.byType(WebrtcCameraView)).right,
      lessThanOrEqualTo(844 - 62),
    );
    expect(rect(find.byType(WebrtcCameraView)).left, greaterThan(844 / 2 + 24));

    await h.dispose(tester);
  });

  testWidgets('a recording started from the map is driven right there', (
    tester,
  ) async {
    final h = await _Harness.pump(tester, const Size(390, 844));
    // The way in is taken by the recording bar's own button.
    h.mission.recording = RecordObjectType.zone;
    h.mission.poke();
    // The panel eases down now that the next-step banner is gone.
    await _settle(tester);
    expect(find.text('手動模式'), findsNothing);

    await tester.tap(find.byTooltip('進入手動模式'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.driveMode.value, isTrue);
    // One bar for the recording, with no way "in" since it is already there.
    expect(find.textContaining('工作區記錄中'), findsOneWidget);
    expect(find.byTooltip('進入手動模式'), findsNothing);

    // Leaving manual mode keeps the recording; its bar on the map saves it.
    await tester.tap(find.byTooltip('退出手動模式'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.mission.recordingType, RecordObjectType.zone);
    expect(find.textContaining('工作區記錄中'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('a long recording keeps counting minutes', (tester) async {
    final h = await _Harness.pump(tester, const Size(390, 844));
    h.mission.recording = RecordObjectType.channel;
    h.mission.elapsed = const Duration(minutes: 75, seconds: 10);
    h.mission.poke();
    await _settle(tester);

    // Not 15:10: the clock does not wrap at the hour.
    expect(find.textContaining('75:10'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('the record picker starts a recording and tucks itself away', (
    tester,
  ) async {
    final mission = _DriveSpy();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(mission: mission, onExit: () {}),
        ),
      ),
    );

    // Tucked away until asked for.
    expect(find.text('工作區'), findsNothing);
    await tester.tap(find.text('記錄邊界'));
    await tester.pump();
    expect(find.text('工作區'), findsOneWidget);
    expect(find.text('禁入區'), findsOneWidget);
    expect(find.text('通道'), findsOneWidget);

    await tester.tap(find.text('禁入區'));
    await tester.pump();
    await tester.pump();
    expect(mission.started, [RecordObjectType.risk]);
    expect(find.text('禁入區'), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });

  testWidgets('the recording bar works in manual mode without a Provider', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
    final mission = MissionMockProvider(rosbridge: RosbridgeService());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ManualControlOverlay(mission: mission, onExit: () {}),
        ),
      ),
    );

    expect(await mission.startRecording(RecordObjectType.channel), isNull);
    await tester.pump();
    // The overlay follows the mission itself: REC bar with a clock, and the
    // picker button makes way for it.
    expect(find.textContaining('通道記錄中 · 00:0'), findsOneWidget);
    expect(find.text('記錄邊界'), findsNothing);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump();
    expect(mission.recordingType, isNull);
    expect(find.text('記錄邊界'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

/// A first frame starts an implicit animation's clock; the second runs it out.
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Finder _joysticks() => find.byWidgetPredicate(
  (widget) => widget.runtimeType.toString() == '_ManualJoystick',
);

/// The map page with a drivable (spy) mission, no robot, no network.
class _Harness {
  _Harness(this.mission, this.driveMode, this.fleet, this.phone, this.recorder);

  final _DriveSpy mission;
  final ValueNotifier<bool> driveMode;
  final RobotFleetProvider fleet;
  final PhoneLocationProvider phone;
  final RecorderProvider recorder;

  static Future<_Harness> pump(
    WidgetTester tester,
    Size size, {
    bool satellite = false,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final ros = _QuietRosbridge();
    final mission = _DriveSpy();
    // Let the provider finish starting up; it clears the map data then.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    if (satellite) {
      mission
        ..mapGeoAnchor = const GeoAnchor(originLat: 25.0, originLon: 121.5)
        ..satelliteBaseMap = true
        ..aiBaseMap = false;
    }
    final h = _Harness(
      mission,
      ValueNotifier<bool>(false),
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
        child: MaterialApp(home: MissionMapScreen(driveMode: h.driveMode)),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    return h;
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    driveMode.dispose();
    recorder.dispose();
    fleet.dispose();
    phone.dispose();
    mission.dispose();
  }
}

class _DriveSpy extends MissionMockProvider {
  _DriveSpy() : super(rosbridge: _QuietRosbridge());

  final List<(double, double)> velocities = [];
  final List<RecordObjectType> started = [];

  /// Stands in for a recording the robot accepted.
  RecordObjectType? recording;

  /// How long it has been going, when the test needs a particular time.
  Duration? elapsed;

  @override
  Duration get recordingElapsed => elapsed ?? super.recordingElapsed;

  void poke() => notifyListeners();

  @override
  RecordObjectType? get recordingType => recording ?? super.recordingType;

  @override
  bool get canDriveManually => true;

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
  Future<String?> startRecording(RecordObjectType type) async {
    started.add(type);
    return null;
  }

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
