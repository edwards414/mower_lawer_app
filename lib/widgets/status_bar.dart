import 'package:flutter/material.dart';
import '../utils/app_icons.dart';

import '../models/mower_status.dart';
import '../utils/constants.dart';

/// Top status bar: battery, GPS, time
class StatusBar extends StatelessWidget {
  final MowerStatus status;

  const StatusBar({super.key, required this.status});

  IconData _batteryIcon() {
    if (status.batteryPercent <= AppConstants.lowBatteryThreshold) {
      return AppIcons.batteryWarning;
    }
    if (status.batteryPercent <= AppConstants.warningBatteryThreshold) {
      return AppIcons.batteryLow;
    }
    if (status.workStatus == MowerWorkStatus.charging) {
      return AppIcons.batteryCharging;
    }
    return AppIcons.batteryFull;
  }

  Color _batteryColor() {
    if (status.batteryPercent <= AppConstants.lowBatteryThreshold) {
      return Colors.red;
    }
    if (status.batteryPercent <= AppConstants.warningBatteryThreshold) {
      return Colors.orange;
    }
    return Colors.green;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize:
          MainAxisSize.min, // Wrap content so it fits tightly in center
      children: [
        Icon(_batteryIcon(), color: _batteryColor(), size: 28),
        const SizedBox(width: 8),
        Text(
          '${status.batteryPercent.toStringAsFixed(0)}%',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: _batteryColor(),
            fontSize: 18,
          ),
        ),
      ],
    );
  }
}
