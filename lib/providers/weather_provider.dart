import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

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
  bool _hasLocation = false;
  int _locationGeneration = 0;

  double _latitude = AppConstants.defaultLatitude;
  double _longitude = AppConstants.defaultLongitude;
  double? _lastFetchLatitude;
  double? _lastFetchLongitude;
  DateTime? _lastFetchedAt;

  WeatherSnapshot? get snapshot => _snapshot;
  bool get isLoading => _isLoading;
  String? get errorMessage => _errorMessage;

  void updateLocation({
    required bool demoMode,
    double? latitude,
    double? longitude,
  }) {
    final hasLiveLocation =
        latitude != null &&
        longitude != null &&
        latitude.isFinite &&
        longitude.isFinite;
    if (!demoMode && !hasLiveLocation) {
      if (_hasLocation || _snapshot != null || _errorMessage != '等待新鮮 GPS 位置') {
        _hasLocation = false;
        _locationGeneration += 1;
        _timer?.cancel();
        _timer = null;
        _snapshot = null;
        _lastFetchLatitude = null;
        _lastFetchLongitude = null;
        _lastFetchedAt = null;
        _errorMessage = '等待新鮮 GPS 位置';
        scheduleMicrotask(() {
          if (!_disposed) notifyListeners();
        });
      }
      return;
    }

    final nextLatitude = demoMode ? AppConstants.defaultLatitude : latitude!;
    final nextLongitude = demoMode ? AppConstants.defaultLongitude : longitude!;
    if (!_hasLocation ||
        _latitude != nextLatitude ||
        _longitude != nextLongitude) {
      _locationGeneration += 1;
    }
    _hasLocation = true;
    _latitude = nextLatitude;
    _longitude = nextLongitude;
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
    if (_isLoading || !_hasLocation) {
      return;
    }

    final latitude = _latitude;
    final longitude = _longitude;
    final generation = _locationGeneration;
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
      if (generation != _locationGeneration || !_hasLocation) {
        return;
      }
      _snapshot = next;
      _lastFetchLatitude = latitude;
      _lastFetchLongitude = longitude;
      _lastFetchedAt = DateTime.now();
      _errorMessage = null;
    } catch (_) {
      if (generation != _locationGeneration || !_hasLocation) {
        return;
      }
      _errorMessage = _snapshot == null ? '天氣暫不可用' : '天氣更新失敗，顯示最後資料';
    } finally {
      _isLoading = false;
      if (!_disposed) {
        notifyListeners();
        if (_hasLocation && generation != _locationGeneration) {
          scheduleMicrotask(() => unawaited(refresh()));
        }
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
