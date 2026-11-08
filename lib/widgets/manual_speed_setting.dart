import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';
import '../utils/app_style.dart';

const _kGreen = Color(0xFF167A4A);

/// The manual joystick's full-deflection speed on the 設定 page: a slider
/// stepped every 0.05 m/s, the chosen speed shown beside its title.
class ManualSpeedSetting extends StatelessWidget {
  const ManualSpeedSetting({super.key});

  /// The slider's shapes, pinned to the Material 3 2023 defaults.
  static const _trackHeight = 4.0;
  static const _thumbRadius = 10.0;
  static const _overlayRadius = 24.0;

  static String _format(double speed) => '${speed.toStringAsFixed(2)} m/s';

  @override
  Widget build(BuildContext context) {
    final mission = context.watch<MissionMockProvider>();
    final speed = mission.manualLinearSpeed;
    const min = MissionMockProvider.manualLinearSpeedMin;
    const max = MissionMockProvider.manualLinearSpeedMax;
    final divisions = ((max - min) / MissionMockProvider.manualLinearSpeedStep)
        .round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const AppIconTile(AppIcons.gamepad2),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '手動搖桿速度',
                style: TextStyle(
                  color: AppStyle.ink,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              _format(speed),
              style: const TextStyle(
                color: _kGreen,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: _trackHeight,
            trackShape: const RoundedRectSliderTrackShape(),
            thumbShape: const RoundSliderThumbShape(
              enabledThumbRadius: _thumbRadius,
            ),
            overlayShape: const RoundSliderOverlayShape(
              overlayRadius: _overlayRadius,
            ),
          ),
          child: Slider(
            value: speed,
            min: min,
            max: max,
            divisions: divisions,
            label: _format(speed),
            semanticFormatterCallback: _format,
            onChanged: (value) =>
                unawaited(mission.setManualLinearSpeed(value)),
          ),
        ),
      ],
    );
  }
}
