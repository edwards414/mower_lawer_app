// A watchable walk through the map's gestures on a simulator, in demo mode
// (nothing is sent to a robot):
//
//   flutter test integration_test/map_gestures_demo_test.dart -d <simulator>
//
// It zooms and pans the map, comes back to the mower, picks a zone, taps out
// a channel and deletes it again, pausing between steps so a person can
// follow. The assertions are the same things the eye should see.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/main.dart' as app;
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/widgets/mission_map_canvas.dart';

const _beat = Duration(milliseconds: 1600);

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('map gestures, step by step', (tester) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('mock_data_enabled', true);
    app.main();
    await tester.pump(const Duration(seconds: 2));

    // Self-check, then the home page's 進入機器, lead to the map.
    Future<void> tapText(String part) async {
      final found = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains(part),
      );
      for (var i = 0; i < 20 && found.evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 250));
      }
      await tester.tap(found.first);
      await tester.pump(_beat);
    }

    await tapText('進入');
    await tapText('進入機器');
    for (var i = 0; i < 20 && find.byType(MissionMapCanvas).evaluate().isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    await tester.pump(_beat);

    final mission = Provider.of<MissionMockProvider>(
      tester.element(find.byType(MissionMapCanvas)),
      listen: false,
    );
    MapProjection view() => tester
        .state<MissionMapCanvasState>(find.byType(MissionMapCanvas))
        .lastProjection!;
    final size = tester.getSize(find.byType(MissionMapCanvas));
    final mid = Offset(size.width / 2, size.height * 0.4);

    // Two fingers moving apart (or together) along a line through [mid].
    Future<void> pinch(double from, double to) async {
      final a = await tester.startGesture(mid - Offset(from, 0));
      final b = await tester.startGesture(mid + Offset(from, 0));
      const steps = 24;
      for (var i = 0; i < steps; i++) {
        final d = Offset((to - from) / steps, 0);
        await a.moveBy(-d);
        await b.moveBy(d);
        await tester.pump(const Duration(milliseconds: 30));
      }
      await a.up();
      await b.up();
      await tester.pump(_beat);
    }

    // 1. Zoom in. The size then stays, though the demo mower keeps moving.
    final fitted = view().scale;
    await pinch(40, 130);
    final zoomed = view().scale;
    expect(zoomed, greaterThan(fitted * 1.5));
    await tester.pump(const Duration(seconds: 3));
    expect(view().scale, zoomed);

    // 2. Zoom back out.
    await pinch(130, 60);
    expect(view().scale, lessThan(zoomed));
    final chosen = view().scale;

    // 3. Drag the map away: it stays there, and 回到割草機 shows.
    final drag = await tester.startGesture(mid);
    for (var i = 0; i < 20; i++) {
      await drag.moveBy(const Offset(6, 5));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await drag.up();
    await tester.pump(_beat);
    expect(find.byTooltip('回到割草機'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    expect(find.byTooltip('回到割草機'), findsOneWidget);

    // 4. Back to the mower, at the same size.
    await tester.tap(find.byTooltip('回到割草機'));
    await tester.pump(_beat);
    expect(find.byTooltip('回到割草機'), findsNothing);
    expect(view().scale, chosen);

    // 5. Pick a zone on the map: its actions come up; ✕ puts them away.
    final zone = mission.zones.first;
    final inside = MapPoint(
      zone.points.map((p) => p.x).reduce((a, b) => a + b) / zone.points.length,
      zone.points.map((p) => p.y).reduce((a, b) => a + b) / zone.points.length,
    );
    await tester.tapAt(view().project(inside));
    await tester.pump(_beat);
    expect(find.text('已選取工作區'), findsOneWidget);
    await tester.pump(_beat);
    await tester.tap(find.byTooltip('取消選取'));
    await tester.pump(_beat);

    // 6. Tap out a channel. The map does not move when drawing starts.
    final channels = mission.channels.length;
    await tester.tap(find.byTooltip('新增物件'));
    await tester.pump(_beat);
    final before = view().scale;
    await tester.tap(find.byKey(const ValueKey('draw-channel')));
    await tester.pump(_beat);
    expect(view().scale, before);
    final taps = [
      mid + const Offset(-110, -60),
      mid + const Offset(-20, -100),
      mid + const Offset(90, -50),
    ];
    for (final p in taps) {
      await tester.tapAt(p);
      await tester.pump(const Duration(milliseconds: 900));
    }
    // A point put in the wrong place is dragged to the right one.
    final fix = await tester.startGesture(taps[1]);
    for (var i = 0; i < 15; i++) {
      await fix.moveBy(const Offset(0, 4));
      await tester.pump(const Duration(milliseconds: 30));
    }
    await fix.up();
    await tester.pump(_beat);
    await tester.tap(find.widgetWithText(FilledButton, '完成儲存'));
    await tester.pump(_beat);
    expect(mission.channels.length, channels + 1);
    await tester.pump(_beat);

    // 7. Pick the new channel where it was drawn, and delete it there.
    await tester.tapAt(taps.first);
    await tester.pump(_beat);
    expect(find.text('已選取通道'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '刪除'));
    await tester.pump(_beat);
    await tester.tap(find.widgetWithText(FilledButton, '刪除'));
    await tester.pump(_beat);
    expect(mission.channels.length, channels);
    await tester.pump(const Duration(seconds: 2));
  });
}
