import 'package:flutter/widgets.dart';

import '../services/rosbridge_service.dart';

/// Closes the relay session while the app is hidden (backgrounded on a phone,
/// minimised on desktop) and reconnects when it is visible again.
///
/// A relay session streams every subscribed topic through the fleet backend,
/// where each message is billed as a Durable Object request, whether or not
/// anyone is looking. A phone suspended by the OS can also leave its socket
/// open for minutes while the robot keeps sending. LAN sessions are left
/// alone ([RosbridgeService.suspendRelay] is a no-op there).
class RelayLifecycleGate extends StatefulWidget {
  const RelayLifecycleGate({
    super.key,
    required this.rosbridge,
    required this.child,
    this.canSuspend,
    this.beforeSuspend,
  });

  final RosbridgeService rosbridge;
  final Widget child;

  /// False keeps the session open, e.g. while a stop or cancel still has to
  /// reach the robot.
  final bool Function()? canSuspend;

  /// Runs while the session can still send, e.g. a final zero velocity.
  final VoidCallback? beforeSuspend;

  @override
  State<RelayLifecycleGate> createState() => _RelayLifecycleGateState();
}

class _RelayLifecycleGateState extends State<RelayLifecycleGate>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final rosbridge = widget.rosbridge;
    switch (state) {
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (!rosbridge.framed || rosbridge.suspended) {
          return;
        }
        if (widget.canSuspend?.call() == false) {
          return;
        }
        widget.beforeSuspend?.call();
        rosbridge.suspendRelay();
      case AppLifecycleState.inactive:
      case AppLifecycleState.resumed:
        rosbridge.resume();
      case AppLifecycleState.detached:
        break;
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
