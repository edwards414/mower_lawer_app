import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/robot_info.dart';
import '../providers/robot_info_provider.dart';
import '../providers/robot_registry.dart';
import '../services/rosbridge_service.dart';

const _kGreen = Color(0xFF167A4A);
const _kGrey = Color(0xFF78909C);
const _kWarn = Color(0xFFB26A00);
const _kBad = Color(0xFFC62828);

/// "版本與更新": one line saying whether the robot has the latest version, and
/// the update / check / restart actions that go with it. No version numbers:
/// the robot checks its own channel and reports the verdict. Lives in the
/// "設定" tab.
class RobotVersionCard extends StatelessWidget {
  const RobotVersionCard({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<RobotInfoProvider>();
    final info = provider.info;
    final status = provider.versionStatus;
    final canAct = _canAct(provider);
    // A check works while the robot moves, so it is not held back by `busy`.
    final canCheck =
        info != null &&
        !provider.stale &&
        !provider.actionPending &&
        !info.update.inProgress;
    // Next to the restart button: the update when there is something to
    // update (or it cannot be told), the check when it has not been looked up.
    final checkSupported =
        (info?.apiVersion ?? 0) >= 2 && !provider.checkUpdateUnsupported;
    final offer = switch (status) {
      VersionStatus.newerAvailable ||
      VersionStatus.updateFailed ||
      VersionStatus.firmwareFailed ||
      VersionStatus.robotTooOld => _Offer.update,
      VersionStatus.notChecked || VersionStatus.checkFailed =>
        checkSupported ? _Offer.check : _Offer.update,
      _ => _Offer.none,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '版本與更新',
          style: TextStyle(fontWeight: FontWeight.w900, fontSize: 16),
        ),
        const SizedBox(height: 12),
        _StatusLine(status),
        const SizedBox(height: 14),
        Row(
          children: [
            if (offer == _Offer.update) ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: canAct
                      ? () => _confirmUpdate(context, provider)
                      : null,
                  icon: const Icon(AppIcons.download),
                  // Why it is greyed out, without a line of small print.
                  label: Text(info?.busy ?? false ? '機器人忙碌中' : '更新機器人'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            if (offer == _Offer.check) ...[
              Expanded(
                child: FilledButton.icon(
                  onPressed: canCheck
                      ? () =>
                            _run(context, provider, provider.requestCheckUpdate)
                      : null,
                  icon: const Icon(AppIcons.refreshCw),
                  label: const Text('檢查更新'),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canAct
                    ? () => _confirmAndRun(
                        context,
                        provider: provider,
                        title: '重新啟動機器人軟體',
                        body: '重新啟動 ROS 容器（不更新）。機器人會離線約 1 分鐘。',
                        action: provider.requestRestart,
                      )
                    : null,
                icon: const Icon(AppIcons.rotateCcw),
                label: const Text('重新啟動'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

bool _canAct(RobotInfoProvider p) {
  final info = p.info;
  return info != null &&
      !p.stale &&
      !p.actionPending &&
      !info.busy &&
      !info.update.inProgress;
}

/// Runs a robot action. The card shows state, not messages, so a request the
/// robot refused (busy, the bridge says no) is reported here, once.
Future<void> _run(
  BuildContext context,
  RobotInfoProvider provider,
  Future<RosbridgeServiceResponse> Function() action,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result = await action();
  if (!result.success) {
    messenger.showSnackBar(
      SnackBar(content: Text(provider.lastActionResult ?? result.message)),
    );
  }
}

Future<void> _confirmAndRun(
  BuildContext context, {
  required RobotInfoProvider provider,
  required String title,
  required String body,
  required Future<RosbridgeServiceResponse> Function() action,
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
  if (ok == true && context.mounted) {
    await _run(context, provider, action);
  }
}

/// Asks, then has the robot pull its channel and restart.
Future<void> _confirmUpdate(BuildContext context, RobotInfoProvider provider) {
  final tag = provider.info?.imageTag ?? '';
  return _confirmAndRun(
    context,
    provider: provider,
    title: '更新機器人',
    body:
        '機器人會下載目前頻道（${tag.isEmpty ? 'stable' : tag}）的新版本並重新啟動，'
        '同時把 STM32 韌體換成該版本內附的。過程約 1–3 分鐘，期間無法操作。',
    action: provider.requestUpdate,
  );
}

/// The action offered beside 重新啟動.
enum _Offer { none, update, check }

/// The one line the card is about: an icon and the verdict, at full size.
class _StatusLine extends StatelessWidget {
  const _StatusLine(this.status);

  final VersionStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (status) {
      VersionStatus.upToDate => (AppIcons.circleCheck, _kGreen, '已是最新版'),
      VersionStatus.newerAvailable => (AppIcons.cloudDownload, _kWarn, '有新版本'),
      VersionStatus.updating => (AppIcons.refreshCw, _kGreen, '更新中…'),
      VersionStatus.updateFailed => (AppIcons.circleAlert, _kBad, '上次更新失敗'),
      VersionStatus.firmwareFailed => (AppIcons.circleAlert, _kBad, '韌體燒錄失敗'),
      VersionStatus.firmwareMismatch => (
        AppIcons.triangleAlert,
        _kWarn,
        '韌體版本不符，請重新啟動',
      ),
      VersionStatus.robotTooOld => (
        AppIcons.triangleAlert,
        _kBad,
        '機器人版本太舊，請更新',
      ),
      VersionStatus.appTooOld => (
        AppIcons.triangleAlert,
        _kBad,
        'App 版本太舊，請更新 App',
      ),
      VersionStatus.checkFailed => (AppIcons.circleAlert, _kGrey, '無法檢查更新'),
      VersionStatus.notChecked => (AppIcons.info, _kGrey, '尚未檢查更新'),
      VersionStatus.offline => (AppIcons.wifiOff, _kGrey, '尚未連線到機器人'),
    };
    return Row(
      children: [
        Icon(icon, color: color, size: 26),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
        ),
      ],
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
              const Icon(AppIcons.triangleAlert, color: _kWarn),
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
                  // The same ask-first, report-a-refusal path as the card.
                  onPressed: _canAct(provider)
                      ? () => _confirmUpdate(context, provider)
                      : null,
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

/// Wraps an operating page (the map, manual mode included): when the robot's
/// API is outside what this app supports, the page is dimmed and blocked until
/// the operator updates or explicitly overrides.
class CompatibilityGate extends StatelessWidget {
  const CompatibilityGate({
    super.key,
    required this.child,
    this.onShowVersions,
  });

  final Widget child;
  final VoidCallback? onShowVersions;

  @override
  Widget build(BuildContext context) {
    final blocked = context.select<RobotInfoProvider, bool>(
      (p) => p.blocksOperation,
    );
    final mismatch = context.select<RobotRegistry, bool>(
      (r) => r.identityMismatch,
    );
    if (!blocked && !mismatch) return child;
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
                // Robot settings and versions share the 設定 tab.
                child: mismatch
                    ? IdentityMismatchNotice(onOpenSettings: onShowVersions)
                    : CompatibilityNotice(onShowVersions: onShowVersions),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The robot we reached is not the one this phone paired with (relay or
/// LAN address points at another machine). Operation stays blocked until
/// the operator picks the right robot.
class IdentityMismatchNotice extends StatelessWidget {
  const IdentityMismatchNotice({super.key, this.onOpenSettings});

  /// Switches to the robot settings (設定 tab); no button when null.
  final VoidCallback? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<RobotRegistry>();
    final active = registry.active;
    if (active == null || !registry.identityMismatch) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFFFFEBEE),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFEF9A9A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(AppIcons.shieldX, color: _kBad),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  '連到的不是配對的機器人',
                  style: TextStyle(fontWeight: FontWeight.w900, color: _kBad),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '這個位址回報的是 ${registry.reportedRobotId}，但你配對的是 '
            '${active.displayName}（${active.id}）。檢查直連 IP / relay 設定，或改選正確的機器人。',
            style: const TextStyle(
              color: Color(0xFF7F1D1D),
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
          if (onOpenSettings != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onOpenSettings,
                child: const Text('我的機器人'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
