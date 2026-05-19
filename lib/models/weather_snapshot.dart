class WeatherSnapshot {
  const WeatherSnapshot({
    required this.temperatureC,
    required this.apparentTemperatureC,
    required this.relativeHumidity,
    required this.weatherCode,
    required this.conditionLabel,
    required this.windSpeedKmh,
    required this.observedAt,
    required this.fetchedAt,
  });

  final double temperatureC;
  final double apparentTemperatureC;
  final int relativeHumidity;
  final int weatherCode;
  final String conditionLabel;
  final double windSpeedKmh;
  final DateTime observedAt;
  final DateTime fetchedAt;

  factory WeatherSnapshot.fromOpenMeteo(Map<String, dynamic> json) {
    final current = json['current'];
    if (current is! Map<String, dynamic>) {
      throw const FormatException('Open-Meteo response missing current data');
    }

    final weatherCode = _requiredInt(current['weather_code'], 'weather_code');
    final observedAt =
        DateTime.tryParse(current['time']?.toString() ?? '') ?? DateTime.now();

    return WeatherSnapshot(
      temperatureC: _requiredDouble(
        current['temperature_2m'],
        'temperature_2m',
      ),
      apparentTemperatureC: _requiredDouble(
        current['apparent_temperature'],
        'apparent_temperature',
      ),
      relativeHumidity: _requiredInt(
        current['relative_humidity_2m'],
        'relative_humidity_2m',
      ),
      weatherCode: weatherCode,
      conditionLabel: conditionLabelForCode(weatherCode),
      windSpeedKmh: _requiredDouble(
        current['wind_speed_10m'],
        'wind_speed_10m',
      ),
      observedAt: observedAt,
      fetchedAt: DateTime.now(),
    );
  }

  static String conditionLabelForCode(int code) {
    return switch (code) {
      0 => '晴朗',
      1 => '大致晴朗',
      2 => '局部多雲',
      3 => '陰天',
      45 || 48 => '有霧',
      51 || 53 || 55 => '毛毛雨',
      56 || 57 => '凍毛雨',
      61 || 63 || 65 => '下雨',
      66 || 67 => '凍雨',
      71 || 73 || 75 => '下雪',
      77 => '雪粒',
      80 || 81 || 82 => '陣雨',
      85 || 86 => '陣雪',
      95 => '雷雨',
      96 || 99 => '雷雨冰雹',
      _ => '天氣未知',
    };
  }

  static double _requiredDouble(dynamic value, String field) {
    if (value is num) {
      return value.toDouble();
    }
    throw FormatException('Open-Meteo response missing $field');
  }

  static int _requiredInt(dynamic value, String field) {
    if (value is num) {
      return value.round();
    }
    throw FormatException('Open-Meteo response missing $field');
  }
}
