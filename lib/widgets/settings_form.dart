import 'package:flutter/material.dart';

import '../models/mowing_settings.dart';
import '../utils/constants.dart';

/// Mowing settings form
class SettingsForm extends StatefulWidget {
  final MowingSettings initialSettings;
  final void Function(MowingSettings) onSave;
  final VoidCallback onCancel;

  const SettingsForm({
    super.key,
    required this.initialSettings,
    required this.onSave,
    required this.onCancel,
  });

  @override
  State<SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends State<SettingsForm> {
  late double _direction;
  late int _durationMinutes;
  late CoveragePattern _coveragePattern;
  late double _pathSpacingCm;

  @override
  void initState() {
    super.initState();
    _direction = widget.initialSettings.direction;
    _durationMinutes = widget.initialSettings.durationMinutes;
    _coveragePattern = widget.initialSettings.coveragePattern;
    _pathSpacingCm = widget.initialSettings.pathSpacingCm;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Mowing Direction (degrees)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Slider(
          value: _direction,
          min: AppConstants.directionMin,
          max: AppConstants.directionMax,
          divisions: 36,
          label: '${_direction.toStringAsFixed(0)}°',
          onChanged: (v) => setState(() => _direction = v),
        ),
        Text('${_direction.toStringAsFixed(0)}° (0=North, 90=East)'),
        const SizedBox(height: 24),
        Text(
          'Mowing Duration (minutes)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Slider(
          value: _durationMinutes.toDouble(),
          min: AppConstants.durationMin.toDouble(),
          max: AppConstants.durationMax.toDouble(),
          divisions: 17,
          label: '$_durationMinutes min',
          onChanged: (v) => setState(() => _durationMinutes = v.round()),
        ),
        Text('$_durationMinutes min'),
        const SizedBox(height: 24),
        Text(
          'Path Coverage Pattern',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        DropdownButtonFormField<CoveragePattern>(
          initialValue: _coveragePattern,
          items: const [
            DropdownMenuItem(
              value: CoveragePattern.parallel,
              child: Text('Parallel Lines'),
            ),
          ],
          onChanged: (v) =>
              v != null ? setState(() => _coveragePattern = v) : null,
        ),
        const SizedBox(height: 24),
        Text(
          'Path Spacing (cm)',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Slider(
          value: _pathSpacingCm,
          min: AppConstants.pathSpacingMin,
          max: AppConstants.pathSpacingMax,
          divisions: 8,
          label: '${_pathSpacingCm.toStringAsFixed(0)} cm',
          onChanged: (v) => setState(() => _pathSpacingCm = v),
        ),
        Text('${_pathSpacingCm.toStringAsFixed(0)} cm'),
        const SizedBox(height: 32),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(onPressed: widget.onCancel, child: const Text('Cancel')),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: () => widget.onSave(
                MowingSettings(
                  direction: _direction,
                  durationMinutes: _durationMinutes,
                  coveragePattern: _coveragePattern,
                  pathSpacingCm: _pathSpacingCm,
                ),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
