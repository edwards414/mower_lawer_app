import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';

import '../services/rosbridge_service.dart';

/// Coming back to the foreground is an explicit reason to try the robot
/// again now instead of waiting out a long reconnect backoff.
class RetryRosbridgeOnResume extends StatefulWidget {
  const RetryRosbridgeOnResume({super.key, required this.child});

  final Widget child;

  @override
  State<RetryRosbridgeOnResume> createState() => _RetryRosbridgeOnResumeState();
}

class _RetryRosbridgeOnResumeState extends State<RetryRosbridgeOnResume> {
  late final AppLifecycleListener _lifecycle;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () => context.read<RosbridgeService>().retryNow(),
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
