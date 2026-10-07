import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';
import '../utils/app_icons.dart';

const _kGreen = Color(0xFF167A4A);
const _kGrey = Color(0xFF78909C);

/// The manual joystick's full-deflection speed on the 更多 page: a stepped
/// slider with a ruler under it, one tick and label per 0.05 m/s stop.
class ManualSpeedSetting extends StatelessWidget {
  const ManualSpeedSetting({super.key});

  /// The slider's shapes are pinned (to the Material 3 2023 defaults) so the
  /// ruler can put each tick exactly under its stop: the track is inset by
  /// the overlay radius (larger than the thumb's) and its stops by a further
  /// half track height, as Slider paints its own discrete ticks.
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
            const Icon(AppIcons.gamepad2, color: _kGreen),
            const SizedBox(width: 12),
            const Expanded(
              child: Text(
                '手動搖桿速度',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              _format(speed),
              style: const TextStyle(
                color: _kGreen,
                fontWeight: FontWeight.w900,
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
        _SpeedRuler(
          selected: speed,
          divisions: divisions,
          inset: _overlayRadius + _trackHeight / 2,
        ),
      ],
    );
  }
}

/// Tick marks and values under the slider; every 0.10 m/s tick is longer.
class _SpeedRuler extends StatelessWidget {
  const _SpeedRuler({
    required this.selected,
    required this.divisions,
    required this.inset,
  });

  final double selected;
  final int divisions;

  /// Distance from either edge to the first and last stop.
  final double inset;

  static const _labelWidth = 36.0;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 28,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final span = constraints.maxWidth - 2 * inset;
          return Stack(
            clipBehavior: Clip.none,
            children: [
              for (var i = 0; i <= divisions; i++)
                _tick(
                  value:
                      MissionMockProvider.manualLinearSpeedMin +
                      i * MissionMockProvider.manualLinearSpeedStep,
                  x: inset + span * i / divisions,
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _tick({required double value, required double x}) {
    final isSelected = (value - selected).abs() < 1e-6;
    final isMajor = (value * 100).round() % 10 == 0;
    final color = isSelected ? _kGreen : _kGrey;
    return Positioned(
      left: x - _labelWidth / 2,
      width: _labelWidth,
      top: 0,
      child: Column(
        children: [
          Container(
            width: isSelected ? 2 : 1.5,
            height: isMajor ? 8 : 5,
            color: color,
          ),
          const SizedBox(height: 3),
          Text(
            value.toStringAsFixed(2),
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.visible,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.w900 : FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
