import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import '../models/robot_info.dart';
import '../providers/robot_info_provider.dart';

const _kGreen = Color(0xFF167A4A);
const _kGrey = Color(0xFF78909C);
const _kWarn = Color(0xFFB26A00);
const _kBad = Color(0xFFC62828);

/// App version from the bundle (once), shared by the widgets below.
final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();

String _appVersionLabel(PackageInfo? p) =>
    p == null ? '…' : '${p.version} (${p.buildNumber})';

/// Versions of the three moving parts (app, robot software, STM32 firmware)
/// plus the host update state and the update / restart actions. Lives in the
/// "更多" tab.
class RobotVersionCard extends StatelessWidget {
  const RobotVersionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RobotInfoProvider>();
    final info = provider.info;
    final stale = provider.stale;

    return FutureBuilder<PackageInfo>(
      future: _packageInfo,
      builder: (context, snapshot) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '版本與更新',
              style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
            ),
            const SizedBox(height: 10),
            _VersionRow(
              icon: Icons.phone_iphone,
              title: 'App',
              detail:
                  '${_appVersionLabel(snapshot.data)} · 支援機器人 API '
                  '${kMinRobotApiVersion == kMaxRobotApiVersion ? kMinRobotApiVersion : '$kMinRobotApiVersion–$kMaxRobotApiVersion'}',
            ),
            _VersionRow(
              icon: Icons.memory,
              title: '機器人軟體',
              detail: info == null
                  ? '尚未收到 /robot/info'
                  : '${info.software.label}'
                        '${info.imageTag.isEmpty ? '' : ' · ${info.imageTag}'}'
                        ' · API ${info.apiVersion}',
              trailing: _CompatibilityChip(provider.compatibility),
              muted: stale,
            ),
            _VersionRow(
              icon: Icons.developer_board,
              title: 'STM32 韌體',
              detail: info == null
                  ? '—'
                  : _firmwareDetail(info),
              trailing: info == null
                  ? null
                  : _FirmwareChip(info),
              muted: stale,
            ),
            if (info != null && info.update.state.isNotEmpty)
              _VersionRow(
                icon: info.update.failed
                    ? Icons.error_outline
                    : info.update.inProgress
                    ? Icons.downloading
                    : Icons.check_circle_outline,
                title: '更新狀態',
                detail: '${_updateStateLabel(info.update.state)}'
                    '${info.update.message.isEmpty ? '' : ' · ${info.update.message}'}',
                muted: stale,
              ),
            if (provider.lastActionResult != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  provider.lastActionResult!,
                  style: const TextStyle(
                    color: _kGrey,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _canAct(provider) ? () => _confirmAndRun(
                            context,
                            title: '更新機器人',
                            body:
                                '機器人會下載目前頻道（${info?.imageTag.isEmpty ?? true ? 'stable' : info!.imageTag}）的新版本並重新啟動，'
                                '同時把 STM32 韌體換成該版本內附的。過程約 1–3 分鐘，期間無法操作。',
                            action: provider.requestUpdate,
                          )
                        : null,
                    icon: const Icon(Icons.system_update_alt),
                    label: const Text('更新機器人'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _canAct(provider) ? () => _confirmAndRun(
                            context,
                            title: '重新啟動機器人軟體',
                            body: '重新啟動 ROS 容器（不更新）。機器人會離線約 1 分鐘。',
                            action: provider.requestRestart,
                          )
                        : null,
                    icon: const Icon(Icons.restart_alt),
                    label: const Text('重新啟動'),
                  ),
                ),
              ],
            ),
            if (info != null && info.busy)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '機器人移動或導航中，先停止才能更新。',
                  style: TextStyle(
                    color: _kWarn,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  static bool _canAct(RobotInfoProvider p) {
    final info = p.info;
    return info != null &&
        !p.stale &&
        !p.actionPending &&
        !info.busy &&
        !info.update.inProgress;
  }

  static String _firmwareDetail(RobotInfo info) {
    final running = info.firmwareRunning;
    final bundled = info.firmwareBundled;
    if (running.isEmpty && bundled.isEmpty) return '沒有韌體資訊';
    final parts = <String>[
      '執行中 ${running.label}',
      if (!bundled.isEmpty && info.firmwareUpToDate != true)
        '內附 ${bundled.label}',
      if (info.firmwareSyncError.isNotEmpty) '燒錄錯誤：${info.firmwareSyncError}',
    ];
    return parts.join(' · ');
  }

  static String _updateStateLabel(String state) {
    switch (state) {
      case 'idle':
        return '閒置';
      case 'pulling':
        return '下載中';
      case 'restarting':
        return '重新啟動中';
      case 'up_to_date':
        return '已是最新';
      case 'failed':
        return '失敗';
      case 'rebooting':
        return '主機重開中';
      case 'powering_off':
        return '關機中';
      default:
        return state;
    }
  }

  static Future<void> _confirmAndRun(
    BuildContext context, {
    required String title,
    required String body,
    required Future<Object?> Function() action,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('確定'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await action();
    }
  }
}

class _VersionRow extends StatelessWidget {
  const _VersionRow({
    required this.icon,
    required this.title,
    required this.detail,
    this.trailing,
    this.muted = false,
  });

  final IconData icon;
  final String title;
  final String detail;
  final Widget? trailing;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: muted ? _kGrey : _kGreen),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
                Text(
                  detail,
                  style: TextStyle(
                    color: muted ? const Color(0xFFB0BEC5) : _kGrey,
                    fontWeight: FontWeight.w700,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 8), trailing!],
        ],
      ),
    );
  }
}

