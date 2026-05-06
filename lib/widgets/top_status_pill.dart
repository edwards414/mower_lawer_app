import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/mower_status_provider.dart';

class TopStatusPill extends StatelessWidget {
  const TopStatusPill({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final mowerStatus = context.watch<MowerStatusProvider>().status;
    final battery = mowerStatus?.batteryPercent ?? 85;

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
              icon: Icons.hub_outlined,
              label: 'ROS',
              color: const Color(0xFF19A763),
            ),
            const SizedBox(width: 10),
            _StatusItem(
              icon: Icons.route_outlined,
              label: mission.navStatusLabel(),
              color: mission.navStatus == NavMockStatus.executing
                  ? const Color(0xFF167A4A)
                  : const Color(0xFF607D8B),
            ),
            const SizedBox(width: 10),
            const _StatusItem(
              icon: Icons.my_location,
              label: 'RTK',
              color: Color(0xFF19A763),
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

  final double battery;

  @override
  Widget build(BuildContext context) {
    final color = battery < 35
        ? const Color(0xFFE08C1A)
        : const Color(0xFF19A763);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(_batteryIcon(battery), size: 18, color: color),
        const SizedBox(width: 4),
        Text(
          '${battery.toStringAsFixed(0)}%',
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
      return Icons.battery_alert;
    }
    if (value < 60) {
      return Icons.battery_4_bar;
    }
    return Icons.battery_full;
  }
}
