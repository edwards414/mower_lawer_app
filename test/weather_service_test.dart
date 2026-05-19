import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/services/weather_service.dart';

void main() {
  test('fetchCurrent parses Open-Meteo current weather', () async {
    final service = WeatherService(
      client: MockClient((request) async {
        expect(request.url.host, 'api.open-meteo.com');
        expect(request.url.path, '/v1/forecast');
        expect(
          request.url.queryParameters['current'],
          contains('relative_humidity_2m'),
        );
        expect(request.url.queryParameters['timezone'], 'auto');

        return http.Response(
          jsonEncode({
            'current': {
              'time': '2026-05-20T09:45',
              'temperature_2m': 27.4,
              'apparent_temperature': 29.1,
              'relative_humidity_2m': 72,
              'weather_code': 61,
              'wind_speed_10m': 8.3,
            },
          }),
          200,
        );
      }),
    );

    final snapshot = await service.fetchCurrent(
      latitude: 25.033,
      longitude: 121.5654,
    );

    expect(snapshot.temperatureC, 27.4);
    expect(snapshot.apparentTemperatureC, 29.1);
    expect(snapshot.relativeHumidity, 72);
    expect(snapshot.weatherCode, 61);
    expect(snapshot.conditionLabel, '下雨');
    expect(snapshot.windSpeedKmh, 8.3);
  });

  test('conditionLabelForCode maps common weather states', () {
    expect(WeatherSnapshot.conditionLabelForCode(0), '晴朗');
    expect(WeatherSnapshot.conditionLabelForCode(2), '局部多雲');
    expect(WeatherSnapshot.conditionLabelForCode(95), '雷雨');
    expect(WeatherSnapshot.conditionLabelForCode(999), '天氣未知');
  });
}
