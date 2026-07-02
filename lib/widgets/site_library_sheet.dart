import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/site_info.dart';
import '../providers/mission_mock_provider.dart';

class SiteLibrarySheet extends StatelessWidget {
  const SiteLibrarySheet({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final activeName = mission.activeSiteName;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 42,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD0D7DA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '場地庫',
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
                  child: FilledButton.icon(
                    onPressed: mission.siteOpBusy
                        ? null
                        : () => _saveAs(context, mission),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('將目前規劃存為場地'),
                  ),
                ),
                if (activeName != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: mission.siteOpBusy
                          ? null
                          : () => _updateActive(context, mission, activeName),
                      icon: const Icon(Icons.sync_outlined),
                      label: const Text('更新目前場地'),
                    ),
                  ),
                ],
              ],
            ),
            // Result of the last site op, shown inside the sheet — the root
            // SnackBar renders behind the modal, so this is the visible
            // feedback while the sheet stays open.
            if (mission.siteOpMessage != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFFF3F6F7),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.info_outline,
                      size: 16,
                      color: Color(0xFF607D8B),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        mission.siteOpMessage!,
                        style: const TextStyle(
                          color: Color(0xFF546E7A),
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            if (mission.sites.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Center(
                  child: Text(
                    '尚無場地 — 錄完區域後存檔即可重複使用',
                    style: TextStyle(
                      color: Color(0xFF78909C),
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: Column(
                    children: mission.sites
                        .map(
                          (site) => _SiteRow(
                            site: site,
                            active: site.name == activeName,
                            busy: mission.siteOpBusy,
                            onActivate: () =>
                                _activate(context, mission, site.name),
                            onRename: () =>
                                _rename(context, mission, site.name),
                            onDelete: () =>
                                _confirmDelete(context, mission, site.name),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveAs(BuildContext context, MissionMockProvider mission) async {
    final name = await _promptSiteName(context, title: '存為場地');
    if (name == null || !context.mounted) {
      return;
    }
    // Saving under an existing name replaces that site — confirm first.
    if (mission.sites.any((s) => s.name == name)) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('覆蓋場地'),
          content: Text('場地「$name」已存在，要覆蓋嗎？'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('覆蓋'),
            ),
          ],
        ),
      );
      if (ok != true || !context.mounted) {
        return;
      }
    }
    await _runSiteOp(context, () => mission.saveSiteAs(name), mission);
  }

  Future<void> _updateActive(
    BuildContext context,
    MissionMockProvider mission,
    String activeName,
  ) async {
    await _runSiteOp(context, () => mission.saveSiteAs(activeName), mission);
  }

  Future<void> _activate(
    BuildContext context,
    MissionMockProvider mission,
    String name,
  ) async {
    await _runSiteOp(context, () => mission.activateSite(name), mission);
  }

  Future<void> _rename(
    BuildContext context,
    MissionMockProvider mission,
    String oldName,
  ) async {
    final newName = await _promptSiteName(
      context,
      title: '場地改名',
      initial: oldName,
    );
    if (newName == null || newName == oldName || !context.mounted) {
      return;
    }
    await _runSiteOp(context, () => mission.renameSite(oldName, newName), mission);
  }

  Future<void> _confirmDelete(
    BuildContext context,
    MissionMockProvider mission,
    String name,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('刪除場地'),
        content: Text('確定刪除場地「$name」?此操作無法復原。'),
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
    if (ok != true || !context.mounted) {
      return;
    }
    await _runSiteOp(context, () => mission.deleteSite(name), mission);
  }

  /// Run a site operation and surface the backend `message` (or the returned
  /// error) as a SnackBar.
  Future<void> _runSiteOp(
    BuildContext context,
    Future<String?> Function() op,
    MissionMockProvider mission,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final error = await op();
    messenger.showSnackBar(
      SnackBar(content: Text(error ?? mission.siteOpMessage ?? '操作完成')),
    );
  }

  Future<String?> _promptSiteName(
    BuildContext context, {
    required String title,
    String initial = '',
  }) async {
    final controller = TextEditingController(text: initial);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '場地名稱',
            hintText: '例如：後院',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    // Intentionally NOT disposing the controller: the dialog's TextField still
    // reads it during the pop transition, so disposing here throws in debug.
    // The short-lived controller is simply left to the GC.
    if (name == null || name.isEmpty) {
      return null;
    }
    return name;
  }
}

class _SiteRow extends StatelessWidget {
  const _SiteRow({
    required this.site,
    required this.active,
    required this.busy,
    required this.onActivate,
    required this.onRename,
    required this.onDelete,
  });

  final SiteInfo site;
  final bool active;
  final bool busy;
  final VoidCallback onActivate;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    const color = Color(0xFF167A4A);
    final navsat = site.datumSource == 'navsat';

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: active ? color.withValues(alpha: 0.10) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: active
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
                child: const Icon(
                  Icons.collections_bookmark_outlined,
                  color: color,
                  size: 22,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            site.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontWeight: FontWeight.w800,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        if (active) ...[
                          const SizedBox(width: 6),
                          const _SiteBadge(
                            label: '使用中',
                            color: color,
                            background: Color(0xFFE4F6EC),
                          ),
                        ],
                        const SizedBox(width: 6),
                        _SiteBadge(
                          label: navsat ? 'RTK' : '預設',
                          color: navsat
                              ? const Color(0xFF1384E8)
                              : const Color(0xFF607D8B),
                          background: navsat
                              ? const Color(0xFFE3F0FC)
                              : const Color(0xFFF0F3F4),
                        ),
                      ],
                    ),
                    Text(
                      _detailText(),
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
              if (busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                IconButton(
                  icon: const Icon(
                    Icons.play_circle_outline,
                    color: Color(0xFF167A4A),
                  ),
                  onPressed: onActivate,
                  tooltip: '啟用',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.drive_file_rename_outline,
                    color: Color(0xFF1384E8),
                  ),
                  onPressed: onRename,
                  tooltip: '改名',
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Color(0xFF90A4AE),
                  ),
                  onPressed: onDelete,
                  tooltip: '刪除',
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _detailText() {
    final created = site.createdAt;
    final date = created == null
        ? ''
        : '${created.year}/${created.month.toString().padLeft(2, '0')}/'
              '${created.day.toString().padLeft(2, '0')} · ';
    return '$date${site.zoneCount} 工作區 · ${site.riskCount} 禁區 · '
        '${site.channelCount} 通道 · ${site.areaM2.round()} m²';
  }
}

class _SiteBadge extends StatelessWidget {
  const _SiteBadge({
    required this.label,
    required this.color,
    required this.background,
  });

  final String label;
  final Color color;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}
