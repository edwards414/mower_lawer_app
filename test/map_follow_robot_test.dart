import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
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

  testWidgets('satellite follow keeps the robot centred until dragged', (
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

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    await ros.close();
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
