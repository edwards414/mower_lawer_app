import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';

class MapObjectsSheet extends StatelessWidget {
  const MapObjectsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SheetHeader(
          title: '地圖物件',
          subtitle:
              '${mission.zones.length + mission.riskZones.length + mission.channels.length} items',
        ),
        const SizedBox(height: 10),
        ...mission.zones.map(
          (zone) => _ObjectRow(
            icon: Icons.crop_square,
            color: const Color(0xFF35B861),
            title: zone.name,
            detail: 'Zone ${zone.id} · ${zone.hasCoveragePath ? '已規劃' : '未規劃'}',
          ),
        ),
        ...mission.riskZones.map(
          (risk) => _ObjectRow(
            icon: Icons.dangerous_outlined,
            color: const Color(0xFFE55353),
            title: risk.name,
            detail: '禁入區 · ${risk.points.length} points',
          ),
        ),
        ...mission.channels.map(
          (channel) => _ObjectRow(
            icon: Icons.timeline,
            color: const Color(0xFF25AFC6),
            title: channel.name,
            detail: '通道 · ${channel.points.length} points',
          ),
        ),
        _ObjectRow(
          icon: Icons.route,
          color: const Color(0xFF147B58),
          title: '覆蓋路徑',
          detail: '${mission.coverageRows.length} segments · Zigzag',
        ),
        _ObjectRow(
          icon: Icons.report_gmailerrorred_outlined,
          color: const Color(0xFFE53935),
          title: '風險線段',
          detail: '${mission.invalidSegments.length} segments',
        ),
      ],
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF78909C),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const Icon(Icons.chevron_right, color: Color(0xFFB0BEC5)),
      ],
    );
  }
}

class _ObjectRow extends StatelessWidget {
  const _ObjectRow({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontWeight: FontWeight.w800,
                    fontSize: 14,
                  ),
                ),
                Text(
                  detail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFF78909C),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
