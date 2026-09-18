import 'dart:async';

import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../models/paired_robot.dart';
import '../providers/mission_mock_provider.dart';
import '../providers/robot_info_provider.dart';
import '../providers/robot_registry.dart';
import '../services/backend_client.dart';
import '../services/rosbridge_service.dart';

const _kGreen = Color(0xFF167A4A);
const _kGrey = Color(0xFF78909C);
const _kBad = Color(0xFFC62828);

/// "我的機器人": paired robots, which one is active, LAN/relay choice,
/// pairing by QR code (or pasted code) and unpairing.
class RobotsScreen extends StatefulWidget {
  const RobotsScreen({super.key});

  @override
  State<RobotsScreen> createState() => _RobotsScreenState();
}

class _RobotsScreenState extends State<RobotsScreen> {
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    // Backend presence of every paired robot, while this page is open.
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshNow());
    _refresh = Timer.periodic(const Duration(seconds: 15), (_) => _refreshNow());
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

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F8),
      appBar: AppBar(
        title: const Text('我的機器人'),
        backgroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 32),
        children: [
          if (robots.isEmpty)
            const _EmptyHint()
          else
            for (final r in robots) ...[
              _RobotCard(
                robot: r,
                active: registry.active?.id == r.id,
                route: registry.active?.id == r.id ? registry.activeRoute : '',
                connected: mission.rosConnected,
                online: mission.robotOnline,
                reportedId: registry.reportedRobotId,
                mismatch: registry.active?.id == r.id && registry.identityMismatch,
                infoName: registry.active?.id == r.id ? info.info?.robotId : null,
                backendStatus: registry.statusOf(r.id),
                backendError: registry.statusErrorOf(r.id),
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
          const SizedBox(height: 18),
          const Text(
            'QR code 在機器人上執行 `sudo mower-pair` 取得。掃描後 App 會記住這台機器人，'
            '每次連線都用配對密鑰驗證；解除配對或在機器人上 `mower-pair --rotate` 會使舊配對失效。',
            style: TextStyle(color: _kGrey, fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  static Future<void> _startPairing(BuildContext context) async {
    final code = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const PairScanScreen()),
    );
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
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

class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: const Column(
        children: [
          Icon(AppIcons.bot, size: 40, color: _kGrey),
          SizedBox(height: 8),
          Text('還沒有配對的機器人', style: TextStyle(fontWeight: FontWeight.w900)),
          SizedBox(height: 4),
          Text(
            '在機器人上執行 sudo mower-pair，掃描印出的 QR code。',
            textAlign: TextAlign.center,
            style: TextStyle(color: _kGrey, fontWeight: FontWeight.w700, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _RobotCard extends StatelessWidget {
  const _RobotCard({
    required this.robot,
    required this.active,
    required this.route,
    required this.connected,
    required this.online,
    required this.reportedId,
    required this.mismatch,
    required this.infoName,
    required this.backendStatus,
    required this.backendError,
  });

  final PairedRobot robot;
  final bool active;

  /// 'lan' / 'relay' for the active robot, '' otherwise.
  final String route;
  final bool connected;
  final bool online;
  final String? reportedId;
  final bool mismatch;
  final String? infoName;
  final RobotStatus? backendStatus;
  final String? backendError;

  String get _routeLabel {
    if (active && route == 'lan') return 'LAN ${robot.lanAddress}';
    if (active && route == 'relay') return '遠端 relay';
    if (active && robot.hasRelay && robot.hasLan) return '偵測 LAN 中…';
    if (robot.usesLan) return 'LAN ${robot.lanAddress}';
    if (robot.hasRelay) return '遠端 relay';
    return '沒有位址';
  }

  String? get _backendLine {
    final s = backendStatus;
    if (s != null) {
      final seen = s.lastSeen;
      final ago = seen == null ? '' : ' · ${_ago(DateTime.now().difference(seen))}';
      final lan = s.lan.isNotEmpty ? ' · LAN ${s.lan}' : '';
      return s.online ? '後台：在線$ago$lan' : '後台：離線$ago';
    }
    final e = backendError;
    if (e != null) return '後台：$e';
    return null;
  }

  static String _ago(Duration d) {
    if (d.inSeconds < 60) return '${d.inSeconds} 秒前';
    if (d.inMinutes < 60) return '${d.inMinutes} 分鐘前';
    if (d.inHours < 48) return '${d.inHours} 小時前';
    return '${d.inDays} 天前';
  }

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
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: active ? Border.all(color: _kGreen, width: 1.5) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(AppIcons.bot, color: active ? _kGreen : _kGrey),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(robot.displayName, style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
                    Text(
                      '${robot.id} · $_routeLabel',
                      style: const TextStyle(color: _kGrey, fontWeight: FontWeight.w700, fontSize: 12),
                    ),
                    if (_backendLine != null)
                      Text(
                        _backendLine!,
                        style: TextStyle(
                          color: backendStatus?.online == true ? _kGreen : _kGrey,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
              Text(status, style: TextStyle(color: statusColor, fontWeight: FontWeight.w900, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!active)
                TextButton(onPressed: () => registry.select(robot.id), child: const Text('使用這台')),
              if (robot.hasRelay && robot.hasLan)
                TextButton(
                  onPressed: () => registry.update(robot.id, preferLan: !robot.preferLan),
                  child: Text(robot.preferLan ? '自動選路' : '固定走 LAN'),
                ),
              TextButton(onPressed: () => _editLan(context, robot), child: const Text('LAN 位址')),
              TextButton(onPressed: () => _rename(context, robot), child: const Text('改名')),
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

  Future<void> _editLan(BuildContext context, PairedRobot robot) async {
    final controller = TextEditingController(text: robot.lanAddress);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('LAN 位址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(hintText: '192.168.0.113'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('儲存')),
        ],
      ),
    );
    if (value == null || !context.mounted) return;
    if (value.isNotEmpty && RosbridgeService.validateRobotIp(value) != null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('請輸入有效的 IPv4 位址')));
      return;
    }
    await context.read<RobotRegistry>().update(
      robot.id,
      lanAddress: value,
      preferLan: value.isNotEmpty && !robot.hasRelay ? true : null,
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
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('儲存')),
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
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('解除')),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      await context.read<RobotRegistry>().remove(robot.id);
    }
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
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }
}
