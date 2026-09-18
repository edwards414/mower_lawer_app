import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class ExecutionControlSheet extends StatelessWidget {
  const ExecutionControlSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final executing = mission.navStatus == NavMockStatus.executing;
    final active = executing || mission.navStatus == NavMockStatus.paused;
    final commandPending = mission.navCommandPending || mission.cancelPending;
    final progressKnown = mission.mockDataEnabled;
    final canCancel =
        !mission.cancelRequestInFlight &&
        !mission.cancelPending &&
        ((mission.mockDataEnabled && executing) ||
            (!mission.mockDataEnabled &&
                mission.rosConnected &&
                (active || mission.navCommandPending)));
    final selectedZoneId =
        mission.zones.any((zone) => zone.id == mission.selectedZoneId)
        ? mission.selectedZoneId
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '任務執行',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            _StatusBadge(label: mission.navStatusLabel(), active: active),
          ],
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: const Color(0xFFF3F6F7),
            borderRadius: BorderRadius.circular(16),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<int>(
              isExpanded: true,
              value: selectedZoneId,
              hint: const Text('尚未收到 Zone'),
              items: mission.zones
                  .map(
                    (zone) => DropdownMenuItem<int>(
                      value: zone.id,
                      child: Text('Zone ${zone.id} · ${zone.name}'),
                    ),
                  )
                  .toList(),
              onChanged: active || commandPending || mission.zones.isEmpty
                  ? null
                  : (value) {
                      if (value != null) {
                        mission.selectZone(value);
                      }
                    },
            ),
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: LinearProgressIndicator(
            value: progressKnown
                ? mission.coverageProgress
                : active
                ? null
                : 0,
            minHeight: 10,
            backgroundColor: const Color(0xFFE2E8EA),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _RunMetric(
                label: '進度',
                value: progressKnown
                    ? '${(mission.coverageProgress * 100).round()}%'
                    : active
                    ? '後端執行中'
                    : mission.coverageProgress >= 1
                    ? '已完成'
                    : '未提供',
              ),
            ),
            Expanded(
              child: _RunMetric(
                label: 'Segment',
                value: progressKnown
                    ? '${mission.currentSegment}/${mission.coverageRows.length}'
                    : '未提供',
              ),
            ),
            Expanded(
              child: _RunMetric(
                label: '速度',
                value: mission.mockDataEnabled && executing
                    ? '0.5 m/s（Demo）'
                    : '—',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                onPressed: mission.canStartMission
                    ? mission.startExecution
                    : null,
                icon: const Icon(AppIcons.play),
                label: const Text('開始'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canCancel ? mission.cancelExecution : null,
                icon: const Icon(AppIcons.square),
                label: const Text('取消'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _StatusBadge extends StatelessWidget {
  const _StatusBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: active ? const Color(0xFFE4F6EC) : const Color(0xFFF0F3F4),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: active ? const Color(0xFF167A4A) : const Color(0xFF607D8B),
          fontSize: 12,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class _RunMetric extends StatelessWidget {
  const _RunMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Color(0xFF78909C),
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900),
          ),
        ),
      ],
    );
  }
}
