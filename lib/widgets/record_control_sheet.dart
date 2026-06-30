import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';

class RecordControlSheet extends StatelessWidget {
  const RecordControlSheet({super.key, required this.onGoManual});

  /// Switch to the manual-control page, where recording actually happens
  /// (you drive the robot to trace each boundary).
  final VoidCallback onGoManual;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    if (mission.recordingType != null) {
      return _ActiveRecordPanel(mission: mission);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '記錄物件',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
        ),
        const SizedBox(height: 4),
        const Text(
          '工作區 / 禁入區 / 通道都是「開著車繞一圈邊界」記錄出來的，'
          '所以記錄在手動遙控頁進行。',
          style: TextStyle(
            color: Color(0xFF78909C),
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 14),
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: onGoManual,
            icon: const Icon(Icons.sports_esports_outlined),
            label: const Text('前往手動遙控頁記錄'),
          ),
        ),
      ],
    );
  }
}

class _ActiveRecordPanel extends StatelessWidget {
  const _ActiveRecordPanel({required this.mission});

  final MissionMockProvider mission;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              Icons.fiber_manual_record,
              color: Color(0xFFE55353),
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                mission.recordingTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: _MetricTile(
                label: '時間',
                value: _formatDuration(mission.recordingElapsed),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _MetricTile(
                label: '點數',
                value: '${mission.recordPointCount}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: () => mission.stopRecording(save: false),
                child: const Text('取消'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FilledButton(
                onPressed: () => mission.stopRecording(save: true),
                child: const Text('結束並儲存'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  String _formatDuration(Duration duration) {
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF3F6F7),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Color(0xFF78909C),
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
          ),
        ],
      ),
    );
  }
}
