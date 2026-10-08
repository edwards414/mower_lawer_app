import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/breathing_marker.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';

/// Driving a boundary over the satellite map: the path being recorded and the
/// way the robot faces are drawn, as the schematic map draws them.
void main() {
  const trail = [
    MapPoint(0, 0),
    MapPoint(3, 0),
    MapPoint(3, 2),
    MapPoint(0, 2),
  ];
  const trailKey = ValueKey('record-trail');

  testWidgets('a zone recording is a closing polygon with its two ends', (
    tester,
  ) async {
    final mission = await _mission(tester);
    mission.recordingType = RecordObjectType.zone;
    mission.recordTrail = trail;
    await _pump(tester, mission);

    final polygon = tester.widget<PolygonLayer>(find.byKey(trailKey));
    expect(polygon.polygons.single.points, hasLength(4));
    expect(find.byType(PolylineLayer), findsNothing);
    // Start anchor (white, ringed) and the live head.
    final ends = tester
        .widget<CircleLayer>(find.byKey(const ValueKey('record-ends')))
        .circles;
    expect(ends, hasLength(2));
    expect(ends.first.color, Colors.white);
    expect(ends.first.point, polygon.polygons.single.points.first);
    expect(ends.last.point, polygon.polygons.single.points.last);

    await _finish(tester, mission);
  });

  testWidgets('a channel (or a young trail) is a line, not a polygon', (
    tester,
  ) async {
    final mission = await _mission(tester);
    mission.recordingType = RecordObjectType.channel;
    mission.recordTrail = trail;
    await _pump(tester, mission);
    expect(
      tester
          .widget<PolylineLayer>(find.byKey(trailKey))
          .polylines
          .single
          .points,
      hasLength(4),
    );
    expect(find.byType(PolygonLayer), findsNothing);

    // Two points of a zone are not an area yet.
    mission.recordingType = RecordObjectType.risk;
    mission.recordTrail = trail.take(2).toList();
    mission.poke();
    await tester.pump();
    expect(find.byType(PolylineLayer), findsOneWidget);
    expect(find.byType(PolygonLayer), findsNothing);

    // Nothing recorded yet: just the start anchor.
    mission.recordTrail = trail.take(1).toList();
    mission.poke();
    await tester.pump();
    expect(find.byKey(trailKey), findsNothing);
    expect(find.byKey(const ValueKey('record-ends')), findsOneWidget);

    await _finish(tester, mission);
  });

  testWidgets('nothing is drawn when nothing is being recorded', (
    tester,
  ) async {
    final mission = await _mission(tester);
    mission.recordTrail = trail; // left over: not recording
    await _pump(tester, mission);
    expect(find.byKey(trailKey), findsNothing);
    expect(find.byKey(const ValueKey('record-ends')), findsNothing);

    await _finish(tester, mission);
  });

  group('heading', () {
    double wedge(WidgetTester tester) {
      final m = tester
          .widget<Transform>(find.byKey(const ValueKey('robot-heading')))
          .transform;
      return math.atan2(m.entry(1, 0), m.entry(0, 0));
    }

    testWidgets('follows the robot across the map-frame bearing', (
      tester,
    ) async {
      final mission = await _mission(tester);
      // Map +X points north: a robot facing +X faces up the screen.
      mission.robotHeadingRad = 0;
      await _pump(tester, mission);
      expect(wedge(tester), closeTo(0, 1e-9));

      // Turned a quarter turn left in the map frame (ROS: counter-clockwise).
      // Map +Y is west here, so it now faces left on the north-up screen.
      mission.robotHeadingRad = math.pi / 2;
      mission.poke();
      await tester.pump();
      expect(wedge(tester), closeTo(-math.pi / 2, 1e-9));

      await _finish(tester, mission);
    });

    testWidgets('accounts for the frame being rotated against north', (
      tester,
    ) async {
      final mission = await _mission(tester);
      // Map +X points east (bearing 90° clockwise from north).
      mission.robotHeadingRad = 0;
      await _pump(
        tester,
        mission,
        anchor: const GeoAnchor(
          originLat: 25.0,
          originLon: 121.5,
          bearingRad: math.pi / 2,
        ),
      );
      expect(wedge(tester), closeTo(math.pi / 2, 1e-9));

      await _finish(tester, mission);
    });
  });

  testWidgets('a still marker schedules no frames; a pulsing one does', (
    tester,
  ) async {
    Widget marker(bool animate) =>
        MaterialApp(home: BreathingMarker(animate: animate));

    await tester.pumpWidget(marker(false));
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(marker(true));
    expect(tester.hasRunningAnimations, isTrue);

    // Driving: the pulse stops, and with it the map's per-frame repaint.
    await tester.pumpWidget(marker(false));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<_Mission> _mission(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  final mission = _Mission();
  // Let the provider read its saved data-source preference.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  return mission;
}

Future<void> _pump(
  WidgetTester tester,
  _Mission mission, {
  GeoAnchor anchor = const GeoAnchor(originLat: 25.0, originLon: 121.5),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: mission,
        builder: (context, _) => SatelliteMapView(
          mission: mission,
          anchor: anchor,
          animateMarker: false,
        ),
      ),
    ),
  );
  await tester.pump();
}

/// The provider owns a periodic timer; end it before the framework checks for
/// pending timers.
Future<void> _finish(WidgetTester tester, _Mission mission) async {
  await tester.pumpWidget(const SizedBox.shrink());
  mission.dispose();
}

class _Mission extends MissionMockProvider {
  _Mission() : super(rosbridge: _QuietRosbridge());

  void poke() => notifyListeners();
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
}
