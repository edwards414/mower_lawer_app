import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';

/// The robot's state at the top of the map, in the home page's style: a
/// white pill on a soft shadow, each item a coloured icon and a dark label.
class TopStatusPill extends StatelessWidget {
  const TopStatusPill({super.key});

  static const _ok = Color(0xFF19A763);
  static const _idle = Color(0xFF8A9691);

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final demo = mission.mockDataEnabled;
    final battery = mission.batteryPercent;

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        boxShadow: AppStyle.floatShadow,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            _StatusItem(
              icon: AppIcons.network,
              label: demo
                  ? 'Demo'
                  : mission.robotOnline
                  ? '在線'
                  : mission.rosConnected
                  ? '離線'
                  : '連線中',
              color: demo
                  ? AppStyle.amber
                  : mission.robotOnline
                  ? _ok
                  : _idle,
            ),
            const _Divider(),
            _StatusItem(
              icon: AppIcons.route,
              label: mission.navStatusLabel(),
              color: mission.navStatus == NavMockStatus.executing
                  ? AppStyle.green
                  : _idle,
            ),
            const _Divider(),
            _StatusItem(
              icon: AppIcons.locateFixed,
              label: demo || mission.hasFreshGpsFix ? 'GPS' : '無定位',
              color: demo
                  ? AppStyle.amber
                  : mission.hasFreshGpsFix
                  ? _ok
                  : _idle,
            ),
            const _Divider(),
            _StatusItem(
              icon: _batteryIcon(battery),
              label: battery == null ? '--' : '${battery.round()}%',
              color: battery == null
                  ? _idle
                  : battery < 35
                  ? AppStyle.amber
                  : _ok,
            ),
          ],
        ),
      ),
    );
  }

  static IconData _batteryIcon(double? value) {
    if (value == null) return AppIcons.battery;
    if (value < 20) return AppIcons.batteryWarning;
    if (value < 60) return AppIcons.batteryMedium;
    return AppIcons.batteryFull;
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
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 5),
        Text(
          label,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: AppStyle.ink,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 14,
    margin: const EdgeInsets.symmetric(horizontal: 10),
    color: AppStyle.line,
  );
}
