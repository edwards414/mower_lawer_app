import 'dart:async';

import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../models/paired_robot.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/robot_info_provider.dart';
import '../providers/robot_registry.dart';
import '../services/rosbridge_service.dart';

const _kGreen = Color(0xFF167A4A);
const _kGrey = Color(0xFF78909C);
const _kBad = Color(0xFFC62828);

/// True while changing the connection or data source would disturb a live
/// operation (mission, recording, manual drive, pending save).
bool connectionSettingsLocked(MissionMockProvider mission) {
  return mission.connectionSettingsPending ||
      mission.planningMutationPending ||
      mission.navCommandPending ||
      mission.cancelPending ||
      mission.navStatus == NavMockStatus.executing ||
      mission.navStatus == NavMockStatus.paused ||
      mission.recordingType != null ||
      mission.recordCommandPending ||
      mission.manualControlActive ||
      mission.hasPendingRecordSave;
}

/// "我的機器人" on the 設定 tab, the app's one settings page: paired robots,
/// which one is active, its 直連 IP, pairing by QR code (or pasted code) and
/// unpairing. Without a paired robot the 直連 IP is the manual development
/// connection instead.
class RobotSettingsSection extends StatefulWidget {
  const RobotSettingsSection({super.key, required this.visible});

  /// The 設定 tab is on screen; backend presence is only polled then.
  final bool visible;

  @override
  State<RobotSettingsSection> createState() => _RobotSettingsSectionState();
}

class _RobotSettingsSectionState extends State<RobotSettingsSection> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    if (widget.visible) _startRefresh();
  }

  @override
  void didUpdateWidget(RobotSettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.visible == oldWidget.visible) return;
    if (widget.visible) {
      _startRefresh();
    } else {
      _refresh?.cancel();
      _refresh = null;
    }
  }

  /// Backend presence of every paired robot, while the tab is on screen.
  void _startRefresh() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshNow());
    _refresh?.cancel();
    _refresh = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _refreshNow(),
    );
  }

  void _refreshNow() {
    if (!mounted) return;
    unawaited(context.read<RobotRegistry>().refreshAll());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final registry = context.watch<RobotRegistry>();
    final mission = context.watch<MissionMockProvider>();
    final info = context.watch<RobotInfoProvider>();
    final robots = registry.robots;
    final locked = connectionSettingsLocked(mission);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const AppSectionTitle('我的機器人'),
        if (robots.isEmpty)
          _EmptyHint(mission: mission, locked: locked)
        else
          for (final r in robots) ...[
            _RobotCard(
              key: ValueKey(r.id),
              robot: r,
              active: registry.active?.id == r.id,
              connected: mission.rosConnected,
              online: mission.robotOnline,
              reportedId: registry.reportedRobotId,
              mismatch:
                  registry.active?.id == r.id && registry.identityMismatch,
              infoName: registry.active?.id == r.id ? info.info?.robotId : null,
              // Re-routing the active robot reconnects; other robots are free.
              locked: registry.active?.id == r.id && locked,
            ),
            const SizedBox(height: 10),
          ],
        const SizedBox(height: 6),
        FilledButton.icon(
          onPressed: () => _startPairing(context),
          icon: const Icon(AppIcons.scanQrCode),
          label: const Text('掃描配對 QR code'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _pasteCode(context),
          icon: const Icon(AppIcons.clipboardPaste),
          label: const Text('手動輸入配對碼'),
        ),
      ],
    );
  }

  static Future<void> _startPairing(BuildContext context) async {
    final code = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const PairScanScreen()));
    if (code == null || !context.mounted) return;
    await _pair(context, code);
  }

  static Future<void> _pasteCode(BuildContext context) async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('輸入配對碼'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          decoration: const InputDecoration(
            hintText: 'https://mower.fxrbindi.com/pair?id=MW-…&s=…',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('配對'),
          ),
        ],
      ),
    );
    if (code == null || !context.mounted) return;
    await _pair(context, code);
  }

  static Future<void> _pair(BuildContext context, String code) async {
    final registry = context.read<RobotRegistry>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final robot = await registry.pairFromText(code);
      messenger.showSnackBar(
        SnackBar(content: Text('已配對 ${robot.displayName}（${robot.id}）')),
      );
    } on FormatException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('配對失敗：${e.message}')));
    }
  }
}

/// The home page's panels; the robot in use has a green edge.
BoxDecoration _cardDecoration({bool active = false}) => BoxDecoration(
  color: Colors.white,
  borderRadius: BorderRadius.circular(20),
  border: active ? Border.all(color: _kGreen, width: 1.5) : null,
  boxShadow: AppStyle.panelShadow,
);

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.mission, required this.locked});

  final MissionMockProvider mission;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final host = mission.robotIp;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: _cardDecoration(),
      child: Column(
        children: [
          const AppIconTile(AppIcons.bot, color: AppStyle.muted),
          const SizedBox(height: 10),
          const Text(
            '還沒有配對的機器人',
            style: TextStyle(
              color: AppStyle.ink,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 14),
          _DirectIpField(
            saved: RosbridgeService.validateRobotIp(host) == null ? host : '',
            allowEmpty: false,
            locked: locked,
            onSave: (ip) async {
              final messenger = ScaffoldMessenger.of(context);
              final error = await mission.updateRobotIp(ip);
              if (error == null) {
                messenger.showSnackBar(
                  const SnackBar(content: Text('直連 IP 已更新')),
                );
              }
              return error;
            },
          ),
        ],
      ),
    );
  }
}

