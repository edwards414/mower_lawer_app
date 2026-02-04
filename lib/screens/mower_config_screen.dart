import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Mower configuration screen for setting robot IP
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
    final prefs = await SharedPreferences.getInstance();
    final savedIp = prefs.getString('robot_ip') ?? '';
    setState(() {
      _ipController.text = savedIp;
      _isLoading = false;
    });
  }

  Future<void> _saveConfig() async {
    if (_formKey.currentState!.validate()) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('robot_ip', _ipController.text);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Configuration saved')));
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
                      icon: const Icon(Icons.close),
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
                          labelText: 'Robot IP Address',
                          hintText: 'e.g.: 192.168.1.100',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.router),
                        ),
                        keyboardType: TextInputType.text,
                        validator: (value) {
                          if (value == null || value.isEmpty) {
                            return 'Please enter IP address';
                          }
                          // Basic IP validation
                          final ipRegex = RegExp(r'^(\d{1,3}\.){3}\d{1,3}$');
                          if (!ipRegex.hasMatch(value)) {
                            return 'Please enter a valid IP address';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: _saveConfig,
                          icon: const Icon(Icons.save),
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
