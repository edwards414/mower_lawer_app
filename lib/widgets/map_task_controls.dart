import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';
import 'execution_control_sheet.dart';
import 'map_objects_sheet.dart';
import 'map_record_bar.dart';
import 'planning_control_sheet.dart';

/// Where the work on the map stands, read off the mission. It picks the
/// floating buttons and the 設定 sheet; there are no tabs to pick.
enum TaskPhase {
  /// No zone yet: nothing to show, the + at the top right is the way in.
  none,
  recording,
  pendingSave,

  /// Zones exist but none is selected.
  pick,
  unplanned,
  planning,
  planned,
  starting,
  running,
  stopping,

  /// A stopped mission the robot could continue.
  resumable,
}

/// The selected zone (the one [MissionMockProvider.selectedZoneId] names), or
/// null when it names none.
MissionZone? selectedZoneOf(MissionMockProvider mission) {
  for (final zone in mission.zones) {
    if (zone.id == mission.selectedZoneId) return zone;
  }
  return null;
}

/// Whether the selected zone has a path to mow, the way 開始 judges it: the
/// planner's flag in the demo (which sets no per-zone flags), the zone's own
/// path live.
bool selectedZonePlanned(MissionMockProvider mission) {
  final zone = selectedZoneOf(mission);
  if (zone == null) return false;
  return mission.mockDataEnabled ? mission.coverageReady : zone.hasCoveragePath;
}

TaskPhase taskPhaseOf(MissionMockProvider mission) {
  if (mission.recordingType != null) return TaskPhase.recording;
  if (mission.hasPendingRecordSave) return TaskPhase.pendingSave;
  if (mission.cancelRequestInFlight || mission.cancelPending) {
    return TaskPhase.stopping;
  }
  final active =
      mission.navStatus == NavMockStatus.executing ||
      mission.navStatus == NavMockStatus.paused ||
      mission.zoneSequenceRunning;
  if (active) return TaskPhase.running;
  if (mission.navCommandPending) return TaskPhase.starting;
  if (mission.zones.isEmpty) return TaskPhase.none;
  if (mission.planningMutationPending) return TaskPhase.planning;
  if (mission.resumableCoverage != null) return TaskPhase.resumable;
  if (selectedZoneOf(mission) == null) return TaskPhase.pick;
  return selectedZonePlanned(mission) ? TaskPhase.planned : TaskPhase.unplanned;
}

/// Whether the floating buttons show. A zone's buttons wait for the operator
/// to tap that zone on the map; whatever is under way (a recording, a
/// mission, a stop) keeps its buttons in view, so 儲存 and 停止 are always
/// there.
bool taskControlsShown(TaskPhase phase, {required bool zoneFocused}) =>
    switch (phase) {
      TaskPhase.none || TaskPhase.pick => false,
      TaskPhase.unplanned ||
      TaskPhase.planning ||
      TaskPhase.planned => zoneFocused,
      _ => true,
    };

/// Whether the phase has a 設定 sheet.
bool taskHasDetails(TaskPhase phase) => switch (phase) {
  TaskPhase.none ||
  TaskPhase.pick ||
  TaskPhase.recording ||
  TaskPhase.pendingSave => false,
  _ => true,
};

/// The 設定 sheet: the existing panels for the phase. It follows the mission,
/// so it changes with the phase while it is open.
class TaskDetailsSheet extends StatelessWidget {
  const TaskDetailsSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final phase = taskPhaseOf(context.watch<MissionMockProvider>());
    final Widget body = switch (phase) {
      TaskPhase.starting ||
      TaskPhase.running ||
      TaskPhase.stopping ||
      TaskPhase.resumable => const ExecutionControlSheet(),
      TaskPhase.planned => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          PlanningControlSheet(),
          _SheetDivider(),
          ExecutionControlSheet(),
          _SheetDivider(),
          MapObjectsSheet(),
        ],
      ),
      TaskPhase.unplanned || TaskPhase.planning => const Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [PlanningControlSheet(), _SheetDivider(), MapObjectsSheet()],
      ),
      _ => const MapObjectsSheet(),
    };
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.8,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFFD0D7DA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            body,
          ],
        ),
      ),
    );
  }
}

