import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class MissionModeBar extends StatelessWidget {
  const MissionModeBar({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final items = const [
      _ModeItem(MissionMode.objects, Icons.layers_outlined, '物件'),
      _ModeItem(MissionMode.record, Icons.edit_location_alt_outlined, '記錄'),
      _ModeItem(MissionMode.plan, Icons.tune_outlined, '規劃'),
      _ModeItem(MissionMode.run, Icons.play_circle_outline, '執行'),
      _ModeItem(MissionMode.logs, Icons.receipt_long_outlined, '日誌'),
    ];

    return Row(
      children: items.map((item) {
        final selected = item.mode == mission.selectedMode;
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => mission.selectMode(item.mode),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: selected
                      ? const Color(0xFF167A4A)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      item.icon,
                      size: 20,
                      color: selected ? Colors.white : const Color(0xFF607D8B),
                    ),
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        item.label,
                        maxLines: 1,
                        style: TextStyle(
                          color: selected
                              ? Colors.white
                              : const Color(0xFF607D8B),
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}

class _ModeItem {
  const _ModeItem(this.mode, this.icon, this.label);

  final MissionMode mode;
  final IconData icon;
  final String label;
}
