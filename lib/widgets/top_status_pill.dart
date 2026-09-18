import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class TopStatusPill extends StatelessWidget {
  const TopStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final battery = mission.batteryPercent;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            blurRadius: 18,
            color: Color(0x22000000),
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusItem(
              icon: AppIcons.network,
              label: mission.mockDataEnabled
                  ? 'Demo'
                  : mission.robotOnline
                  ? 'Online'
                  : mission.rosConnected
                  ? 'Offline'
                  : 'Wait',
              color: mission.mockDataEnabled
                  ? const Color(0xFFE08C1A)
                  : mission.robotOnline
                  ? const Color(0xFF19A763)
                  : const Color(0xFF607D8B),
            ),
            const SizedBox(width: 10),
            _StatusItem(
              icon: AppIcons.route,
              label: mission.navStatusLabel(),
              color: mission.navStatus == NavMockStatus.executing
                  ? const Color(0xFF167A4A)
                  : const Color(0xFF607D8B),
            ),
            const SizedBox(width: 10),
            _StatusItem(
              icon: AppIcons.locateFixed,
              label: mission.mockDataEnabled
                  ? 'Demo GPS'
                  : mission.hasFreshGpsFix
                  ? 'GPS'
                  : 'No fix',
              color: mission.mockDataEnabled
                  ? const Color(0xFFE08C1A)
                  : mission.hasFreshGpsFix
                  ? const Color(0xFF19A763)
                  : const Color(0xFF607D8B),
            ),
            const SizedBox(width: 10),
            _BatteryStatus(battery: battery),
          ],
        ),
      ),
    );
  }
}

class _StatusItem extends StatelessWidget {
  const _StatusItem({
    required this.icon,
    required this.label,
    required this.color,
  });

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}

class _BatteryStatus extends StatelessWidget {
  const _BatteryStatus({required this.battery});

  final double? battery;

  @override
  Widget build(BuildContext context) {
    final battery = this.battery;
    final color = battery == null
        ? const Color(0xFF607D8B)
        : battery < 35
        ? const Color(0xFFE08C1A)
        : const Color(0xFF19A763);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          battery == null ? AppIcons.battery : _batteryIcon(battery),
          size: 18,
          color: color,
        ),
        const SizedBox(width: 4),
        Text(
          battery == null ? '--' : '${battery.toStringAsFixed(0)}%',
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  IconData _batteryIcon(double value) {
    if (value < 20) {
      return AppIcons.batteryWarning;
    }
    if (value < 60) {
      return AppIcons.batteryMedium;
    }
    return AppIcons.batteryFull;
  }
}
