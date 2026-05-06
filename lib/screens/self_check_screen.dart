import 'package:flutter/material.dart';

class SelfCheckScreen extends StatelessWidget {
  const SelfCheckScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  Widget build(BuildContext context) {
    final checks = const [
      _CheckItem(Icons.hub_outlined, 'ROS adapter mock', '已連線'),
      _CheckItem(Icons.route_outlined, 'Nav2 狀態', '待命'),
      _CheckItem(Icons.my_location, '定位品質', 'RTK fixed'),
      _CheckItem(Icons.map_outlined, '任務地圖資料', 'Demo loaded'),
      _CheckItem(Icons.battery_full, '電量', '85%'),
      _CheckItem(Icons.health_and_safety_outlined, '安全狀態', 'Clear'),
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
                        icon: const Icon(Icons.arrow_back_ios_new),
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
                      child: const Text(
                        '進入任務地圖',
                        style: TextStyle(fontWeight: FontWeight.w900),
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
  const _CheckItem(this.icon, this.title, this.detail);

  final IconData icon;
  final String title;
  final String detail;
}

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
        const Icon(Icons.check, color: Color(0xFF4ED59B), size: 24),
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