class _SheetDivider extends StatelessWidget {
  const _SheetDivider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 32, color: Color(0xFFE3E8EA));
}

const _green = Color(0xFF167A4A);
const _danger = Color(0xFFB9322A);
const _amber = Color(0xFF8F5400);
const _ink2 = Color(0xFF5C6B64);

/// The floating buttons over the map, just above the right joystick: one
/// main action for the phase, and 設定 (or ✕ while recording) beside it.
class MapTaskControls extends StatelessWidget {
  const MapTaskControls({
    super.key,
    required this.phase,
    required this.onDetails,
    required this.beforeModal,
    this.snackBottom,
  });

  final TaskPhase phase;

  /// Opens the 設定 sheet.
  final VoidCallback onDetails;

  /// Called before a dialog opens over the map, so the sticks stop first.
  final VoidCallback beforeModal;

  /// Snackbars float above this.
  final double? snackBottom;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final busyRecord = mission.recordCommandPending;
    final _MainButton? main = switch (phase) {
      TaskPhase.none || TaskPhase.pick => null,
      TaskPhase.recording => _MainButton(
        icon: AppIcons.save,
        label: busyRecord ? '處理中' : '儲存',
        busy: busyRecord,
        onTap: () => unawaited(
          finishRecordingWithFeedback(
            context,
            mission,
            save: true,
            clearBottom: snackBottom,
          ),
        ),
      ),
      TaskPhase.pendingSave => _MainButton(
        icon: AppIcons.refreshCw,
        label: busyRecord ? '儲存中' : '重試儲存',
        gradient: AppStyle.warnGradient,
        busy: busyRecord,
        onTap: () => unawaited(
          retrySaveWithFeedback(context, mission, clearBottom: snackBottom),
        ),
      ),
      TaskPhase.unplanned => _MainButton(
        icon: AppIcons.spline,
        label: '生成路徑',
        blockedReason: mission.canMutatePlanning ? null : '現在不能生成路徑',
        onTap: () => mission.runPlanningStep('coverage'),
      ),
      TaskPhase.planning => const _MainButton(
        icon: AppIcons.spline,
        label: '生成中',
        busy: true,
      ),
      TaskPhase.planned => _MainButton(
        icon: AppIcons.play,
        label: '開始割草',
        blockedReason: _startBlock(mission),
        onTap: () => unawaited(_confirmStart(context, mission, beforeModal)),
      ),
      TaskPhase.starting => const _MainButton(
        icon: AppIcons.play,
        label: '開始中',
        busy: true,
      ),
      TaskPhase.running => _MainButton(
        icon: AppIcons.square,
        label: '停止',
        gradient: AppStyle.stopGradient,
        blockedReason: _canCancel(mission) ? null : '現在不能停止，請稍候',
        onTap: () {
          beforeModal();
          unawaited(confirmStopMowing(context, mission));
        },
      ),
      TaskPhase.stopping => const _MainButton(
        icon: AppIcons.square,
        label: '停止中',
        gradient: AppStyle.stopGradient,
        busy: true,
      ),
      // The 執行 panel holds 繼續割草, with its own checks and choice.
      TaskPhase.resumable => _MainButton(
        icon: AppIcons.play,
        label: '繼續割草',
        onTap: onDetails,
      ),
    };
    if (main == null) return const SizedBox.shrink();
    final _RoundButton? side = phase == TaskPhase.recording
        ? _RoundButton(
            icon: AppIcons.x,
            tooltip: '取消記錄',
            onTap: busyRecord
                ? null
                : () => unawaited(
                    _confirmCancelRecording(
                      context,
                      mission,
                      beforeModal,
                      snackBottom,
                    ),
                  ),
          )
        : taskHasDetails(phase)
        ? _RoundButton(
            icon: AppIcons.slidersHorizontal,
            tooltip: '任務設定',
            onTap: onDetails,
          )
        : null;
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.15,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (side != null) ...[side, const SizedBox(width: 10)],
          _withBlockedTap(context, main),
        ],
      ),
    );
  }

  /// A blocked main button still answers a tap: with why it is blocked.
  Widget _withBlockedTap(BuildContext context, _MainButton main) {
    final reason = main.blockedReason;
    if (reason == null) return main;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(reason),
            behavior: snackBottom == null ? null : SnackBarBehavior.floating,
            margin: snackBottom == null
                ? null
                : EdgeInsets.fromLTRB(16, 0, 16, snackBottom!),
          ),
        ),
      child: main,
    );
  }

  /// 開始割草 follows the 執行 panel: every zone in order when that is picked.
  static bool _runAll(MissionMockProvider mission) =>
      mission.zones.length >= 2 && mission.runAllZones;

  static String? _startBlock(MissionMockProvider mission) => _runAll(mission)
      ? mission.zoneSequenceBlockReason
      : mission.startBlockReason;

  /// The same rule as the 執行 panel's 取消.
  static bool _canCancel(MissionMockProvider mission) {
    final executing = mission.navStatus == NavMockStatus.executing;
    final active = executing || mission.navStatus == NavMockStatus.paused;
    return !mission.cancelRequestInFlight &&
        !mission.cancelPending &&
        ((mission.mockDataEnabled && executing) ||
            (!mission.mockDataEnabled &&
                mission.rosConnected &&
                (active ||
                    mission.navCommandPending ||
                    mission.zoneSequenceRunning)));
  }

  static Future<void> _confirmCancelRecording(
    BuildContext context,
    MissionMockProvider mission,
    VoidCallback beforeModal,
    double? snackBottom,
  ) async {
    beforeModal();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消這次記錄？'),
        content: Text('已記下的 ${mission.recordPointCount} 點會被捨棄，地圖不會新增任何東西。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('繼續記錄'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: _danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('捨棄'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await finishRecordingWithFeedback(
        context,
        mission,
        save: false,
        clearBottom: snackBottom,
      );
    }
  }

  static Future<void> _confirmStart(
    BuildContext context,
    MissionMockProvider mission,
    VoidCallback beforeModal,
  ) async {
    beforeModal();
    final runAll = _runAll(mission);
    final zone = selectedZoneOf(mission);
    final mock = mission.mockDataEnabled;
    final online = mission.rosConnected && mission.robotOnline;
    final battery = mission.batteryPercent;
    final checks = <(String, String, bool?)>[
      ('區域', runAll ? '全部區域依序' : zone?.name ?? '—', true),
      ('路徑', '已生成', true),
      (
        '連線',
        mock
            ? '示範模式'
            : online
            ? '機器人在線'
            : '連線中斷',
        mock || online,
      ),
      (
        '定位',
        mock
            ? '示範模式'
            : mission.hasFreshGpsFix
            ? 'GPS 正常'
            : '沒有有效 GPS',
        mock || mission.hasFreshGpsFix,
      ),
      (
        '電量',
        battery == null ? '未知' : '${battery.round()}%',
        battery == null ? null : battery >= 20,
      ),
    ];
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('開始割草？'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value, good) in checks)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(
                      good == false ? AppIcons.triangleAlert : AppIcons.check,
                      size: 18,
                      color: good == null
                          ? _ink2
                          : good
                          ? _green
                          : _amber,
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 44,
                      child: Text(
                        label,
                        style: const TextStyle(
                          color: _ink2,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        value,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 10),
            const Text(
              '開始後搖桿會鎖住。要手動駕駛，請先停止任務。請確認割草區域內沒有人或寵物。',
              style: TextStyle(color: _ink2, fontSize: 13, height: 1.4),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('開始割草'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    if (runAll) {
      if (mission.canStartZoneSequence) {
        await startNewMission(context, mission, mission.startZoneSequence);
      }
    } else if (mission.canStartMission) {
      await startNewMission(context, mission, mission.startExecution);
    }
  }
}

/// While recording (or while a stopped recording still has to be saved): a
/// small status pill at the top of the map, under the robot status.
class MapRecordChip extends StatelessWidget {
  const MapRecordChip({super.key});

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final String text;
    final Color color;
    if (mission.recordingType != null) {
      final elapsed = mission.recordingElapsed;
      final mm = elapsed.inMinutes.toString().padLeft(2, '0');
      final ss = elapsed.inSeconds.remainder(60).toString().padLeft(2, '0');
      text =
          'REC $mm:$ss · ${mission.recordPointCount} 點 · '
          '${mission.recordingTitle}';
      color = AppStyle.danger;
    } else if (mission.hasPendingRecordSave) {
      text = '${mission.pendingRecordSaveTitle}已停止，但還沒存好';
      color = AppStyle.amber;
    } else {
      return const SizedBox.shrink();
    }
    final warning = mission.recordingType != null
        ? mission.recordingRtkWarning
        : null;
    return IgnorePointer(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A white pill, its dot in the state's colour.
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(999),
              boxShadow: AppStyle.floatShadow,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 14, 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      boxShadow: [BoxShadow(color: color, blurRadius: 6)],
                    ),
                    child: const SizedBox.square(dimension: 9),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppStyle.ink,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (warning != null) ...[
            const SizedBox(height: 6),
            Semantics(
              liveRegion: true,
              child: DecoratedBox(
                key: const ValueKey('record-rtk-pause'),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF1DC),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFFF5C77E)),
                  boxShadow: AppStyle.floatShadow,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 6,
                  ),
                  child: Text(
                    warning,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF7A4300),
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 停止 (the floating button and the locked sticks): a real cancel of the
/// navigation, asked first. The sticks unlock only once the robot confirms
/// the stop.
Future<void> confirmStopMowing(
  BuildContext context,
  MissionMockProvider mission, {
  bool fromSticks = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(fromSticks ? '割草中，搖桿已鎖住' : '停止割草？'),
      content: Text(
        fromSticks
            ? '割草機正在自動割草。要手動駕駛，得先停止任務。\n\n'
                  '停止後，要等機器人確認導航已取消、任務真的停了，搖桿才會解鎖。'
                  '這是取消任務，不是暫停；之後可以在「設定」從停下的地方繼續割草。'
            : '割草機會停下並取消這次導航。之後可以在「設定」從停下的地方繼續割草。',
        style: const TextStyle(height: 1.45),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(fromSticks ? '繼續割草' : '取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: _danger),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('停止任務'),
        ),
      ],
    ),
  );
  if (ok == true) mission.cancelExecution();
}

/// The main floating action, in the home page's style: a rounded button
/// with a gradient by what it does (green go, red stop, amber retry) and a
/// glow of its colour. Busy, it spins and does nothing; blocked, it greys
/// out (the caller says why on a tap).
class _MainButton extends StatelessWidget {
  const _MainButton({
    required this.icon,
    required this.label,
    this.onTap,
    this.gradient = AppStyle.goGradient,
    this.busy = false,
    this.blockedReason,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final LinearGradient gradient;
  final bool busy;
  final String? blockedReason;

  @override
  Widget build(BuildContext context) {
    final enabled = !busy && blockedReason == null && onTap != null;
    final fill = blockedReason != null ? AppStyle.offGradient : gradient;
    final radius = BorderRadius.circular(20);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: fill,
        boxShadow: AppStyle.glow(fill.colors.last),
      ),
      child: Material(
        type: MaterialType.transparency,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? onTap : null,
          child: SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (busy)
                    const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2.4,
                        color: Colors.white,
                      ),
                    )
                  else
                    Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(width: 10),
                  Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // Like the map's left-hand buttons.
    return Tooltip(
      message: tooltip,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: AppStyle.floatShadow,
        ),
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: 52,
              child: Icon(
                icon,
                size: 22,
                color: onTap == null ? Colors.black26 : AppStyle.ink,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
