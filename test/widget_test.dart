import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/main.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/services/weather_service.dart';
import 'package:mower_stdio/widgets/execution_control_sheet.dart';
import 'package:mower_stdio/widgets/map_task_controls.dart';

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
    // No tab bar: home leads into the map, the map has its own way back.
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('首頁'), findsNothing);
    // Manual mode is part of the map page, not a page of its own.
    expect(find.text('手動控制'), findsNothing);
    // The schedule tab was placeholder data only; it must not come back
    // until scheduling is real.
    expect(find.text('排程'), findsNothing);
    expect(find.text('尚未配對機器人'), findsOneWidget);

    // The robot name in the header opens 設定, where 我的機器人 lives.
    await tester.tap(find.text('尚未配對機器人'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('還沒有配對的機器人'), findsOneWidget);
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('等待新鮮 GPS 位置'), findsWidgets);

    // One status card (state, zone, battery, progress), the lawn's area,
    // the weather, and one way into the map.
    expect(find.text('未連線'), findsOneWidget);
    expect(find.text('電量'), findsOneWidget);
    expect(find.text('進度'), findsOneWidget);
    expect(find.text('總面積'), findsOneWidget);
    expect(find.text('進入機器'), findsOneWidget);

    // 進入機器 opens the map. With no zone yet there is nothing to run: no
    // buttons, only the + to add one, and no tabs to pick.
    await tester.ensureVisible(find.text('進入機器'));
    await tester.tap(find.text('進入機器'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(MapTaskControls), findsNothing);
    expect(find.byType(ExecutionControlSheet), findsNothing);
    expect(find.byTooltip('新增物件'), findsOneWidget);
    for (final tab in ['物件', '規劃', '執行', '日誌']) {
      expect(find.text(tab), findsNothing);
    }

    // The map's 設定 button opens the settings page.
    await tester.tap(find.byTooltip('設定'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

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
    await tester.ensureVisible(find.text('進階'));
    await tester.pump();
    await tester.tap(find.text('進階'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Demo 模式'), findsOneWidget);

    // Back to the map: the joysticks are always on it, no manual mode to
    // enter. Not connected, they are locked and say why. The camera stays
    // off until it is turned on.
    await tester.pageBack();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('手動模式'), findsNothing);
    expect(find.text('前進 / 後退'), findsOneWidget);
    expect(find.text('連線中斷'), findsNWidgets(2));
    expect(find.text('前鏡頭'), findsNothing);
    await tester.tap(find.byTooltip('打開前鏡頭'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('前鏡頭'), findsOneWidget);
    await tester.tap(find.byTooltip('關閉前鏡頭'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('前鏡頭'), findsNothing);

    // And home again.
    await tester.tap(find.byTooltip('回主畫面'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('我的割草機'), findsOneWidget);
    expect(find.text('前進 / 後退'), findsNothing);

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
