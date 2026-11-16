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
import 'package:mower_stdio/widgets/mission_map_canvas.dart';

/// Deleting a map object and tapping one out are done on the map itself: an
/// object picked there offers its actions on the spot, and every kind can be
/// drawn point by point.
void main() {
  testWidgets('an object tapped on the map can be deleted right there', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    expect(find.text('已選取工作區'), findsNothing);

    await tester.tapAt(h.screen(const MapPoint(2, 2)));
    await tester.pump();

    expect(h.mission.isObjectSelected('zone', 1), isTrue);
    expect(find.text('已選取工作區'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pump();
    expect(find.text('刪除工作區「前院」？'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.mission.zones, isEmpty);
    expect(find.text('已刪除「前院」'), findsOneWidget);
    expect(find.text('已選取工作區'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('cancelling the confirmation deletes nothing; ✕ lets go', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    await tester.tapAt(h.screen(const MapPoint(2, 2)));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(h.mission.zones, hasLength(1));
    expect(h.mission.isObjectSelected('zone', 1), isTrue);

    await tester.tap(find.byTooltip('取消選取'));
    await tester.pump();
    expect(h.mission.selectedObjectKind, isNull);
    expect(find.text('已選取工作區'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('調整 on the selected object opens vertex editing', (tester) async {
    final h = await _Harness.pump(tester);
    await tester.tapAt(h.screen(const MapPoint(2, 2)));
    await tester.pump();

    await tester.tap(find.widgetWithText(TextButton, '調整'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.mission.editVertexMode, isTrue);
    expect(h.mission.editKind, 'zone');
    expect(find.text('已選取工作區'), findsNothing);

    await h.dispose(tester);
  });

  testWidgets('a channel is tapped out from the add sheet', (tester) async {
    final h = await _Harness.pump(tester);
    await tester.tap(find.byTooltip('新增物件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('在地圖上點出'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('draw-channel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(h.mission.drawMode, isTrue);
    expect(find.text('畫通道 · 0 點'), findsOneWidget);
    expect(find.text('點地圖放第一個點'), findsOneWidget);
    final save = find.widgetWithText(FilledButton, '完成儲存');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.tapAt(const Offset(120, 300));
    await tester.pump();
    expect(find.text('再點 1 點'), findsOneWidget);
    await tester.tapAt(const Offset(260, 340));
    await tester.pump();
    expect(find.text('畫通道 · 2 點'), findsOneWidget);

    await tester.tap(save);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.mission.drawMode, isFalse);
    expect(h.mission.channels, hasLength(1));
    expect(h.mission.channels.single.points, hasLength(2));
    expect(find.text('已新增通道'), findsOneWidget);

    await h.dispose(tester);
  });

  testWidgets('tapping the start point closes a drawn area; drag fixes one', (
    tester,
  ) async {
    final h = await _Harness.pump(tester);
    expect(h.mission.startDraw('risk'), isNull);
    await tester.pump(const Duration(milliseconds: 400));

    const a = Offset(110, 260);
    const b = Offset(250, 260);
    const c = Offset(250, 380);
    for (final p in [a, b, c]) {
      await tester.tapAt(p);
      await tester.pump();
    }
    expect(find.text('畫禁入區 · 3 點'), findsOneWidget);
    expect(find.text('點起點閉合，或拖曳點修正'), findsOneWidget);

    // Dragging a point moves it instead of adding one.
    final before = h.mission.draftPolygon[2];
    await tester.dragFrom(c, const Offset(0, 60));
    await tester.pump();
    expect(h.mission.draftPolygon, hasLength(3));
    expect(h.mission.draftPolygon[2], isNot(before));

    await tester.tapAt(a);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(h.mission.drawMode, isFalse);
    expect(h.mission.riskZones, hasLength(1));
    expect(h.mission.riskZones.single.points, hasLength(3));

    await h.dispose(tester);
  });
}

class _Harness {
  _Harness(this.mission, this.fleet, this.phone, this.recorder);

  final MissionMockProvider mission;
  final RobotFleetProvider fleet;
  final PhoneLocationProvider phone;
  final RecorderProvider recorder;

  /// The map page in demo mode, holding exactly one zone (id 1, 「前院」).
  static Future<_Harness> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
    final ros = _QuietRosbridge();
    final mission = MissionMockProvider(rosbridge: _QuietRosbridge());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(mission.mockDataEnabled, isTrue);
    mission
      ..zones = const [
        MissionZone(
          id: 1,
          name: '前院',
          points: [
            MapPoint(0, 0),
            MapPoint(4, 0),
            MapPoint(4, 4),
            MapPoint(0, 4),
          ],
        ),
      ]
      ..riskZones = const []
      ..channels = const [];
    final h = _Harness(
      mission,
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
        child: const MaterialApp(home: MissionMapScreen()),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    return h;
  }

  /// Where a map point is on screen.
  Offset screen(MapPoint world) {
    final canvas =
        find.byType(MissionMapCanvas).evaluate().single as StatefulElement;
    return (canvas.state as MissionMapCanvasState).lastProjection!.project(
      world,
    );
  }

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    recorder.dispose();
    fleet.dispose();
    phone.dispose();
    mission.dispose();
  }
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
