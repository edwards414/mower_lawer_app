import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ros_service.dart';
import '../widgets/settings_form.dart';

/// Settings page: mowing direction, duration, coverage pattern, path spacing
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final ros = context.read<RosService>();
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Settings',
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Flexible(
            child: SingleChildScrollView(
              child: SettingsForm(
                initialSettings: ros.getSettings(),
                onSave: (s) async {
                  await ros.updateSettings(s);
                  if (context.mounted) Navigator.pop(context);
                },
                onCancel: () => Navigator.pop(context),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
