import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum PhoneLocationStatus { off, locating, active, denied, serviceDisabled }

/// The phone's own GPS fix, for showing "where am I" on the map next to the
/// robot. Off until the user asks for it, so the location permission prompt
/// only appears in response to that tap.
class PhoneLocationProvider extends ChangeNotifier {
  StreamSubscription<Position>? _sub;
  PhoneLocationStatus _status = PhoneLocationStatus.off;
  LatLng? _position;
  double? _accuracyM;
  bool _disposed = false;

  PhoneLocationStatus get status => _status;
  bool get enabled =>
      _status == PhoneLocationStatus.locating ||
      _status == PhoneLocationStatus.active;

  /// Latest fix; null until the first one arrives (or while off).
  LatLng? get position => _position;

  /// Horizontal accuracy radius of [position], metres.
  double? get accuracyM => _accuracyM;

  Future<void> toggle() => enabled ? stop() : start();

  Future<void> start() async {
    if (enabled) return;
    _set(PhoneLocationStatus.locating);

    if (!await Geolocator.isLocationServiceEnabled()) {
      _set(PhoneLocationStatus.serviceDisabled);
      return;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever ||
        permission == LocationPermission.unableToDetermine) {
      _set(PhoneLocationStatus.denied);
      return;
    }
    // The user may have switched it off again while the prompt was up.
    if (_disposed || _status != PhoneLocationStatus.locating) return;

    await _sub?.cancel();
    _sub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.best,
            distanceFilter: 1,
          ),
        ).listen(
          (p) {
            _position = LatLng(p.latitude, p.longitude);
            _accuracyM = p.accuracy;
            _set(PhoneLocationStatus.active);
          },
          onError: (Object e) {
            debugPrint('[PhoneLocation] stream error: $e');
            _sub?.cancel();
            _sub = null;
            _position = null;
            _accuracyM = null;
            _set(
              e is LocationServiceDisabledException
                  ? PhoneLocationStatus.serviceDisabled
                  : PhoneLocationStatus.denied,
            );
          },
        );
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _position = null;
    _accuracyM = null;
    _set(PhoneLocationStatus.off);
  }

  /// Opens the OS settings page where location can be re-enabled.
  Future<void> openSettings() => _status == PhoneLocationStatus.serviceDisabled
      ? Geolocator.openLocationSettings()
      : Geolocator.openAppSettings();

  void _set(PhoneLocationStatus status) {
    if (_disposed) return;
    _status = status;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _sub?.cancel();
    super.dispose();
  }
}