class _CompatibilityChip extends StatelessWidget {
  const _CompatibilityChip(this.compatibility);

  final RobotCompatibility compatibility;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (compatibility) {
      RobotCompatibility.compatible => ('相容', _kGreen),
      RobotCompatibility.robotTooOld => ('機器人太舊', _kBad),
      RobotCompatibility.appTooOld => ('App 太舊', _kBad),
      RobotCompatibility.unknown => ('未知', _kGrey),
    };
    return _Chip(label: label, color: color);
  }
}

class _FirmwareChip extends StatelessWidget {
  const _FirmwareChip(this.info);

  final RobotInfo info;

  @override
  Widget build(BuildContext context) {
    if (info.firmwareSyncError.isNotEmpty ||
        info.firmwareSyncAction == 'failed') {
      return const _Chip(label: '燒錄失敗', color: _kBad);
    }
    return switch (info.firmwareUpToDate) {
      true => const _Chip(label: '最新', color: _kGreen),
      false => const _Chip(label: '版本不符', color: _kWarn),
      null => const _Chip(label: '未知', color: _kGrey),
    };
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w900,
          fontSize: 11,
        ),
      ),
    );
  }
}

/// Explains an API mismatch. Shown on the dashboard and inside
/// [CompatibilityGate].
class CompatibilityNotice extends StatelessWidget {
  const CompatibilityNotice({super.key, this.onShowVersions});

  final VoidCallback? onShowVersions;

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RobotInfoProvider>();
    final compatibility = provider.compatibility;
    if (compatibility == RobotCompatibility.compatible ||
        compatibility == RobotCompatibility.unknown) {
      return const SizedBox.shrink();
    }
    final info = provider.info!;
    final robotTooOld = compatibility == RobotCompatibility.robotTooOld;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF3E0),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFFFB74D)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: _kWarn),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  robotTooOld ? '機器人軟體太舊，請更新機器人' : 'App 太舊，請更新 App',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: _kWarn,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '機器人 API ${info.apiVersion}（${info.software.label}），'
            '這個 App 支援 $kMinRobotApiVersion–$kMaxRobotApiVersion。'
            '版本不合時任務與手動控制會停用。',
            style: const TextStyle(
              color: Color(0xFF6D4C41),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (onShowVersions != null)
                TextButton(
                  onPressed: onShowVersions,
                  child: const Text('查看版本'),
                ),
              if (robotTooOld)
                TextButton(
                  onPressed: provider.actionPending
                      ? null
                      : () => provider.requestUpdate(),
                  child: const Text('更新機器人'),
                ),
              const Spacer(),
              TextButton(
                onPressed: () => provider.setOverrideCompatibility(true),
                child: const Text('仍要繼續'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Wraps an operating page (map / manual control): when the robot's API is
/// outside what this app supports, the page is dimmed and blocked until the
/// operator updates or explicitly overrides.
class CompatibilityGate extends StatelessWidget {
  const CompatibilityGate({super.key, required this.child, this.onShowVersions});

  final Widget child;
  final VoidCallback? onShowVersions;

  @override
  Widget build(BuildContext context) {
    final blocked = context.select<RobotInfoProvider, bool>(
      (p) => p.blocksOperation,
    );
    if (!blocked) return child;
    return Stack(
      fit: StackFit.expand,
      children: [
        AbsorbPointer(child: Opacity(opacity: 0.35, child: child)),
        ColoredBox(
          color: Colors.black.withValues(alpha: 0.25),
          child: SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.all(22),
                child: CompatibilityNotice(onShowVersions: onShowVersions),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
