import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class AddObjectSheet extends StatefulWidget {
  const AddObjectSheet({super.key, this.onRecordingStarted});

  /// Called once the robot has accepted a zone / risk / channel recording, so
  /// the caller can put the user in manual mode to drive it.
  final VoidCallback? onRecordingStarted;

  @override
  State<AddObjectSheet> createState() => _AddObjectSheetState();
}

class _AddObjectSheetState extends State<AddObjectSheet> {
  bool _starting = false;
  String? _error;

  Future<void> _startRecording(RecordObjectType type) async {
    if (_starting) {
      return;
    }
    final mission = context.read<MissionMockProvider>();
    final navigator = Navigator.of(context);
    final route = ModalRoute.of(context);
    setState(() {
      _starting = true;
      _error = null;
    });
    final error = await mission.startRecording(type);
    // Dismissed while waiting: the user is already back on the map. `mounted`
    // is still true during the sheet's exit animation, so ask the route: only
    // pop (and hand off) while this sheet is still the top route, otherwise
    // pop() would remove the page underneath. Recording, if it started, stays
    // visible and controllable from the map.
    if (!mounted || !(route?.isCurrent ?? false)) {
      return;
    }
    if (error != null) {
      setState(() {
        _starting = false;
        _error = error;
      });
      return;
    }
    navigator.pop();
    // Demo recordings need no driving, so keep the user on the map there.
    if (!mission.mockDataEnabled) {
      widget.onRecordingStarted?.call();
    }
  }

  void _startDraw(String kind) {
    final mission = context.read<MissionMockProvider>();
    final error = mission.startDraw(kind);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final idle = !_starting;
    // Rebuilds only when the hint changes, not on every robot message.
    final rtkHint = context.select<MissionMockProvider, String?>(
      (mission) => mission.recordStartRtkHint,
    );

    return SafeArea(
      // Scrolls so the extra rows never overflow a landscape phone.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 42,
              height: 4,
              decoration: BoxDecoration(
                color: const Color(0xFFD0D7DA),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                const Expanded(
                  child: Text(
                    '新增地圖物件',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(AppIcons.x),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '選一種畫法：用搖桿開車沿邊界記錄最準；在地圖上點出不用移動割草機。',
                style: TextStyle(
                  color: Color(0xFF78909C),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            // Status sits above the cards so it stays in view on a short
            // (landscape) screen instead of falling below the fold.
            if (_starting) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 3),
              const SizedBox(height: 6),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '正在通知機器人開始記錄…',
                  style: TextStyle(
                    color: Color(0xFF78909C),
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
            // Advance notice only: the robot answers the start itself.
            if (rtkHint != null && !_starting) ...[
              const SizedBox(height: 12),
              Row(
                key: const ValueKey('record-start-rtk-hint'),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(
                    AppIcons.triangleAlert,
                    size: 16,
                    color: Color(0xFFB26A00),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      rtkHint,
                      style: const TextStyle(
                        color: Color(0xFFB26A00),
                        fontSize: 12.5,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(AppIcons.x, size: 16, color: Color(0xFFC62828)),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _error!,
                      style: const TextStyle(
                        color: Color(0xFFC62828),
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            const _MethodHeader(
              icon: AppIcons.gamepad2,
              title: '開車記錄',
              detail: '用地圖上的搖桿沿邊界或路徑開一趟',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _AddObjectCard(
                    icon: AppIcons.squareDashed,
                    label: '工作區',
                    color: const Color(0xFF35B861),
                    onTap: idle
                        ? () => _startRecording(RecordObjectType.zone)
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    icon: AppIcons.ban,
                    label: '禁入區',
                    color: const Color(0xFFE55353),
                    onTap: idle
                        ? () => _startRecording(RecordObjectType.risk)
                        : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    icon: AppIcons.spline,
                    label: '通道',
                    color: const Color(0xFF25AFC6),
                    onTap: idle
                        ? () => _startRecording(RecordObjectType.channel)
                        : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            const _MethodHeader(
              icon: AppIcons.mapPinPen,
              title: '在地圖上點出',
              detail: '一點一點點出形狀，點錯可以復原或拖曳修正',
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _AddObjectCard(
                    key: const ValueKey('draw-zone'),
                    icon: AppIcons.squareDashed,
                    label: '工作區',
                    color: const Color(0xFF35B861),
                    compact: true,
                    onTap: idle ? () => _startDraw('zone') : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    key: const ValueKey('draw-risk'),
                    icon: AppIcons.ban,
                    label: '禁入區',
                    color: const Color(0xFFE55353),
                    compact: true,
                    onTap: idle ? () => _startDraw('risk') : null,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _AddObjectCard(
                    key: const ValueKey('draw-channel'),
                    icon: AppIcons.spline,
                    label: '通道',
                    color: const Color(0xFF25AFC6),
                    compact: true,
                    onTap: idle ? () => _startDraw('channel') : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MethodHeader extends StatelessWidget {
  const _MethodHeader({
    required this.icon,
    required this.title,
    required this.detail,
  });

  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF455A64)),
        const SizedBox(width: 6),
        Text(
          title,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w900),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            detail,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFF78909C),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _AddObjectCard extends StatelessWidget {
  const _AddObjectCard({
    super.key,
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
    this.compact = false,
  });

  /// A shorter card, for the second row of the sheet.
  final bool compact;

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: onTap == null ? 0.5 : 1,
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Container(
          height: compact ? 92 : 112,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFFE1E7EA)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x12000000),
                blurRadius: 12,
                offset: Offset(0, 5),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: compact ? 36 : 44,
                height: compact ? 36 : 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: color, size: compact ? 22 : 28),
              ),
              SizedBox(height: compact ? 6 : 10),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
