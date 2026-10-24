import 'package:flutter/material.dart';

import '../utils/app_icons.dart';

/// The RTK base station, which is also the charging dock, on the map: a
/// white tile with a charging plug and its name above it (below is where a
/// robot's label goes). The same look on the satellite map (this widget,
/// [size] square, the name drawn outside it) and on the vector map (drawn by
/// the canvas with these values).
class BaseStationMarker extends StatelessWidget {
  const BaseStationMarker({super.key});

  /// Violet: green, red, cyan and blue are zones, risk zones, channels and
  /// the phone, and the robot is orange on the satellite map.
  static const Color color = Color(0xFF7B4FD6);
  static const IconData icon = AppIcons.plugZap;
  static const String label = '基站';
  static const double size = 28;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label（充電座）',
      child: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color, width: 2),
              boxShadow: const [
                BoxShadow(color: Color(0x55000000), blurRadius: 4),
              ],
            ),
            child: const Icon(icon, size: 18, color: color),
          ),
          Positioned(
            bottom: size + 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.88),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
