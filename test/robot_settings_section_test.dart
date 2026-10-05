import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/providers/robot_info_provider.dart';
import 'package:mower_stdio/providers/robot_registry.dart';
import 'package:mower_stdio/screens/robots_screen.dart';
import 'package:mower_stdio/services/backend_client.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';

const _secret = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _qr =
    'https://mower.fxrbindi.com/pair?v=1&id=MW-7K3Q9P&s=$_secret'
    '&h=wss%3A%2F%2Fcontrol.example.com&l=192.168.0.113';

void main() {
  testWidgets('one 直連 IP field replaces the LAN and 直連 settings', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final rosbridge = _NoopRosbridgeService();
    final registry = RobotRegistry(
      rosbridge: rosbridge,
      store: MemoryPairingStore(),
      backend: BackendClient(
        client: MockClient((_) async => http.Response('{}', 404)),
      ),
      lanProbe: (_, _) async => false,
    );
    await registry.load();
    await registry.pairFromText(_qr);
    final mission = _BusyMission(rosbridge);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider<RobotRegistry>.value(value: registry),
          ChangeNotifierProvider<MissionMockProvider>.value(value: mission),
          ChangeNotifierProvider<RobotInfoProvider>(
            create: (_) => RobotInfoProvider(rosbridge: rosbridge),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: RobotSettingsSection(visible: false),
            ),
          ),
        ),
      ),
    );

    final field = find.widgetWithText(TextField, '直連 IP');
    expect(field, findsOneWidget);
    for (final gone in ['LAN 位址', '直連位址', '固定走 LAN', '自動選路']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }

    // Nothing typed yet: nothing to save.
    final save = find.widgetWithText(FilledButton, '儲存');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    await tester.enterText(field, '999.1.1.1');
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    expect(find.text('請輸入有效的 IPv4 位址'), findsOneWidget);
    expect(registry.active!.directAddress, isEmpty);

    // A live operation locks the connection of the active robot.
    await tester.enterText(field, '192.168.0.50');
    mission.setBusy(true);
    await tester.pump();
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    expect(find.text('任務、記錄或手動控制進行中，結束後才能改連線。'), findsOneWidget);

    mission.setBusy(false);
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    expect(registry.active!.directAddress, '192.168.0.50');
    expect(find.text('直連 IP 已更新：192.168.0.50'), findsOneWidget);

    // An empty field turns direct connection off again.
    await tester.enterText(field, '');
    await tester.pump();
    await tester.tap(save);
    await tester.pump();
    expect(registry.active!.directAddress, isEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
    registry.dispose();
  });
}

class _BusyMission extends MissionMockProvider {
  _BusyMission(RosbridgeService rosbridge) : super(rosbridge: rosbridge);

  void setBusy(bool busy) {
    manualControlActive = busy;
    notifyListeners();
  }
}

class _NoopRosbridgeService extends RosbridgeService {
  _NoopRosbridgeService() : super(url: 'ws://robot.test:9090');

  @override
  Stream<RosbridgeTopicMessage> get messages => const Stream.empty();

  @override
  Stream<RosbridgeConnectionState> get states => const Stream.empty();

  @override
  Future<void> loadSavedRobotIp() async {}

  @override
  void connect() {}

  @override
  void reconnect() {}

  @override
  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {}
}
