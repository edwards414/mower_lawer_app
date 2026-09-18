// On-device smoke test for the front camera: pair with a real robot, open
// the manual page and report what the WHEP camera view does.
//
//   flutter test integration_test/camera_smoke_test.dart -d <simulator> \
//     --dart-define=PAIR_URL='https://mower.fxrbindi.com/pair?v=1&id=MW-…&s=…&l=…'
//
// It never asserts on video (the robot may be off); it prints the route,
// the WHEP URL and the camera state so a person can read the outcome.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';

import 'package:mower_stdio/main.dart' as app;
import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/providers/robot_registry.dart';

const _pairUrl = String.fromEnvironment('PAIR_URL');
const _watchSeconds = int.fromEnvironment('WATCH_SECONDS', defaultValue: 25);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('front camera on the manual page', (tester) async {
    expect(_pairUrl, isNotEmpty, reason: 'pass --dart-define=PAIR_URL=…');
    app.main();
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle(const Duration(milliseconds: 200));

    // Providers live under MowerApp; any element below them will do.
    final context = tester.element(find.byType(MaterialApp).first);
    final registry = Provider.of<RobotRegistry>(context, listen: false);
    final mission = Provider.of<MissionMockProvider>(context, listen: false);
    while (!registry.loaded) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    await registry.pairFromText(_pairUrl);
    for (var i = 0; i < 30 && registry.activeRoute.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 200));
    }
    debugPrint('[camera-smoke] route=${registry.activeRoute} '
        'rosbridge=${mission.rosbridgeUrl} whepUrl=${mission.whepUrl(CameraFeed.front)}');

    // The self-check page comes first; its bottom button ("進入任務地圖" /
    // "以檢視模式進入" / "進入 Demo 任務地圖") leads to the dashboard.
    for (var i = 0; i < 20 && find.byType(NavigationBar).evaluate().isEmpty; i++) {
      final enter = find.byWidgetPredicate(
        (w) => w is Text && (w.data ?? '').contains('進入'),
      );
      if (enter.evaluate().isNotEmpty) {
        debugPrint('[camera-smoke] self-check page: tapping "${(enter.evaluate().first.widget as Text).data}"');
        await tester.tap(enter.first);
        await tester.pump(const Duration(seconds: 1));
      }
      await tester.pump(const Duration(milliseconds: 500));
    }
    if (find.byType(NavigationBar).evaluate().isEmpty) {
      final texts = find.byType(Text).evaluate()
          .map((e) => (e.widget as Text).data)
          .whereType<String>()
          .take(12)
          .toList();
      debugPrint('[camera-smoke] no NavigationBar; visible texts: $texts');
      return;
    }
    await tester.tap(find.byType(NavigationDestination).at(2));
    await tester.pump(const Duration(seconds: 1));

    String? last;
    for (var i = 0; i < _watchSeconds; i++) {
      await tester.pump(const Duration(seconds: 1));
      final video = find.byType(RTCVideoView).evaluate().isNotEmpty;
      final texts = ['影像連線中…', '影像連線失敗', '等待影像串流', '尚未設定機器人 IP', '遠端連線暫不支援影像，請在同一個 Wi-Fi 下使用']
          .where((t) => find.text(t).evaluate().isNotEmpty)
          .toList();
      final now = 'video=$video placeholder=$texts';
      if (now != last) {
        debugPrint('[camera-smoke] t=${i + 1}s $now');
        last = now;
      }
      if (video) break;
    }
    debugPrint('[camera-smoke] done: $last');
  });
}
