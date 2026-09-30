import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:mower_stdio/utils/app_icons.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/main.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/services/weather_service.dart';

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
    expect(find.text('手動控制'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    // The schedule tab was placeholder data only; it must not come back
    // until scheduling is real.
    expect(find.text('排程'), findsNothing);
    expect(find.text('尚未配對機器人'), findsOneWidget);

    // The robot name in the header opens 我的機器人.
    await tester.tap(find.text('尚未配對機器人'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('還沒有配對的機器人'), findsOneWidget);
    await tester.pageBack();
    await tester.pump();
    // The default Android page transition is longer than 400 ms; wait it out
    // so the popped route stops covering the bottom navigation.
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('等待新鮮 GPS 位置'), findsWidgets);

    // One main card: status, battery, mission and the way into the map.
    expect(find.text('前往地圖執行任務'), findsOneWidget);
    expect(find.text('電量'), findsNothing);

    // The main button opens the map on its run panel.
    await tester.ensureVisible(find.text('前往地圖執行任務'));
    await tester.tap(find.text('前往地圖執行任務'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('物件'), findsOneWidget);

    expect(find.text('物件'), findsOneWidget);
    expect(find.text('規劃'), findsOneWidget);
    expect(find.text('執行'), findsOneWidget);
    expect(find.text('日誌'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.ellipsis));
    await tester.pump(const Duration(milliseconds: 100));

    // Layers live on the map only; connection tools are folded under 進階.
    expect(find.text('我的機器人'), findsOneWidget);
    expect(find.text('進階'), findsOneWidget);
    expect(find.text('地圖圖層'), findsNothing);
    expect(find.text('連線設定（進階）'), findsNothing);

    // Unpaired: the manual-IP row is honest about having no value.
    // The section sits below the fold of the 800x600 test surface.
    await tester.ensureVisible(find.text('進階'));
    await tester.pump();
    await tester.tap(find.text('進階'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('手動區網 IP'), findsOneWidget);
    expect(find.text('未設定'), findsOneWidget);
    expect(find.text('Demo 模式'), findsOneWidget);

    await tester.tap(find.text('手動控制').last);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('前鏡頭'), findsOneWidget);
    expect(find.text('機器人未就緒'), findsOneWidget);

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
