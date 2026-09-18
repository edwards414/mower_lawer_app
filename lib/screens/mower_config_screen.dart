import 'package:flutter/material.dart';
import '../utils/app_icons.dart';
import 'package:provider/provider.dart';

import '../providers/mission_mock_provider.dart';
import '../services/rosbridge_service.dart';

/// Optional LAN override for development and on-site maintenance.
class MowerConfigScreen extends StatefulWidget {
  const MowerConfigScreen({super.key});

  @override
  State<MowerConfigScreen> createState() => _MowerConfigScreenState();
}

class _MowerConfigScreenState extends State<MowerConfigScreen> {
  final _formKey = GlobalKey<FormState>();
  final _ipController = TextEditingController();
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  Future<void> _loadConfig() async {
    final host = context.read<MissionMockProvider>().robotIp;
    setState(() {
      _ipController.text = RosbridgeService.validateRobotIp(host) == null
          ? host
          : '';
      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    if (_formKey.currentState!.validate()) {
      final error = await context.read<MissionMockProvider>().updateRobotIp(
        _ipController.text,
      );

      if (mounted) {
        if (error != null) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(error)));
          return;
        }
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('區網機器人 IP 已更新')));
        Navigator.pop(context);
      }
    }
  }

  @override
  void dispose() {
    _ipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Mower Config',
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                    IconButton(
                      icon: const Icon(AppIcons.x),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextFormField(
                        controller: _ipController,
                        decoration: const InputDecoration(
                          labelText: 'LAN Robot IP Address',
                          hintText: 'e.g.: 192.168.1.100',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(AppIcons.router),
                        ),
                        keyboardType: TextInputType.text,
                        validator: (value) =>
                            RosbridgeService.validateRobotIp(value ?? ''),
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saveConfig,
                          icon: const Icon(AppIcons.save),
                          label: const Text('Save Configuration'),
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
