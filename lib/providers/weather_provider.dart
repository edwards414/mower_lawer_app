import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/mower_status.dart';
import '../models/weather_snapshot.dart';
import '../services/weather_service.dart';
import '../utils/constants.dart';

class WeatherProvider extends ChangeNotifier {
  WeatherProvider({required WeatherService service}) : _service = service;

  static const refreshInterval = Duration(minutes: 15);
  static const _locationRefreshThresholdDegrees = 0.001;

  final WeatherService _service;

  Timer? _timer;
  WeatherSnapshot? _snapshot;
  bool _isLoading = false;
  String? _errorMessage;
  bool _disposed = false;

  double _latitude = AppConstants.defaultLatitude;
  double _longitude = AppConstants.defaultLongitude;
  double? _lastFetchLatitude;
  double? _lastFetchLongitude;
  DateTime? _lastFetchedAt;

  WeatherSnapshot? get snapshot => _snapshot;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void updateFromMowerStatus(MowerStatus? status) {
    _latitude = status?.latitude ?? AppConstants.defaultLatitude;
    _longitude = status?.longitude ?? AppConstants.defaultLongitude;
    _timer ??= Timer.periodic(refreshInterval, (_) => unawaited(refresh()));

    if (_isLoading) {
      return;
    }
    if (_needsRefresh()) {
      scheduleMicrotask(() {
        if (!_disposed) {
          unawaited(refresh());
        }
      });
    }
  }

  Future<void> refresh() async {
    if (_isLoading) {
      return;
    }

    final latitude = _latitude;
    final longitude = _longitude;
    _isLoading = true;
    if (_snapshot == null) {
      _errorMessage = null;
    }
    notifyListeners();

    try {
      final next = await _service.fetchCurrent(
        latitude: latitude,
        longitude: longitude,
      );
      _snapshot = next;
      _lastFetchLatitude = latitude;
      _lastFetchLongitude = longitude;
      _lastFetchedAt = DateTime.now();
      _errorMessage = null;
    } catch (_) {
      _errorMessage = _snapshot == null ? '天氣暫不可用' : '天氣更新失敗，顯示最後資料';
    } finally {
      _isLoading = false;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  bool _needsRefresh() {
    final fetchedAt = _lastFetchedAt;
    if (fetchedAt == null) {
      return true;
    }
    if (DateTime.now().difference(fetchedAt) >= refreshInterval) {
      return true;
    }
    final lastLatitude = _lastFetchLatitude;
    final lastLongitude = _lastFetchLongitude;
    if (lastLatitude == null || lastLongitude == null) {
      return true;
    }
    final distance = math.sqrt(
      math.pow(_latitude - lastLatitude, 2) +
          math.pow(_longitude - lastLongitude, 2),
    );
    return distance >= _locationRefreshThresholdDegrees;
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
