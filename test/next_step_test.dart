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
}
