import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the phone's screen on, or lets it sleep again. Manual mode's cruise
/// (定速) holds it: a phone left to auto-lock leaves the foreground, and that
/// stops the robot. Tests pass a fake, so they never reach the platform.
abstract interface class ScreenWake {
  /// True keeps the screen on; false hands it back to the system timer.
  Future<void> keepOn(bool on);
}

/// The platform's wakelock (wakelock_plus).
class PlatformScreenWake implements ScreenWake {
  const PlatformScreenWake();

  @override
  Future<void> keepOn(bool on) async {
    try {
      await WakelockPlus.toggle(enable: on);
    } catch (e) {
      // Not a safety problem: the screen just sleeps on its usual timer, and
      // the app leaving the foreground ends the cruise with a stop.
      debugPrint('wakelock ${on ? 'enable' : 'disable'} failed: $e');
    }
  }
}
