import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../models/mission_mock.dart';
import '../providers/mission_mock_provider.dart';

class SelfCheckScreen extends StatelessWidget {
  const SelfCheckScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final battery = mission.batteryPercent;
    final mapReady =
        mission.zones.isNotEmpty ||
        mission.freeSpaceReady ||
        mission.coverageReady;
    final navHealthy =
        mission.hasFreshNavStatusSnapshot &&
        mission.navStatus == NavMockStatus.idle;
    final navCheckState = navHealthy
        ? _CheckState.ready
        : mission.hasFreshNavStatusSnapshot
        ? _CheckState.warning
        : _CheckState.waiting;
    final checks = mission.mockDataEnabled
        ? [
            const _CheckItem(
              AppIcons.flaskConical,
              '資料模式',
              'Demo 已由使用者手動開啟',
              _CheckState.warning,
            ),
            const _CheckItem(
              AppIcons.map,
              '任務地圖資料',
              'Demo 資料，不會送出真機任務',
              _CheckState.warning,
            ),
            _CheckItem(
              AppIcons.batteryFull,
              '電量',
              '${battery?.round() ?? 0}%（Demo）',
              _CheckState.warning,
            ),
            const _CheckItem(
              AppIcons.shieldCheck,
              '安全狀態',
              'Demo 不代表真機安全狀態',
              _CheckState.warning,
            ),
          ]
        : [
            _CheckItem(
              AppIcons.network,
              'rosbridge',
              mission.rosConnected ? '已連線' : '尚未連線',
              mission.rosConnected ? _CheckState.ready : _CheckState.waiting,
            ),
            _CheckItem(
              AppIcons.radar,
              '機器人 heartbeat',
              mission.robotOnline ? '在線且資料新鮮' : '未收到新鮮 heartbeat',
              mission.robotOnline ? _CheckState.ready : _CheckState.waiting,
            ),
            _CheckItem(
              AppIcons.route,
              'Nav2 狀態',
              mission.hasFreshNavStatusSnapshot
                  ? mission.navStatusLabel()
                  : '尚未取得新鮮的後端狀態',
              navCheckState,
            ),
            _CheckItem(
              AppIcons.locate,
              '機器人位置',
              mission.hasFreshRobotPose ? 'pose 資料新鮮' : '尚未收到新鮮 pose',
              mission.hasFreshRobotPose
                  ? _CheckState.ready
                  : _CheckState.waiting,
            ),
            _CheckItem(
              AppIcons.locateFixed,
              'GPS 定位',
              mission.hasFreshGpsFix
                  ? '定位有效 · 水平 σ ${mission.gpsHorizontalSigmaM!.toStringAsFixed(2)} m'
                  : '需非零座標、已知 covariance，且水平 σ ≤ ${MissionMockProvider.maxGpsHorizontalSigmaM.toStringAsFixed(3)} m',
              mission.hasFreshGpsFix ? _CheckState.ready : _CheckState.waiting,
            ),
            _CheckItem(
              AppIcons.map,
              '任務地圖資料',
              mapReady ? '已收到真實圖層' : '尚未收到真實圖層',
              mapReady ? _CheckState.ready : _CheckState.waiting,
            ),
            _CheckItem(
              AppIcons.batteryFull,
              '電量',
              battery == null ? '尚未收到新鮮電量' : '${battery.round()}%',
              battery == null ? _CheckState.waiting : _CheckState.ready,
            ),
            const _CheckItem(
              AppIcons.shieldCheck,
              '安全狀態',
              '後端尚未提供安全狀態 topic',
              _CheckState.warning,
            ),
          ];

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F8),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 22),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final previewHeight = (constraints.maxHeight * 0.28)
                  .clamp(140.0, 230.0)
                  .toDouble();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(AppIcons.chevronLeft),
                      ),
                      const Spacer(),
                      const Text(
                        'Step 1/1',
                        style: TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ],
                  ),
                  const SizedBox(height: 22),
                  const Text(
                    '任務自檢',
                    style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    height: previewHeight,
                    width: double.infinity,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: const Color(0xFFE1F6ED),
                        borderRadius: BorderRadius.circular(28),
                      ),
                      child: const CustomPaint(
                        painter: _MowerPreviewPainter(),
                        child: SizedBox.expand(),
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Expanded(
                    child: ListView.separated(
                      physics: const BouncingScrollPhysics(),
                      itemBuilder: (context, index) {
                        final item = checks[index];
                        return _CheckRow(item: item);
                      },
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 12),
                      itemCount: checks.length,
                    ),
                  ),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onComplete,
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      child: Text(
                        mission.mockDataEnabled
                            ? '進入 Demo 任務地圖'
                            : mission.canControlRobot
                            ? '進入任務地圖'
                            : '以檢視模式進入',
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _CheckItem {
  const _CheckItem(this.icon, this.title, this.detail, this.state);

  final IconData icon;
  final String title;
  final String detail;
  final _CheckState state;
}

enum _CheckState { ready, waiting, warning }

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.item});

  final _CheckItem item;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(item.icon, color: const Color(0xFF263238), size: 24),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                item.detail,
                style: const TextStyle(
                  color: Color(0xFF78909C),
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        Icon(
          switch (item.state) {
            _CheckState.ready => AppIcons.circleCheck,
            _CheckState.waiting => AppIcons.hourglass,
            _CheckState.warning => AppIcons.info,
          },
          color: switch (item.state) {
            _CheckState.ready => const Color(0xFF4ED59B),
            _CheckState.waiting => const Color(0xFF78909C),
            _CheckState.warning => const Color(0xFFE08C1A),
          },
          size: 24,
        ),
      ],
    );
  }
}

class _MowerPreviewPainter extends CustomPainter {
  const _MowerPreviewPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = const Color(0x6635B861)
      ..strokeWidth = 1;
    for (var x = 18.0; x < size.width; x += 28) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (var y = 18.0; y < size.height; y += 28) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    final center = Offset(size.width * 0.5, size.height * 0.56);
    final shadow = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center.translate(0, 18),
        width: size.width * 0.68,
        height: size.height * 0.18,
      ),
      const Radius.circular(24),
    );
    canvas.drawRRect(shadow, Paint()..color = const Color(0x33000000));

    final deck = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center,
        width: size.width * 0.72,
        height: size.height * 0.28,
      ),
      const Radius.circular(24),
    );
    canvas.drawRRect(deck, Paint()..color = const Color(0xFF18241F));

    final cabin = RRect.fromRectAndRadius(
      Rect.fromCenter(
        center: center.translate(size.width * 0.08, -size.height * 0.14),
        width: size.width * 0.32,
        height: size.height * 0.24,
      ),
      const Radius.circular(18),
    );
    canvas.drawRRect(cabin, Paint()..color = const Color(0xFFBFD4CF));
    canvas.drawRRect(
      cabin,
      Paint()
        ..color = const Color(0x99111827)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );

    final trackPaint = Paint()..color = const Color(0xFF0F1714);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center.translate(-size.width * 0.24, size.height * 0.1),
          width: size.width * 0.24,
          height: size.height * 0.12,
        ),
        const Radius.circular(18),
      ),
      trackPaint,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: center.translate(size.width * 0.24, size.height * 0.1),
          width: size.width * 0.24,
          height: size.height * 0.12,
        ),
        const Radius.circular(18),
      ),
      trackPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _MowerPreviewPainter oldDelegate) {
    return false;
  }
}
