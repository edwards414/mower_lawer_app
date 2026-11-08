import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

enum PhoneLocationStatus { off, locating, active, denied, serviceDisabled }

/// The phone's own GPS fix, for showing "where am I" on the map next to the
/// robot. There is no switch for it: the map turns it on by itself whenever
/// the phone allows it ([start], asking for the permission once), and leaves
/// it off, quietly, when it does not.
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

  /// Starts following the phone's position. With [prompt] false it never
  /// asks for the permission: it only starts if the phone already allows it.
  Future<void> start({bool prompt = true}) async {
    if (enabled) return;
    _set(PhoneLocationStatus.locating);

    LocationPermission permission;
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _set(PhoneLocationStatus.serviceDisabled);
        return;
      }
      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && prompt) {
        permission = await Geolocator.requestPermission();
      }
    } catch (e) {
      // No location support here (a platform without the plugin): stay off.
      debugPrint('[PhoneLocation] unavailable: $e');
      _set(PhoneLocationStatus.denied);
      return;
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
