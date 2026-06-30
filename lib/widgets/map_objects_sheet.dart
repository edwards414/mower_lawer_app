import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';

class MapObjectsSheet extends StatelessWidget {
  const MapObjectsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final count = mission.zones.length +
        mission.riskZones.length +
        mission.channels.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SheetHeader(
          title: '地圖物件',
          subtitle: mission.replanning
              ? '重新規劃中…'
              : '$count items · 點一下選取,垃圾桶刪除',
        ),
        const SizedBox(height: 10),
        ...mission.zones.map(
          (zone) => _ObjectRow(
            icon: Icons.crop_square,
            color: const Color(0xFF35B861),
            title: zone.name,
            detail: 'Zone ${zone.id} · ${zone.hasCoveragePath ? '已規劃' : '未規劃'}',
            selected: mission.isObjectSelected('zone', zone.id),
            onTap: () => mission.selectObject('zone', zone.id),
            onDelete: () =>
                _confirmDelete(context, mission, 'zone', zone.id, zone.name),
          ),
        ),
        ...mission.riskZones.map(
          (risk) => _ObjectRow(
            icon: Icons.dangerous_outlined,
            color: const Color(0xFFE55353),
            title: risk.name,
            detail: '禁入區 · ${risk.points.length} points',
            selected: mission.isObjectSelected('risk', risk.id),
            onTap: () => mission.selectObject('risk', risk.id),
            onDelete: () =>
                _confirmDelete(context, mission, 'risk', risk.id, risk.name),
          ),
        ),
        ...mission.channels.map(
          (channel) => _ObjectRow(
            icon: Icons.timeline,
            color: const Color(0xFF25AFC6),
            title: channel.name,
            detail: '通道 · ${channel.points.length} points',
            selected: mission.isObjectSelected('channel', channel.id),
            onTap: () => mission.selectObject('channel', channel.id),
            onDelete: () => _confirmDelete(
              context,
              mission,
              'channel',
              channel.id,
              channel.name,
            ),
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

  Future<void> _confirmDelete(
    BuildContext context,
    MissionMockProvider mission,
    String kind,
    int id,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除物件'),
        content: Text('確定刪除「$name」?刪除後會自動重新規劃覆蓋路徑。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('刪除'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await mission.deleteObject(kind, id);
    }
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
    this.selected = false,
    this.onTap,
    this.onDelete,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: selected ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: selected
                  ? Border.all(color: color.withValues(alpha: 0.6), width: 1.4)
                  : null,
            ),
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
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Color(0xFF90A4AE),
                    ),
                    onPressed: onDelete,
                    tooltip: '刪除',
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