class _RobotCard extends StatelessWidget {
  const _RobotCard({
    super.key,
    required this.robot,
    required this.active,
    required this.connected,
    required this.online,
    required this.reportedId,
    required this.mismatch,
    required this.infoName,
    required this.locked,
  });

  final PairedRobot robot;
  final bool active;

  final bool connected;
  final bool online;
  final String? reportedId;
  final bool mismatch;
  final String? infoName;

  /// Changing the 直連 IP now would disturb a live operation.
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final registry = context.read<RobotRegistry>();
    final String status;
    final Color statusColor;
    if (!active) {
      status = '未選取';
      statusColor = _kGrey;
    } else if (mismatch) {
      status = '連到的是 $reportedId，不是這台';
      statusColor = _kBad;
    } else if (online) {
      status = '在線';
      statusColor = _kGreen;
    } else if (connected) {
      status = '已連線，等待 heartbeat';
      statusColor = _kGrey;
    } else {
      status = '連線中…';
      statusColor = _kGrey;
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardDecoration(active: active),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIconTile(
                AppIcons.bot,
                color: active ? _kGreen : AppStyle.muted,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  robot.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppStyle.ink,
                    fontWeight: FontWeight.w700,
                    fontSize: 17,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Status on a tag of its colour.
              Flexible(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    child: Text(
                      status,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: statusColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _DirectIpField(
            saved: robot.directAddress,
            allowEmpty: true,
            locked: locked,
            onSave: (ip) async {
              final messenger = ScaffoldMessenger.of(context);
              await registry.update(robot.id, directAddress: ip);
              messenger.showSnackBar(
                SnackBar(content: Text(ip.isEmpty ? '已停用直連' : '直連 IP 已更新：$ip')),
              );
              return null;
            },
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              if (!active)
                TextButton(
                  onPressed: () => registry.select(robot.id),
                  child: const Text('使用這台'),
                ),
              TextButton(
                onPressed: () => _rename(context, robot),
                child: const Text('改名'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '解除配對',
                onPressed: () => _unpair(context, robot),
                icon: const Icon(AppIcons.unlink, color: _kBad),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _rename(BuildContext context, PairedRobot robot) async {
    final controller = TextEditingController(text: robot.name);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('機器人名稱'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('儲存'),
          ),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    await context.read<RobotRegistry>().update(robot.id, name: value);
  }

  Future<void> _unpair(BuildContext context, PairedRobot robot) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('解除配對 ${robot.displayName}？'),
        content: const Text('之後要再掃一次機器人的 QR code 才能連線。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('解除'),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<RobotRegistry>().remove(robot.id);
    }
  }
}

/// The one 直連 IP: the robot's LAN IP or its Tailscale IP, edited in place.
class _DirectIpField extends StatefulWidget {
  const _DirectIpField({
    required this.saved,
    required this.allowEmpty,
    required this.locked,
    required this.onSave,
  });

  /// The address in effect now.
  final String saved;

  /// Saving an empty field turns direct connection off.
  final bool allowEmpty;

  /// Reconnecting now would disturb a live operation.
  final bool locked;

  /// Applies the trimmed address; returns an error message or null.
  final Future<String?> Function(String ip) onSave;

  @override
  State<_DirectIpField> createState() => _DirectIpFieldState();
}

class _DirectIpFieldState extends State<_DirectIpField> {
  late final _controller = TextEditingController(text: widget.saved);
  String? _error;
  bool _saving = false;

  @override
  void didUpdateWidget(_DirectIpField oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Changed elsewhere: follow it unless the operator has started typing.
    if (widget.saved != oldWidget.saved &&
        _controller.text.trim() == oldWidget.saved) {
      _controller.text = widget.saved;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _canSave =>
      !_saving && !widget.locked && _controller.text.trim() != widget.saved;

  Future<void> _save() async {
    final ip = _controller.text.trim();
    final invalid = ip.isEmpty && widget.allowEmpty
        ? null
        : RosbridgeService.validateRobotIp(ip);
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    final error = await widget.onSave(ip);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _controller,
                keyboardType: TextInputType.url,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() => _error = null),
                onSubmitted: (_) {
                  if (_canSave) unawaited(_save());
                },
                decoration: InputDecoration(
                  labelText: '直連 IP',
                  hintText: '192.168.x.x 或 100.x.y.z',
                  errorText: _error,
                  isDense: true,
                  prefixIcon: const Icon(AppIcons.router),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton(
                onPressed: _canSave ? _save : null,
                // Why it cannot save, without a line of small print.
                child: Text(
                  widget.locked
                      ? '任務中'
                      : _saving
                      ? '儲存中'
                      : '儲存',
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Camera view that returns the first QR code it decodes.
class PairScanScreen extends StatefulWidget {
  const PairScanScreen({super.key});

  @override
  State<PairScanScreen> createState() => _PairScanScreenState();
}

class _PairScanScreenState extends State<PairScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final code in capture.barcodes) {
      final value = code.rawValue;
      if (value != null && value.contains('id=')) {
        _done = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('掃描機器人 QR code')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 3),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          const Positioned(
            left: 0,
            right: 0,
            bottom: 40,
            child: Text(
              '對準機器人上 sudo mower-pair 印出的 QR code',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
