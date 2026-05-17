import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'providers/mission_mock_provider.dart';
import 'providers/mower_status_provider.dart';
import 'screens/home_screen.dart';
import 'services/rosbridge_service.dart';
import 'services/ros_service.dart';
import 'widgets/iphone_12_template.dart';

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
        Provider<RosbridgeService>(
          create: (_) => RosbridgeService(),
          dispose: (_, service) => service.dispose(),
        ),
        ChangeNotifierProvider<MissionMockProvider>(
          create: (ctx) =>
              MissionMockProvider(rosbridge: ctx.read<RosbridgeService>()),
        ),
        ChangeNotifierProvider<MowerStatusProvider>(
          create: (ctx) => MowerStatusProvider(ctx.read<RosService>()),
        ),
      ],
      child: MaterialApp(
        title: '割草任務控制台',
        debugShowCheckedModeBanner: false,
        builder: (context, child) {
          return IPhone12Template(child: child ?? const SizedBox.shrink());
        },
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: const Color(0xFF167A4A),
            brightness: Brightness.light,
          ),
          scaffoldBackgroundColor: const Color(0xFFECEFF1),
          useMaterial3: true,
        ),
        home: const HomeScreen(),
      ),
    );
  }
}
