/// Application constants
class AppConstants {
  AppConstants._();

  /// Default map center (Taipei)
  static const double defaultLatitude = 25.0330;
  static const double defaultLongitude = 121.5654;

  /// Default zoom level
  static const double defaultZoom = 17;

  /// ROS API base URL (configurable, using mock data initially)
  static const String rosApiBaseUrl = 'http://localhost:5000';

  /// Status polling interval (milliseconds)
  static const int statusPollIntervalMs = 1000;

  /// Mowing direction range
  static const double directionMin = 0;
  static const double directionMax = 360;

  /// Mowing duration range (minutes)
  static const int durationMin = 10;
  static const int durationMax = 180;

  /// Path spacing range (cm)
  static const double pathSpacingMin = 10;
  static const double pathSpacingMax = 50;

  /// Low battery threshold (%)
  static const double lowBatteryThreshold = 20;

  /// Warning battery threshold (%)
  static const double warningBatteryThreshold = 35;
}
