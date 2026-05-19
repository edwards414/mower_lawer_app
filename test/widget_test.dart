import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/main.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/services/weather_service.dart';

void main() {
  testWidgets('shows self check then dashboard shell and map tab', (
    tester,
  ) async {
    await tester.pumpWidget(MowerApp(weatherService: _FailingWeatherService()));

    expect(find.text('任務自檢'), findsOneWidget);
    expect(find.text('進入任務地圖'), findsOneWidget);

    await tester.tap(find.text('進入任務地圖'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('我的割草機'), findsOneWidget);
    expect(find.text('首頁'), findsOneWidget);
    expect(find.text('地圖'), findsOneWidget);
    expect(find.text('手動控制'), findsOneWidget);
    expect(find.text('排程'), findsOneWidget);
    expect(find.text('更多'), findsOneWidget);
    expect(find.text('天氣暫不可用'), findsWidgets);

    await tester.tap(find.byIcon(Icons.map_outlined));
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('物件'), findsOneWidget);
    expect(find.text('記錄'), findsOneWidget);
    expect(find.text('規劃'), findsOneWidget);
    expect(find.text('執行'), findsOneWidget);
    expect(find.text('日誌'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.sports_esports_outlined).first);
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('前鏡頭'), findsOneWidget);
    expect(find.text('停止'), findsOneWidget);
    expect(find.text('rosbridge 未連線'), findsOneWidget);
    expect(find.text('首頁'), findsOneWidget);

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
