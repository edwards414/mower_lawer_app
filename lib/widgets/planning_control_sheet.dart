import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import 'image_mission_sheet.dart';

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
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<CoveragePatternKind>(
            showSelectedIcon: false,
            selected: {mission.coveragePattern},
            onSelectionChanged: (selection) {
              final pattern = selection.first;
              mission.setCoveragePattern(pattern);
              // 'Custom' opens the uploaded-image coverage flow.
              if (pattern == CoveragePatternKind.custom) {
                _openImageMission(context);
              }
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
              ButtonSegment(
                value: CoveragePatternKind.custom,
                label: Text('Custom'),
                icon: Icon(Icons.image_outlined),
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

  void _openImageMission(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => const ImageMissionSheet(),
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
  static const int divisions = 13;
  static const int fractionDigits = 2;

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
              '${value.toStringAsFixed(fractionDigits)} $unit',
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
          divisions: divisions,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
