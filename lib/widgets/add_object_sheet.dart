import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class AddObjectSheet extends StatelessWidget {
  const AddObjectSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.read<MissionMockProvider>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD0D7DA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '新增地圖物件',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _AddObjectCard(
                    icon: Icons.crop_square,
                    label: '工作區',
                    color: const Color(0xFF35B861),
                    onTap: () {
                      Navigator.of(context).pop();
                      mission.startRecording(RecordObjectType.zone);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    icon: Icons.dangerous_outlined,
                    label: '禁入區',
                    color: const Color(0xFFE55353),
                    onTap: () {
                      Navigator.of(context).pop();
                      mission.startRecording(RecordObjectType.risk);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    icon: Icons.timeline,
                    label: '通道',
                    color: const Color(0xFF25AFC6),
                    onTap: () {
                      Navigator.of(context).pop();
                      mission.startRecording(RecordObjectType.channel);
                    },
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _AddObjectCard extends StatelessWidget {
  const _AddObjectCard({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        height: 112,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: const Color(0xFFE1E7EA)),
          boxShadow: const [
            BoxShadow(
              color: Color(0x12000000),
              blurRadius: 12,
              offset: Offset(0, 5),
            ),
          ],
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 28),
            ),
            const SizedBox(height: 10),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                label,
                maxLines: 1,
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
