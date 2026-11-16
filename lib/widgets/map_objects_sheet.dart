import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
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
              : '$count 個物件 · 點清單或地圖上的物件來調整、刪除',
        ),
        const SizedBox(height: 10),
        ...mission.zones.map(
          (zone) => _ObjectRow(
            icon: AppIcons.squareDashed,
            color: const Color(0xFF35B861),
            title: zone.name,
            detail: 'Zone ${zone.id} · ${zone.hasCoveragePath ? '已規劃' : '未規劃'}',
            selected: mission.isObjectSelected('zone', zone.id),
            onTap: () => mission.selectObject('zone', zone.id),
            onEdit: () => mission.startVertexEdit('zone', zone.id),
            onDelete: () =>
                confirmDeleteObject(context, mission, 'zone', zone.id, zone.name),
          ),
        ),
        ...mission.riskZones.map(
          (risk) => _ObjectRow(
            icon: AppIcons.ban,
            color: const Color(0xFFE55353),
            title: risk.name,
            detail: '禁入區 · ${risk.points.length} points',
            selected: mission.isObjectSelected('risk', risk.id),
            onTap: () => mission.selectObject('risk', risk.id),
            onEdit: () => mission.startVertexEdit('risk', risk.id),
            onDelete: () =>
                confirmDeleteObject(context, mission, 'risk', risk.id, risk.name),
          ),
        ),
        ...mission.channels.map(
          (channel) => _ObjectRow(
            icon: AppIcons.spline,
            color: const Color(0xFF25AFC6),
            title: channel.name,
            detail: '通道 · ${channel.points.length} points',
            selected: mission.isObjectSelected('channel', channel.id),
            onTap: () => mission.selectObject('channel', channel.id),
            onEdit: () => mission.startVertexEdit('channel', channel.id),
            onDelete: () => confirmDeleteObject(
              context,
              mission,
              'channel',
              channel.id,
              channel.name,
            ),
          ),
        ),
        _ObjectRow(
          icon: AppIcons.route,
          color: const Color(0xFF147B58),
          title: '覆蓋路徑',
          detail: '${mission.coverageRows.length} segments · Zigzag',
        ),
        _ObjectRow(
          icon: AppIcons.octagonAlert,
          color: const Color(0xFFE53935),
          title: '風險線段',
          detail: '${mission.invalidSegments.length} segments',
        ),
      ],
    );
  }
}

/// Asks before deleting a map object, deletes it, and says what happened:
/// the one delete flow, shared by the object list and the bar that shows for
/// an object selected on the map.
Future<void> confirmDeleteObject(
  BuildContext context,
  MissionMockProvider mission,
  String kind,
  int id,
  String name, {
  double snackBottom = 12,
}) async {
  final messenger = ScaffoldMessenger.of(context);
  final label = MissionMockProvider.objectKindLabel(kind);
  final consequence = switch (kind) {
    'zone' => '這個工作區和它的覆蓋路徑會一起移除。',
    'risk' => '割草機之後可以進入這塊區域，覆蓋路徑會重新規劃。',
    _ => '用到這條通道的跨區移動會改走別條或無法通行。',
  };
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('刪除$label「$name」？'),
      content: Text('$consequence刪除後無法復原。'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFD64545),
          ),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('刪除'),
        ),
      ],
    ),
  );
  if (ok != true) {
    return;
  }
  final error = await mission.deleteObject(kind, id);
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        content: Text(error == null ? '已刪除「$name」' : '沒有刪除「$name」：$error'),
        // Floats clear of the joysticks along the bottom of the map.
        behavior: SnackBarBehavior.floating,
        margin: EdgeInsets.fromLTRB(16, 0, 16, snackBottom),
      ),
    );
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
        const Icon(AppIcons.chevronRight, color: Color(0xFFB0BEC5)),
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
    this.onEdit,
    this.onDelete,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onEdit;
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
                if (onEdit != null)
                  IconButton(
                    icon: const Icon(AppIcons.slidersHorizontal, color: Color(0xFF1384E8)),
                    onPressed: onEdit,
                    tooltip: '調整頂點',
                    visualDensity: VisualDensity.compact,
                  ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(
                      AppIcons.trash2,
                      color: Color(0xFF90A4AE),
                    ),
                    onPressed: onDelete,
                    tooltip: '刪除',
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
