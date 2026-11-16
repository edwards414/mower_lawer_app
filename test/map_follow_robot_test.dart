import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/models/map_camera.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/breathing_marker.dart';
import 'package:mower_stdio/widgets/mission_map_canvas.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';

// The default 800x600 test surface; its centre is where a followed robot sits.
const _centre = Offset(400, 300);

void main() {
  testWidgets('canvas centerOn puts the robot mid-map, all content in view', (
    tester,
  ) async {
    final (ros, mission) = await _missionWithRobotAt(tester, 36, 4);
    final key = GlobalKey<MissionMapCanvasState>();

    Future<MapProjection> paint({MapPoint? centerOn}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MissionMapCanvas(
            key: key,
            mission: mission,
            // No panel: the map area is the whole surface.
            bottomInset: 0,
            centerOn: centerOn,
          ),
        ),
      );
      return key.currentState!.lastProjection!;
    }

    final framed = await paint();
    expect(
      framed.project(mission.robotPosition),
      isNot(offsetMoreOrLessEquals(_centre, epsilon: 20)),
      reason: 'a robot near the lawn edge is off-centre when framing all',
    );

    final followed = await paint(centerOn: mission.robotPosition);
    expect(
      followed.project(mission.robotPosition),
      offsetMoreOrLessEquals(_centre, epsilon: 1e-6),
    );
    for (final p in mission.zones.single.points) {
      final s = followed.project(p);
      expect(s.dx, inInclusiveRange(0, 800));
      expect(s.dy, inInclusiveRange(0, 600));
    }

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    await ros.close();
  });

  testWidgets('satellite follow pauses for a drag, then picks up again', (
    tester,
  ) async {
    final (ros, mission) = await _missionWithRobotAt(tester, 36, 4);
    var follow = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => ListenableBuilder(
            listenable: mission,
            builder: (context, _) => SatelliteMapView(
              mission: mission,
              anchor: const GeoAnchor(originLat: 25.0, originLon: 121.5),
              followRobot: follow,
              onFollowRobotChanged: (on) => setState(() => follow = on),
              resumeFollowAfter: const Duration(seconds: 8),
            ),
          ),
        ),
      ),
    );
    Offset robot() => tester.getCenter(find.byType(BreathingMarker));

    // The initial fit is applied once the map knows its size.
    await tester.pump();
    await tester.pump();
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    ros.pushPose(10, 25);
    await tester.pump();
    await tester.pump();
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    // A one-finger drag stops following.
    await tester.dragFrom(const Offset(200, 560), const Offset(120, 0));
    await tester.pump();
    expect(follow, isFalse);

    ros.pushPose(20, 15);
    await tester.pump();
    await tester.pump();
    expect(robot(), isNot(offsetMoreOrLessEquals(_centre, epsilon: 20)));

    // Another drag before the wait is up starts it over.
    await tester.pump(const Duration(seconds: 5));
    await tester.dragFrom(const Offset(200, 560), const Offset(-60, 0));
    await tester.pump(const Duration(seconds: 5));
    expect(follow, isFalse);

    // Left alone, it goes back to the robot by itself.
    await tester.pump(const Duration(seconds: 4));
    expect(follow, isTrue);
    await tester.pump();
    await tester.pump();
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    await ros.close();
  });
  testWidgets('canvas with a camera keeps its size; fingers zoom and pan it', (
    tester,
  ) async {
    final (ros, mission) = await _missionWithRobotAt(tester, 36, 4);
    final camera = MapViewCamera();
    late MapProjection p;
    var follow = true;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => ListenableBuilder(
            listenable: mission,
            builder: (context, _) => MissionMapCanvas(
              mission: mission,
              bottomInset: 0,
              camera: camera,
              centerOn: follow ? mission.robotPosition : null,
              onUserPan: () => setState(() => follow = false),
              onProjectionPainted: (v) => p = v,
            ),
          ),
        ),
      ),
    );
    Offset robot() => p.project(mission.robotPosition);
    final fitted = p.scale;
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    // The robot crossing the lawn re-centres the map but never resizes it.
    ros.pushPose(2, 28);
    await tester.pump();
    expect(p.scale, fitted);
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    // Two fingers spreading zoom in, about the followed robot.
    final a = await tester.startGesture(const Offset(350, 200));
    final b = await tester.startGesture(const Offset(450, 200));
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await a.moveBy(const Offset(-50, 0));
    await b.moveBy(const Offset(50, 0));
    await tester.pump();
    await a.up();
    await b.up();
    await tester.pump();
    final zoomed = p.scale;
    expect(zoomed, greaterThan(fitted * 1.5));
    expect(follow, isTrue);
    expect(robot(), offsetMoreOrLessEquals(_centre, epsilon: 0.5));

    // The chosen size stays as the robot moves on.
    ros.pushPose(30, 10);
    await tester.pump();
    expect(p.scale, zoomed);

    // One finger pans, which ends following; the map then stays put.
    await tester.dragFrom(const Offset(200, 500), const Offset(120, 0));
    await tester.pump();
    expect(follow, isFalse);
    final left = robot();
    expect(left, isNot(offsetMoreOrLessEquals(_centre, epsilon: 20)));
    await tester.pump(const Duration(seconds: 30));
    expect(follow, isFalse);
    expect(robot(), offsetMoreOrLessEquals(left, epsilon: 0.5));
    expect(p.scale, zoomed);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    await ros.close();
  });

  testWidgets('satellite opens where the shared camera was looking', (
    tester,
  ) async {
    final (ros, mission) = await _missionWithRobotAt(tester, 36, 4);
    // What the schematic map left behind: a spot on the lawn at ~z19.
    final scale = MapViewCamera.scaleOfZoom(19, 25.0);
    final camera = MapViewCamera()
      ..scale = scale
      ..center = const MapPoint(12, 9);
    await tester.pumpWidget(
      MaterialApp(
        home: SatelliteMapView(
          mission: mission,
          anchor: const GeoAnchor(originLat: 25.0, originLon: 121.5),
          camera: camera,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    // Not re-framed on the content: same place, same size, written back.
    expect(camera.scale, closeTo(scale, scale * 0.01));
    expect(camera.center!.x, closeTo(12, 0.05));
    expect(camera.center!.y, closeTo(9, 0.05));

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    await ros.close();
  });

  test('camera size converts to a satellite zoom and back', () {
    for (final zoom in [16.0, 18.5, 22.0]) {
      final scale = MapViewCamera.scaleOfZoom(zoom, 24.9);
      expect(MapViewCamera.zoomOfScale(scale, 24.9), closeTo(zoom, 1e-9));
    }
    // z19 at Taiwan's latitude is about 27 cm per pixel.
    expect(1 / MapViewCamera.scaleOfZoom(19, 25.0), closeTo(0.27, 0.01));
  });
}

/// A live (non-demo) mission with one 40 x 30 m zone and the robot's pose
/// reported at ([x], [y]).
Future<(_PoseRosbridgeFake, MissionMockProvider)> _missionWithRobotAt(
  WidgetTester tester,
  double x,
  double y,
) async {
  SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  final ros = _PoseRosbridgeFake();
  final mission = MissionMockProvider(rosbridge: ros);
  // Let the provider finish connecting (it subscribes to messages then).
  await tester.pump();
  mission.zones = const [
    MissionZone(
      id: 1,
      name: 'A',
      points: [
        MapPoint(0, 0),
        MapPoint(40, 0),
        MapPoint(40, 30),
        MapPoint(0, 30),
      ],
    ),
  ];
  ros.pushPose(x, y);
  await tester.pump();
  expect(mission.shouldShowRobot, isTrue);
  expect(mission.robotPosition.x, x);
  return (ros, mission);
}

class _PoseRosbridgeFake extends RosbridgeService {
  _PoseRosbridgeFake() : super(url: 'ws://robot.test:9090');

  final _messages = StreamController<RosbridgeTopicMessage>.broadcast();

  void pushPose(double x, double y) => _messages.add(
    RosbridgeTopicMessage(
      topic: '/adapter/robot_pose',
      message: {
        'pose': {
          'position': {'x': x, 'y': y, 'z': 0.0},
          'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0},
        },
      },
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
}
