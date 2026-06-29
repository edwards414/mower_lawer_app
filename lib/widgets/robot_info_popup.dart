import 'package:flutter/material.dart';

import '../models/robot_fleet.dart';

class RobotInfoPopup extends StatelessWidget {
  const RobotInfoPopup({
    super.key,
    required this.robot,
    required this.onClose,
  });

  final RobotAgent robot;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final battery = robot.batteryPercent;
    final progress = robot.progress;

    final batteryColor = battery > 50
        ? const Color(0xFF168848)
        : battery > 20
        ? const Color(0xFFE65100)
        : const Color(0xFFD32F2F);

    final statusLabel = switch (robot.workStatus) {
      RobotWorkStatus.working => '工作中',
      RobotWorkStatus.charging => '充電中',
      RobotWorkStatus.idle => '待機',
    };

    final statusColor = switch (robot.workStatus) {
      RobotWorkStatus.working => const Color(0xFF168848),
      RobotWorkStatus.charging => const Color(0xFF1565C0),
      RobotWorkStatus.idle => const Color(0xFF607D8B),
    };

    return Material(
      color: Colors.transparent,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: const [
            BoxShadow(
              color: Color(0x40000000),
              blurRadius: 24,
              offset: Offset(0, 8),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      color: robot.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    robot.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF17211C),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onClose,
                    behavior: HitTestBehavior.opaque,
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close, size: 18, color: Color(0xFF78909C)),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Icon(Icons.battery_charging_full, size: 15, color: batteryColor),
                  const SizedBox(width: 4),
                  Text(
                    '${battery.round()}%',
                    style: TextStyle(
                      color: batteryColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: (battery / 100).clamp(0.0, 1.0),
                        minHeight: 6,
                        backgroundColor: const Color(0xFFE6ECE9),
                        color: batteryColor,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 7),
              Row(
                children: [
                  Icon(Icons.circle, size: 8, color: statusColor),
                  const SizedBox(width: 6),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '已分配 ${robot.assignedRowIndices.length} 行',
                    style: const TextStyle(
                      color: Color(0xFF8A9691),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 9),
              Row(
                children: [
                  const Text(
                    '進度',
                    style: TextStyle(
                      color: Color(0xFF8A9691),
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: progress.clamp(0.0, 1.0),
                        minHeight: 7,
                        backgroundColor: const Color(0xFFE6ECE9),
                        color: robot.color,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '${(progress * 100).round()}%',
                    style: TextStyle(
                      color: robot.color,
                      fontSize: 12,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
