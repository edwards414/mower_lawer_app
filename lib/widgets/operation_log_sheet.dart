import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';

class OperationLogSheet extends StatelessWidget {
  const OperationLogSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final logs = mission.logs.take(8).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '操作日誌',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900),
              ),
            ),
            TextButton.icon(
              onPressed: () => mission.addMockAction('手動刷新日誌'),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (logs.isEmpty)
          const Text('目前沒有日誌', style: TextStyle(color: Color(0xFF78909C)))
        else
          ...logs.map(
            (log) =>
                _LogRow(time: log.time, level: log.level, message: log.message),
          ),
      ],
    );
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow({
    required this.time,
    required this.level,
    required this.message,
  });

  final String time;
  final String level;
  final String message;

  @override
  Widget build(BuildContext context) {
    final color = _levelColor(level);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(top: 7),
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 58,
            child: Text(
              time,
              style: const TextStyle(
                color: Color(0xFF78909C),
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '[$level] $message',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Color _levelColor(String level) {
    switch (level) {
      case 'SUCCESS':
        return const Color(0xFF167A4A);
      case 'WARN':
        return const Color(0xFFE08C1A);
      case 'ERROR':
        return const Color(0xFFE53935);
      default:
        return const Color(0xFF607D8B);
    }
  }
}
