import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';
import '../services/rosbridge_service.dart';
import '../widgets/add_object_sheet.dart';
import '../widgets/execution_control_sheet.dart';
import '../widgets/map_objects_sheet.dart';
import '../widgets/mission_map_canvas.dart';
import '../widgets/mission_mode_bar.dart';
import '../widgets/operation_log_sheet.dart';
import '../widgets/planning_control_sheet.dart';
import '../widgets/record_control_sheet.dart';
import '../widgets/top_status_pill.dart';
import 'self_check_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _selfCheckComplete = false;

  @override
  Widget build(BuildContext context) {
    if (!_selfCheckComplete) {
      return SelfCheckScreen(
        onComplete: () => setState(() => _selfCheckComplete = true),
      );
    }

    final mission = context.watch<MissionMockProvider>();
    final media = MediaQuery.of(context);
    final size = media.size;
    final isLandscape = size.width > size.height;
    final panelHeight = isLandscape
        ? math.min(size.height * 0.5, 220.0)
        : math.min(size.height * 0.43, 370.0);

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: MissionMapCanvas(mission: mission, bottomInset: panelHeight),
          ),
          Positioned(
            top: media.padding.top + 10,
            left: 12,
            right: 76,
            child: const TopStatusPill(),
          ),
          Positioned(
            top: media.padding.top + 78,
            right: 12,
            child: _MapActionRail(
              onAdd: () => _showAppSheet(context, const AddObjectSheet()),
              onLayers: () => _showAppSheet(context, const _LayerToggleSheet()),
              onSettings: () =>
                  _showAppSheet(context, const _SettingsQuickSheet()),
              onManual: () =>
                  _showAppSheet(context, const _ManualControlSheet()),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: panelHeight,
            child: const _MissionBottomPanel(),
          ),
        ],
      ),
    );
  }

  void _showAppSheet(BuildContext context, Widget child) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return DecoratedBox(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
          ),
          child: child,
        );
      },
    );
  }
}

class _MapActionRail extends StatelessWidget {
  const _MapActionRail({
    required this.onAdd,
    required this.onLayers,
    required this.onSettings,
    required this.onManual,
  });

  final VoidCallback onAdd;
  final VoidCallback onLayers;
  final VoidCallback onSettings;
  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _RoundIconButton(
          icon: Icons.add,
          tooltip: '新增物件',
          color: const Color(0xFF1384E8),
          onTap: onAdd,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.layers_outlined,
          tooltip: '圖層',
          onTap: onLayers,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.settings_outlined,
          tooltip: '設定',
          onTap: onSettings,
        ),
        const SizedBox(height: 10),
        _RoundIconButton(
          icon: Icons.sports_esports_outlined,
          tooltip: '手動控制',
          onTap: onManual,
        ),
      ],
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? const Color(0xFF263238);
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.94),
        shape: const CircleBorder(),
        elevation: 7,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, color: foreground, size: 26),
          ),
        ),
      ),
    );
  }
}

class _MissionBottomPanel extends StatelessWidget {
  const _MissionBottomPanel();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        boxShadow: [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 24,
            offset: Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
          child: Column(
            children: [
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: const Color(0xFFD0D7DA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              const MissionModeBar(),
              const SizedBox(height: 10),
              Expanded(
                child: SingleChildScrollView(
                  physics: const BouncingScrollPhysics(),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    child: _ModePanel(
                      key: ValueKey(mission.selectedMode),
                      mode: mission.selectedMode,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ModePanel extends StatelessWidget {
  const _ModePanel({super.key, required this.mode});

  final MissionMode mode;

  @override
  Widget build(BuildContext context) {
    switch (mode) {
      case MissionMode.objects:
        return const MapObjectsSheet();
      case MissionMode.record:
        return const RecordControlSheet();
      case MissionMode.plan:
        return const PlanningControlSheet();
      case MissionMode.run:
        return const ExecutionControlSheet();
      case MissionMode.logs:
        return const OperationLogSheet();
    }
  }
}

class _LayerToggleSheet extends StatelessWidget {
  const _LayerToggleSheet();

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 18),
            const Text(
              '圖層',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 12),
            _LayerSwitch(
              title: '工作區',
              value: mission.layers.zones,
              onChanged: (value) => mission.updateLayer(zones: value),
            ),
            _LayerSwitch(
              title: '禁入區',
              value: mission.layers.risks,
              onChanged: (value) => mission.updateLayer(risks: value),
            ),
            _LayerSwitch(
              title: '通道',
              value: mission.layers.channels,
              onChanged: (value) => mission.updateLayer(channels: value),
            ),
            _LayerSwitch(
              title: '覆蓋路徑',
              value: mission.layers.coverage,
              onChanged: (value) => mission.updateLayer(coverage: value),
            ),
            _LayerSwitch(
              title: '風險線段',
              value: mission.layers.invalidSegments,
              onChanged: (value) => mission.updateLayer(invalidSegments: value),
            ),
          ],
        ),
      ),
    );
  }
}

class _LayerSwitch extends StatelessWidget {
  const _LayerSwitch({
    required this.title,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: const TextStyle(fontWeight: FontWeight.w800)),
      value: value,
      onChanged: onChanged,
    );
  }
}

class _SettingsQuickSheet extends StatefulWidget {
  const _SettingsQuickSheet();

