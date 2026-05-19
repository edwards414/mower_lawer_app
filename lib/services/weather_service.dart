import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/weather_snapshot.dart';

class WeatherService {
  WeatherService({http.Client? client, Uri? endpoint})
    : _client = client ?? http.Client(),
      _ownsClient = client == null,
      _endpoint =
          endpoint ?? Uri.parse('https://api.open-meteo.com/v1/forecast');

  final http.Client _client;
  final bool _ownsClient;
  final Uri _endpoint;

  Future<WeatherSnapshot> fetchCurrent({
    required double latitude,
    required double longitude,
  }) async {
    final uri = _endpoint.replace(
      queryParameters: {
        'latitude': latitude.toStringAsFixed(5),
        'longitude': longitude.toStringAsFixed(5),
        'current':
            'temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m',
        'timezone': 'auto',
      },
    );

    final response = await _client.get(uri).timeout(const Duration(seconds: 8));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw WeatherException('天氣 API 回應 ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Open-Meteo response is not an object');
    }
    return WeatherSnapshot.fromOpenMeteo(decoded);
  }

  void dispose() {
    if (_ownsClient) {
      _client.close();
    }
  }
}

class WeatherException implements Exception {
  const WeatherException(this.message);

  final String message;

  @override
  String toString() => message;
}
