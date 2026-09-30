import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/mission_next_step.dart';

Future<MissionMockProvider> _live(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
  final provider = MissionMockProvider(rosbridge: RosbridgeService());
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  return provider;
}

Future<void> _end(WidgetTester tester, MissionMockProvider provider) async {
  await tester.pumpWidget(const SizedBox.shrink());
  provider.dispose();
}

void main() {
  testWidgets('no zones: first step is to add a zone, and it opens the sheet', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = await _live(tester);
    var opened = 0;
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(
            body: MissionNextStepBanner(onAddObject: () => opened++),
          ),
        ),
      ),
    );

    expect(MissionNextStep.of(provider)?.addObject, isTrue);
    expect(find.textContaining('第一步'), findsOneWidget);
    await tester.tap(find.text('新增工作區'));
    expect(opened, 1);
    await _end(tester, provider);
  });

  testWidgets('guidance steps aside while recording or drawing', (
    tester,
  ) async {
    final provider = await _live(tester);
    expect(MissionNextStep.of(provider), isNotNull);
    expect(provider.startDrawRisk(), isNull);
    expect(MissionNextStep.of(provider), isNull);
    provider.cancelDraw();
    expect(MissionNextStep.of(provider), isNotNull);
    await _end(tester, provider);
  });

  testWidgets('plan step action switches panel, then hides itself there', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = await _live(tester);
    provider.zones = const [MissionZone(id: 1, name: '後院', points: [])];
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MissionNextStepBanner(onAddObject: () {})),
        ),
      ),
    );

    expect(find.textContaining('第二步'), findsOneWidget);
    await tester.tap(find.text('前往規劃'));
    await tester.pump();
    expect(provider.selectedMode, MissionMode.plan);
    expect(find.text('前往規劃'), findsNothing);
    expect(find.textContaining('第二步'), findsOneWidget);
    await _end(tester, provider);
  });

  testWidgets('live: guidance follows the SELECTED zone, not any zone', (
    tester,
  ) async {
    final provider = await _live(tester);
    provider.zones = const [
      MissionZone(id: 1, name: '前院', points: [], hasCoveragePath: true),
      MissionZone(id: 2, name: '後院', points: []),
    ];

    provider.selectedZoneId = 1;
    expect(MissionNextStep.of(provider)?.text, contains('路徑已就緒'));

    // Starting needs the selected zone's path; the banner must not claim it.
    provider.selectedZoneId = 2;
    final step = MissionNextStep.of(provider)!;
    expect(step.text, contains('第二步'));
    expect(step.text, contains('後院'));
    expect(step.targetMode, MissionMode.plan);
    await _end(tester, provider);
  });

  testWidgets('demo: generating the path (coverageReady) advances to run', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': true});
    final provider = MissionMockProvider(rosbridge: RosbridgeService());
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    expect(provider.mockDataEnabled, isTrue);
    // Demo planning never sets per-zone flags, only the ready flag.
    provider.zones = const [MissionZone(id: 1, name: '前院', points: [])];
    provider.selectedZoneId = 1;
    provider.coverageReady = false;
    expect(MissionNextStep.of(provider)?.text, contains('第二步'));
    provider.coverageReady = true;
    expect(MissionNextStep.of(provider)?.text, contains('路徑已就緒'));
    await _end(tester, provider);
  });

  testWidgets('banner is left out on landscape screens', (tester) async {
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final provider = await _live(tester);
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: provider,
        child: MaterialApp(
          home: Scaffold(body: MissionNextStepBanner(onAddObject: () {})),
        ),
      ),
    );
    expect(find.textContaining('第一步'), findsNothing);
    await _end(tester, provider);
  });
}
