import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class PlanningControlSheet extends StatelessWidget {
  const PlanningControlSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Coverage 規劃',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            _ReadyBadge(label: mission.coverageReady ? 'Ready' : 'Draft'),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _PlanActionChip(
              label: '自由空間',
              ready: mission.freeSpaceReady,
              onTap: () => mission.runPlanningStep('free_space'),
            ),
            _PlanActionChip(
              label: '風險地圖',
              ready: mission.riskMapReady,
              onTap: () => mission.runPlanningStep('risk_map'),
            ),
            _PlanActionChip(
              label: '通道地圖',
              ready: mission.channelMapReady,
              onTap: () => mission.runPlanningStep('channel_map'),
            ),
          ],
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CoveragePatternKind>(
            selected: {mission.coveragePattern},
            onSelectionChanged: (selection) {
              mission.setCoveragePattern(selection.first);
            },
            segments: const [
              ButtonSegment(
                value: CoveragePatternKind.zigzag,
                label: Text('Zigzag'),
                icon: Icon(Icons.swap_vert),
              ),
              ButtonSegment(
                value: CoveragePatternKind.spiral,
                label: Text('Spiral'),
                icon: Icon(Icons.blur_circular),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _ParameterSlider(
          label: 'Strip Width',
          value: mission.stripWidthM,
          min: 0.3,
          max: 1.6,
          unit: 'm',
          onChanged: mission.setStripWidth,
        ),
        _ParameterSlider(
          label: 'Waypoint Spacing',
          value: mission.waypointSpacingM,
          min: 0.1,
          max: 0.8,
          unit: 'm',
          onChanged: mission.setWaypointSpacing,
        ),
        const SizedBox(height: 8),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: () => mission.runPlanningStep('coverage'),
            icon: const Icon(Icons.route),
            label: const Text('生成覆蓋路徑'),
          ),
        ),
      ],
    );
  }
}

class _ReadyBadge extends StatelessWidget {
  const _ReadyBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFFE4F6EC),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: Color(0xFF167A4A),
          fontWeight: FontWeight.w900,
          fontSize: 12,
        ),
      ),
    );
  }
}

class _PlanActionChip extends StatelessWidget {
  const _PlanActionChip({
    required this.label,
    required this.ready,
    required this.onTap,
  });

  final String label;
  final bool ready;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ActionChip(
      avatar: Icon(
        ready ? Icons.check_circle : Icons.radio_button_unchecked,
        color: ready ? const Color(0xFF167A4A) : const Color(0xFF78909C),
      ),
      label: Text(label),
      onPressed: onTap,
      backgroundColor: Colors.white,
      side: BorderSide(
        color: ready ? const Color(0x5535B861) : const Color(0xFFD8DDE0),
      ),
    );
  }
}

class _ParameterSlider extends StatelessWidget {
  const _ParameterSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String unit;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w800),
              ),
            ),
            Text(
              '${value.toStringAsFixed(2)} $unit',
              style: const TextStyle(
                color: Color(0xFF167A4A),
                fontWeight: FontWeight.w900,
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: 13,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