  @override
  State<_SettingsQuickSheet> createState() => _SettingsQuickSheetState();
}

class _SettingsQuickSheetState extends State<_SettingsQuickSheet> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  bool _initialized = false;
  bool _saving = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) {
      return;
    }
    _ipController.text = context.read<MissionMockProvider>().robotIp;
    _initialized = true;
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 18),
            const Text(
              '設定',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 14),
            Form(
              key: _formKey,
              child: TextFormField(
                controller: _ipController,
                keyboardType: TextInputType.text,
                validator: (value) =>
                    RosbridgeService.validateRobotIp(value ?? ''),
                decoration: const InputDecoration(
                  labelText: '機器人 IP',
                  hintText: '192.168.1.100',
                  prefixIcon: Icon(Icons.router_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _saving ? null : () => _saveRobotIp(context),
                icon: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.wifi_tethering),
                label: Text(_saving ? '儲存中' : '儲存並重連'),
              ),
            ),
            const SizedBox(height: 16),
            _InfoRow(
              icon: Icons.link_outlined,
              title: 'rosbridge',
              detail: mission.rosbridgeUrl,
            ),
            _InfoRow(
              icon: Icons.storage_outlined,
              title: '資料來源',
              detail: mission.rosConnected
                  ? 'ROS 即時資料'
                  : mission.mockDataEnabled
                  ? 'Mock fallback'
                  : '等待 ROS 真實資料',
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'Mock 資料',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
              subtitle: Text(
                mission.mockDataEnabled
                    ? 'rosbridge 未連線時使用 demo fallback'
                    : '關閉 demo，畫面只吃 ROS 真實 topic',
                style: const TextStyle(
                  color: Color(0xFF78909C),
                  fontWeight: FontWeight.w700,
                ),
              ),
              value: mission.mockDataEnabled,
              onChanged: (value) {
                unawaited(mission.setMockDataEnabled(value));
              },
            ),
            _InfoRow(icon: Icons.map_outlined, title: '底圖模式', detail: '灰底任務地圖'),
            _InfoRow(
              icon: Icons.satellite_alt_outlined,
              title: '衛星圖',
              detail: '等待 API 串接',
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _saveRobotIp(BuildContext context) async {
    if (!(_formKey.currentState?.validate() ?? false)) {
      return;
    }
    setState(() => _saving = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final mission = context.read<MissionMockProvider>();
    final error = await mission.updateRobotIp(_ipController.text);
    if (!mounted) {
      return;
    }
    setState(() => _saving = false);
    if (error != null) {
      messenger.showSnackBar(SnackBar(content: Text(error)));
      return;
    }
    messenger.showSnackBar(const SnackBar(content: Text('機器人 IP 已更新')));
    navigator.pop();
  }
}

class _ManualControlSheet extends StatelessWidget {
  const _ManualControlSheet();

  @override
  Widget build(BuildContext context) {
    final mission = context.read<MissionMockProvider>();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SheetHandle(),
            const SizedBox(height: 18),
            const Text(
              '手動控制',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 8),
            const Text(
              'Mock only，不會發布速度或刀盤命令。',
              style: TextStyle(
                color: Color(0xFF78909C),
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: const [
                _JoystickPreview(label: 'Move'),
                _JoystickPreview(label: 'Turn'),
              ],
            ),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () {
                  mission.addMockAction('手動控制 mock opened');
                  Navigator.of(context).pop();
                },
                icon: const Icon(Icons.lock_outline),
                label: const Text('保持安全鎖定'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _JoystickPreview extends StatelessWidget {
  const _JoystickPreview({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 104,
          height: 104,
          decoration: const BoxDecoration(
            color: Color(0xFFE5FAF1),
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Container(
              width: 42,
              height: 42,
              decoration: const BoxDecoration(
                color: Color(0xFF55D69B),
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w900)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Icon(icon, color: const Color(0xFF167A4A)),
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
                  style: const TextStyle(
                    color: Color(0xFF78909C),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SheetHandle extends StatelessWidget {
  const _SheetHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 42,
        height: 4,
        decoration: BoxDecoration(
          color: const Color(0xFFD0D7DA),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
