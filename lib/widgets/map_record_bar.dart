import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';

/// Map-side controls for an object recording, so the way to finish (save or
/// cancel) or retry a failed save is visible where the trail is drawn and not
/// only on the manual-control page.
///
/// Renders nothing when there is no recording and no unsaved one.
class MapRecordBar extends StatelessWidget {
  const MapRecordBar({super.key, required this.onOpenManual});

  /// Takes the user to the manual-control page, where the robot is driven.
  final VoidCallback onOpenManual;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final Widget content;
    if (mission.hasPendingRecordSave) {
      content = _PendingSaveBar(mission: mission);
    } else if (mission.recordingType != null) {
      content = _RecordingBar(mission: mission, onOpenManual: onOpenManual);
    } else {
      return const SizedBox.shrink();
    }
    // Swallow taps on the bar (incl. rounded-corner gaps) so they do not
    // select a map object behind it.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapUp: (_) {},
      child: content,
    );
  }
}

class _RecordingBar extends StatelessWidget {
  const _RecordingBar({required this.mission, required this.onOpenManual});

  final MissionMockProvider mission;
  final VoidCallback onOpenManual;

  Future<void> _finish(BuildContext context, {required bool save}) async {
    final messenger = ScaffoldMessenger.of(context);
    final done = await mission.stopRecording(save: save);
    if (!done) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(save ? '儲存沒有成功，記錄仍在進行，請重試（詳見日誌）' : '取消沒有成功，請重試（詳見日誌）'),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = mission.recordCommandPending;
    final compact = TextButton.styleFrom(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      minimumSize: Size.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    return Material(
      color: Colors.black.withValues(alpha: 0.78),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(AppIcons.disc, color: Color(0xFFE55353), size: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${mission.recordingTitle} · ${mission.recordPointCount} 點',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w900,
                  fontSize: 13,
                ),
              ),
            ),
            IconButton(
              tooltip: '前往手動控制',
              onPressed: onOpenManual,
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
              padding: EdgeInsets.zero,
              icon: const Icon(
                AppIcons.gamepad2,
                color: Colors.white70,
                size: 20,
              ),
            ),
            TextButton(
              onPressed: busy
                  ? null
                  : () => unawaited(_finish(context, save: false)),
              style: compact.copyWith(
                foregroundColor: WidgetStateProperty.resolveWith(
                  (states) => states.contains(WidgetState.disabled)
                      ? Colors.white24
                      : const Color(0xFFB0BEC5),
                ),
              ),
              child: const Text('取消'),
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => unawaited(_finish(context, save: true)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(busy ? '處理中' : '儲存'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PendingSaveBar extends StatelessWidget {
  const _PendingSaveBar({required this.mission});

  final MissionMockProvider mission;

  @override
  Widget build(BuildContext context) {
    final busy = mission.recordCommandPending;
    return Material(
      color: const Color(0xFFE65100).withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(18),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            const Icon(AppIcons.save, color: Colors.white, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '${mission.pendingRecordSaveTitle}已停止，但尚未儲存',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: busy
                  ? null
                  : () => unawaited(mission.retryPendingRecordSave()),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: const Color(0xFFE65100),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(AppIcons.refreshCw, size: 16),
              label: Text(busy ? '儲存中' : '重試'),
            ),
          ],
        ),
      ),
    );
  }
}
