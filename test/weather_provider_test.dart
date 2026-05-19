import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mower_stdio/models/weather_snapshot.dart';
import 'package:mower_stdio/providers/weather_provider.dart';
import 'package:mower_stdio/services/weather_service.dart';

void main() {
  test('keeps cached weather when a later refresh fails', () async {
    final firstSnapshot = WeatherSnapshot(
      temperatureC: 26,
      apparentTemperatureC: 28,
      relativeHumidity: 74,
      weatherCode: 2,
      conditionLabel: WeatherSnapshot.conditionLabelForCode(2),
      windSpeedKmh: 6.5,
      observedAt: DateTime(2026, 5, 20, 9, 30),
      fetchedAt: DateTime(2026, 5, 20, 9, 31),
    );
    final provider = WeatherProvider(
      service: _QueuedWeatherService([
        firstSnapshot,
        const WeatherException('offline'),
      ]),
    );

    await provider.refresh();

    expect(provider.snapshot, same(firstSnapshot));
    expect(provider.errorMessage, isNull);

    await provider.refresh();

    expect(provider.snapshot, same(firstSnapshot));
    expect(provider.errorMessage, '天氣更新失敗，顯示最後資料');

    provider.dispose();
  });
}

class _QueuedWeatherService extends WeatherService {
  _QueuedWeatherService(this._responses)
    : super(client: MockClient((_) async => http.Response('{}', 500)));

  final List<Object> _responses;

  @override
  Future<WeatherSnapshot> fetchCurrent({
    required double latitude,
    required double longitude,
  }) async {
    final next = _responses.removeAt(0);
    if (next is WeatherSnapshot) {
      return next;
    }
    throw next;
  }
}
