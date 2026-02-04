import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/coverage_path.dart';
import '../models/mower_status.dart';
import '../providers/mower_status_provider.dart';
import '../utils/constants.dart';
import '../widgets/map_widget.dart';
import '../widgets/status_bar.dart';
import 'mower_config_screen.dart';
import 'settings_screen.dart';

/// Main screen: status bar, map, bottom controls
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<MowerStatusProvider>();
    final status =
        provider.status ??
        MowerStatus(
          batteryPercent: 0,
          latitude: AppConstants.defaultLatitude,
          longitude: AppConstants.defaultLongitude,
          startLatitude: AppConstants.defaultLatitude,
          startLongitude: AppConstants.defaultLongitude,
        );
    final coveragePath = provider.coveragePath ?? const CoveragePath();

    return Scaffold(
      body: Stack(
        children: [
          // 1. Full Screen Map
          Positioned.fill(
            child: MapWidget(status: status, coveragePath: coveragePath),
          ),

          // 2. Settings Icon (Top Right)
          Positioned(
            top: 48,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: 'settings_fab',
              backgroundColor: Theme.of(context).colorScheme.surface,
              child: const Icon(Icons.settings),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => Dialog(
                    child: Container(
                      constraints: const BoxConstraints(
                        maxWidth: 500,
                        maxHeight: 600,
                      ),
                      child: const SettingsScreen(),
                    ),
                  ),
                );
              },
            ),
          ),

          // 3. Config Icon (Top Right, below settings)
          Positioned(
            top: 104,
            right: 16,
            child: FloatingActionButton.small(
              heroTag: 'config_fab',
              backgroundColor: Theme.of(context).colorScheme.surface,
              child: const Icon(Icons.router),
              onPressed: () {
                showDialog(
                  context: context,
                  builder: (context) => Dialog(
                    child: Container(
                      constraints: const BoxConstraints(
                        maxWidth: 500,
                        maxHeight: 400,
                      ),
                      child: const MowerConfigScreen(),
                    ),
                  ),
                );
              },
            ),
          ),

          // 4. Status Bar Overlay (Top Center)
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 48),
              child: FractionallySizedBox(
                widthFactor: 0.3,
                child: Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: StatusBar(status: status),
                  ),
                ),
              ),
            ),
          ),

          // 5. Control Buttons Overlay (Bottom)
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.only(bottom: 32),
              child: _buildBottomControls(context, provider),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(
    BuildContext context,
    MowerStatusProvider provider,
  ) {
    return Card(
      elevation: 8,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: () async {
                if (provider.isMowing) {
                  await provider.stopMowing();
                } else {
                  await provider.startMowing();
                }
              },
              icon: Icon(provider.isMowing ? Icons.pause : Icons.play_arrow),
              label: Text(provider.isMowing ? 'Pause' : 'Start'),
            ),
            const SizedBox(width: 16),
            OutlinedButton.icon(
              onPressed: () async {
                await provider.stopMowing();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Return to base command sent'),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.home),
              label: const Text('Return to Base'),
            ),
          ],
        ),
      ), // Padding
    ); // Card
  }
}
