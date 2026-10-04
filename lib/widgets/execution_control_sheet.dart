import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../models/zone_sequence.dart';
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
    final sequenceAvailable = mission.zones.length >= 2;
    final runAll = sequenceAvailable && mission.runAllZones;
    final sequence = _ourSequence(mission);

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
        if (sequenceAvailable) ...[
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('單一區域')),
                ButtonSegment(value: true, label: Text('全部區域依序')),
              ],
              selected: {runAll},
              showSelectedIcon: false,
              onSelectionChanged: active || commandPending
                  ? null
                  : (selection) => mission.setRunAllZones(selection.first),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (runAll)
          _SequencePlan(mission: mission, status: sequence)
        else
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
                    : runAll && (sequence?.running ?? false)
                    ? '第 ${sequence!.index + 1}/${sequence.zoneIds.length} 區'
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
                onPressed: runAll
                    ? mission.canStartZoneSequence
                          ? mission.startZoneSequence
                          : null
                    : mission.canStartMission
                    ? mission.startExecution
                    : null,
                icon: const Icon(AppIcons.play),
                label: Text(runAll ? '依序開始' : '開始'),
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

/// The robot's sequence status when it is about the zones shown here.
ZoneSequenceStatus? _ourSequence(MissionMockProvider mission) {
  final status = mission.zoneSequence;
  if (status == null ||
      status.state == 'idle' ||
      !listEquals(status.zoneIds, mission.sequenceZoneIds)) {
    return null;
  }
  return status;
}

enum _LegState { pending, current, done, stopped }

/// 全部區域依序: each zone in order with the channel between two zones; the
/// leg the robot is on is highlighted and the finished ones are ticked.
class _SequencePlan extends StatelessWidget {
  const _SequencePlan({required this.mission, required this.status});

  final MissionMockProvider mission;
  final ZoneSequenceStatus? status;

  @override
  Widget build(BuildContext context) {
    final ids = mission.sequenceZoneIds;
    final status = this.status;
    // Legs in order: zone i at 2i, the channel after it at 2i + 1.
    final at = status == null
        ? -1
        : status.leg == 'channel'
        ? 2 * status.index + 1
        : 2 * status.index;
    _LegState legState(int leg) {
      if (status == null) {
        return _LegState.pending;
      }
      if (status.state == 'completed' || leg < at) {
        return _LegState.done;
      }
      if (leg == at) {
        return status.running ? _LegState.current : _LegState.stopped;
      }
      return _LegState.pending;
    }

    final legs = <Widget>[];
    for (var i = 0; i < ids.length; i++) {
      if (i > 0) {
        legs.add(const Icon(AppIcons.arrowRight, size: 14));
        legs.add(_LegChip(label: '通道', state: legState(2 * i - 1)));
        legs.add(const Icon(AppIcons.arrowRight, size: 14));
      }
      legs.add(_LegChip(label: 'Zone ${ids[i]}', state: legState(2 * i)));
    }
    final reason = mission.zoneSequenceBlockReason;
    final running = status?.running ?? false;
    final caption = running || (status != null && status.state != 'completed')
        ? status!.message
        : status?.state == 'completed'
        ? '全部區域已完成'
        : reason ?? '依序割完每個區域，區域之間沿通道自動移動';
    final warn = !running && status == null && reason != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 4,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: legs,
          ),
          const SizedBox(height: 8),
          Text(
            caption,
            style: TextStyle(
              color: warn ? const Color(0xFFB26A00) : const Color(0xFF607D8B),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegChip extends StatelessWidget {
  const _LegChip({required this.label, required this.state});

  final String label;
  final _LegState state;

  @override
  Widget build(BuildContext context) {
    final (background, foreground) = switch (state) {
      _LegState.current => (const Color(0xFF167A4A), Colors.white),
      _LegState.done => (const Color(0xFFE4F6EC), const Color(0xFF167A4A)),
      _LegState.stopped => (const Color(0xFFFDECEA), const Color(0xFFC62828)),
      _LegState.pending => (Colors.white, const Color(0xFF607D8B)),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDE5E8)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (state == _LegState.done) ...[
            Icon(AppIcons.check, size: 13, color: foreground),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: foreground,
              fontSize: 12,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
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
