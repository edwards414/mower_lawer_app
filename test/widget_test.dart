import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:mower_stdio/utils/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/main.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/services/weather_service.dart';
import 'package:mower_stdio/widgets/execution_control_sheet.dart';
import 'package:mower_stdio/widgets/mission_mode_bar.dart';

void main() {
  testWidgets('shows self check then dashboard shell and map tab', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    await tester.pumpWidget(MowerApp(weatherService: _FailingWeatherService()));

    expect(find.text('任務自檢'), findsOneWidget);
    expect(find.text('以檢視模式進入'), findsOneWidget);
    expect(find.text('未收到新鮮 heartbeat'), findsOneWidget);

    await tester.tap(find.text('以檢視模式進入'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('我的割草機'), findsOneWidget);
    expect(find.text('首頁'), findsOneWidget);
    expect(find.text('地圖'), findsOneWidget);
    // Manual mode is part of the map page, not a tab of its own.
    expect(find.text('手動控制'), findsNothing);
    expect(find.text('設定'), findsOneWidget);
    // The schedule tab was placeholder data only; it must not come back
    // until scheduling is real.
    expect(find.text('排程'), findsNothing);
    expect(find.text('尚未配對機器人'), findsOneWidget);

    // The robot name in the header opens 我的機器人, which lives on the 設定
    // tab (the one settings page), not on a page of its own.
    await tester.tap(find.text('尚未配對機器人'));
    await tester.pump();
    expect(find.text('還沒有配對的機器人'), findsOneWidget);
    await tester.tap(find.byIcon(AppIcons.house));
    await tester.pump();
    expect(find.text('等待新鮮 GPS 位置'), findsWidgets);

    // One main card: status, battery, mission and the way into the map.
    expect(find.text('前往地圖執行任務'), findsOneWidget);
    expect(find.text('電量'), findsNothing);

    // The main button opens the map on its run panel.
    await tester.ensureVisible(find.text('前往地圖執行任務'));
    await tester.tap(find.text('前往地圖執行任務'));
    await tester.pump(const Duration(milliseconds: 300));
    // It lands on the run panel itself, not just any map panel.
    expect(find.byType(ExecutionControlSheet), findsOneWidget);

    // Even if the operator collapsed the panel earlier, the button reveals it.
    await tester.tap(find.byType(AnimatedRotation));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ExecutionControlSheet), findsNothing);
    await tester.tap(find.byIcon(AppIcons.house));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('前往地圖執行任務'));
    await tester.tap(find.text('前往地圖執行任務'));
    await tester.pump();
    // The panel animates open; wait for it to be tall enough for its content.
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ExecutionControlSheet), findsOneWidget);

    expect(find.text('物件'), findsOneWidget);
    expect(find.text('規劃'), findsOneWidget);
    expect(find.text('執行'), findsOneWidget);
    expect(find.text('日誌'), findsOneWidget);

    await tester.tap(find.text('設定'));
    await tester.pump(const Duration(milliseconds: 100));

    // Layers live on the map only. Robot settings are right on this page;
    // only Demo / data source are folded under 進階.
    expect(find.text('我的機器人'), findsOneWidget);
    expect(find.text('地圖圖層'), findsNothing);
    expect(find.text('連線設定（進階）'), findsNothing);

    // Unpaired: the one 直連 IP field is the manual development connection,
    // right on this page (the old 進階 sheet and LAN/直連 dialogs are gone).
    expect(find.widgetWithText(TextField, '直連 IP'), findsOneWidget);
    expect(find.text('手動區網 IP'), findsNothing);

    // 進階 sits below the fold of the 800x600 test surface.
    await tester.scrollUntilVisible(
      find.text('進階'),
      200,
      scrollable: find
          .ancestor(of: find.text('我的機器人'), matching: find.byType(Scrollable))
          .first,
    );
    // Built does not mean on screen: it can still sit under the tab bar.
    await tester.ensureVisible(find.text('進階'));
    await tester.pump();
    await tester.tap(find.text('進階'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Demo 模式'), findsOneWidget);

    // Manual mode lives on the map page: one tap puts the joysticks and the
    // camera over the same map, and the panel and tab bar step aside.
    await tester.tap(find.text('地圖'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NavigationBar), findsOneWidget);
    await tester.tap(find.text('手動模式'));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('前鏡頭'), findsOneWidget);
    expect(find.text('機器人未就緒'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.byType(ExecutionControlSheet), findsNothing);
    expect(find.byType(MissionModeBar), findsNothing);

    // ✕ brings the map page back as it was.
    await tester.tap(find.byTooltip('退出手動模式'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('前鏡頭'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(MissionModeBar), findsOneWidget);

    // Back leaves manual mode before it leaves the app.
    await tester.tap(find.text('手動模式'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(NavigationBar), findsNothing);
    // ignore: invalid_use_of_protected_member
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('前鏡頭'), findsNothing);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

class _FailingWeatherService extends WeatherService {
  _FailingWeatherService()
    : super(client: MockClient((_) async => http.Response('{}', 500)));

  @override
  Future<WeatherSnapshot> fetchCurrent({
    required double latitude,
    required double longitude,
  }) async {
    throw const WeatherException('offline');
  }
}
