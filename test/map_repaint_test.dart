import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/geo_anchor.dart';
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/models/robot_fleet.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/mission_map_canvas.dart';
import 'package:mower_stdio/widgets/satellite_map_view.dart';

/// The map is redrawn when the mission changes, not on a timer: an idle map
/// costs nothing, and moving a robot only re-projects what moved.
void main() {
  testWidgets('an idle map does not repaint on its own', (tester) async {
    final mission = await _mission(tester);
    var paints = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: MissionMapCanvas(
          mission: mission,
          bottomInset: 0,
          onProjectionPainted: (_) => paints++,
        ),
      ),
    );
    final first = paints;
    expect(first, greaterThan(0));

    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(paints, first, reason: 'nothing changed, so nothing is redrawn');

    // A mission change redraws it, with no rebuild from above.
    mission.poke();
    await tester.pump();
    expect(paints, first + 1);

    await _finish(tester, mission);
  });

  testWidgets('the selected robot pulses; deselecting stops it', (
    tester,
  ) async {
    final mission = await _mission(tester);
    var paints = 0;
    Widget map({int? selected}) => MaterialApp(
      home: MissionMapCanvas(
        mission: mission,
        bottomInset: 0,
        robots: const [_robot],
        selectedRobotId: selected,
        onProjectionPainted: (_) => paints++,
      ),
    );

    await tester.pumpWidget(map(selected: _robot.id));
    final start = paints;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(paints - start, greaterThanOrEqualTo(8));

    await tester.pumpWidget(map());
    await tester.pump();
    final stopped = paints;
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(paints, stopped);

    await _finish(tester, mission);
  });

  testWidgets('a pose tick leaves the satellite layers as they were', (
    tester,
  ) async {
    final mission = await _mission(tester);
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
    mission.coverageRows = const [
      [MapPoint(2, 2), MapPoint(38, 2)],
      [MapPoint(2, 5), MapPoint(38, 5)],
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: mission,
          builder: (context, _) => SatelliteMapView(
            mission: mission,
            anchor: const GeoAnchor(originLat: 25.0, originLon: 121.5),
          ),
        ),
      ),
    );
    await tester.pump();
    // flutter_map drops a layer's projection and simplification caches when
    // the layer *widget* is replaced, so what must hold still is the widget.
    PolylineLayer coverage() =>
        tester.widget<PolylineLayer>(find.byKey(const ValueKey('coverage')));
    PolygonLayer zones() =>
        tester.widget<PolygonLayer>(find.byKey(const ValueKey('zones')));
    final coverageBefore = coverage();
    final zonesBefore = zones();
    expect(coverageBefore.polylines, hasLength(2));

    // The robot moves: the same layers, handed back untouched.
    mission.robotPosition = const MapPoint(12, 9);
    mission.poke();
    await tester.pump();
    expect(identical(coverage(), coverageBefore), isTrue);
    expect(identical(zones(), zonesBefore), isTrue);

    // A zone summary swaps in equal copies of the zones (twice a second).
    mission.zones = [
      for (final z in mission.zones)
        MissionZone(
          id: z.id,
          name: z.name,
          points: z.points,
          hasCoveragePath: true,
        ),
    ];
    mission.poke();
    await tester.pump();
    expect(identical(zones(), zonesBefore), isTrue);
    expect(identical(coverage(), coverageBefore), isTrue);

    // New coverage replaces only the coverage layer.
    mission.coverageRows = const [
      [MapPoint(2, 8), MapPoint(38, 8)],
    ];
    mission.poke();
    await tester.pump();
    expect(coverage().polylines, hasLength(1));
    expect(identical(zones(), zonesBefore), isTrue);

    // A moved zone replaces only the zone layer.
    final coverageNow = coverage();
    mission.zones = const [
      MissionZone(
        id: 1,
        name: 'A',
        points: [MapPoint(0, 0), MapPoint(20, 0), MapPoint(20, 10)],
      ),
    ];
    mission.poke();
    await tester.pump();
    expect(identical(zones(), zonesBefore), isFalse);
    expect(identical(coverage(), coverageNow), isTrue);

    await _finish(tester, mission);
  });
}

const _robot = RobotAgent(
  id: 1,
  name: 'A',
  color: Colors.blue,
  batteryPercent: 80,
  progress: 0,
  workStatus: RobotWorkStatus.idle,
  assignedRowIndices: [],
  position: MapPoint(1, 1),
);

Future<_Mission> _mission(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  final mission = _Mission();
  // Let the provider read its saved data-source preference.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  return mission;
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
