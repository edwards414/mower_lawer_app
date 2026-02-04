import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/mower_status_provider.dart';
import 'screens/home_screen.dart';
import 'services/ros_service.dart';

void main() {
  runApp(const MowerApp());
}

class MowerApp extends StatelessWidget {
  const MowerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        Provider<RosService>(create: (_) => RosService()),
        ChangeNotifierProvider<MowerStatusProvider>(
          create: (ctx) => MowerStatusProvider(ctx.read<RosService>()),
        ),
      ],
      child: MaterialApp(
        title: '割草机',
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
