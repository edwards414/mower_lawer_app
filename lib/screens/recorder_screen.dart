import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../providers/recorder_provider.dart';
import '../widgets/recorder_info_sheet.dart';

/// Recording status + recorded-bag management (list / rename / delete /
/// upload), all driven over rosbridge by [RecorderProvider].
class RecorderScreen extends StatelessWidget {
  const RecorderScreen({super.key});

  static String _human(int n) {
    var v = n.toDouble();
    for (final u in ['B', 'KB', 'MB', 'GB', 'TB']) {
      if (v < 1024) {
        return '${v.toStringAsFixed(v < 10 && u != 'B' ? 1 : 0)}$u';
      }
      v /= 1024;
    }
    return '${v.toStringAsFixed(1)}PB';
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<RecorderProvider>(
      builder: (context, rec, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('錄製 / Bag'),
            actions: [
              IconButton(
                icon: const Icon(AppIcons.info),
                tooltip: '錄製設計邏輯',
                onPressed: () => _showInfo(context),
              ),
              IconButton(
                icon: const Icon(AppIcons.refreshCw),
                tooltip: '重新整理',
                onPressed: rec.refresh,
              ),
            ],
          ),
          body: Column(
            children: [
              _statusBanner(rec),
              _chips(rec),
              const Divider(height: 1),
              Expanded(
                child: rec.bags.isEmpty
                    ? const Center(child: Text('目前沒有錄製檔'))
                    : ListView.separated(
                        itemCount: rec.bags.length,
                        separatorBuilder: (_, _) => const Divider(height: 1),
                        itemBuilder: (context, i) =>
                            _bagTile(context, rec, rec.bags[i]),
                      ),
              ),
            ],
          ),
          floatingActionButton: rec.r2Configured
              ? FloatingActionButton.extended(
                  onPressed: rec.uploadNow,
                  icon: const Icon(AppIcons.cloudUpload),
                  label: const Text('上傳待傳'),
                )
              : null,
        );
      },
    );
  }

  void _showInfo(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const RecorderInfoSheet(),
    );
  }

  Widget _statusBanner(RecorderProvider rec) {
    final s = rec.status;
    if (!s.recording) {
      return Container(
        width: double.infinity,
        color: Colors.grey.shade200,
        padding: const EdgeInsets.all(12),
        child: const Text('● 未在錄製', style: TextStyle(color: Colors.black54)),
      );
    }
    final mins = (s.elapsedS ~/ 60).toString().padLeft(2, '0');
    final secs = (s.elapsedS.toInt() % 60).toString().padLeft(2, '0');
    return Container(
      width: double.infinity,
      color: Colors.red.shade50,
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          const Icon(AppIcons.disc, color: Colors.red, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '錄製中 · ${s.runId ?? ""}',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                Text(
                  '$mins:$secs · ${_human(s.bagBytes)} · '
                  '${s.numTopics} topics',
                  style: const TextStyle(color: Colors.black54, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chips(RecorderProvider rec) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          _chip(
            rec.networkOk ? 'WiFi · 可上傳' : '離線 · 暫存',
            rec.networkOk ? Colors.green : Colors.orange,
          ),
          const SizedBox(width: 8),
          _chip(
            rec.r2Configured ? 'R2 已設定' : 'R2 未設定',
            rec.r2Configured ? Colors.blue : Colors.grey,
          ),
        ],
      ),
    );
  }

  Widget _chip(String label, MaterialColor color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
    decoration: BoxDecoration(
      color: color.shade50,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(label, style: TextStyle(color: color.shade700, fontSize: 12)),
  );

  Widget _bagTile(BuildContext context, RecorderProvider rec, BagInfo bag) {
    return ListTile(
      leading: Icon(
        bag.recording
            ? AppIcons.disc
            : bag.uploaded
            ? AppIcons.cloudCheck
            : bag.uploading
            ? AppIcons.cloudUpload
            : AppIcons.hardDrive,
        color: bag.recording
            ? Colors.red
            : (bag.uploaded ? Colors.blue : Colors.black45),
      ),
      title: Text(
        bag.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        '${_human(bag.sizeBytes)} · ${bag.runId}',
        style: const TextStyle(fontSize: 12),
      ),
      trailing: bag.recording
          ? const Text(
              'REC',
              style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
            )
          : PopupMenuButton<String>(
              onSelected: (v) => _onAction(context, rec, bag, v),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'rename', child: Text('更名')),
                PopupMenuItem(value: 'delete', child: Text('刪除')),
              ],
            ),
    );
  }

  Future<void> _onAction(
    BuildContext context,
    RecorderProvider rec,
    BagInfo bag,
    String action,
  ) async {
    if (action == 'rename') {
      final controller = TextEditingController(text: bag.displayName);
      final name = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('更名'),
          content: TextField(controller: controller, autofocus: true),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('確定'),
            ),
          ],
        ),
      );
      if (name != null && name.isNotEmpty) {
        rec.rename(bag.runId, name);
      }
    } else if (action == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('刪除'),
          content: Text(
            '確定刪除「${bag.displayName}」?(本機${bag.uploaded ? " + R2" : ""})',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('刪除', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      );
      if (ok == true) {
        rec.delete(bag.runId);
      }
    }
  }
}
