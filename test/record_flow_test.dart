import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/models/mission_mock.dart';
import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/add_object_sheet.dart';
import 'package:mower_stdio/widgets/map_record_bar.dart';

Future<MissionMockProvider> _provider(
  WidgetTester tester, {
  required bool demo,
}) async {
  SharedPreferences.setMockInitialValues({'mock_data_enabled': demo});
  final provider = MissionMockProvider(rosbridge: RosbridgeService());
  // Let the provider read its saved data-source preference.
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  expect(provider.mockDataEnabled, demo);
  return provider;
}

/// The provider owns a periodic timer; end it before the framework checks for
/// pending timers.
Future<void> _finish(WidgetTester tester, MissionMockProvider provider) async {
  await tester.pumpWidget(const SizedBox.shrink());
  provider.dispose();
}

Widget _host(MissionMockProvider provider, Widget body) {
  return ChangeNotifierProvider<MissionMockProvider>.value(
    value: provider,
    child: MaterialApp(home: Scaffold(body: body)),
  );
}

void main() {
  testWidgets('map record bar shows a recording and can save it', (
    tester,
  ) async {
    final provider = await _provider(tester, demo: true);
    var manualOpened = 0;
    await tester.pumpWidget(
      _host(provider, MapRecordBar(onOpenManual: () => manualOpened++)),
    );

    // Nothing to show while idle.
    expect(find.text('儲存'), findsNothing);

    expect(await provider.startRecording(RecordObjectType.zone), isNull);
    await tester.pump();
    expect(find.textContaining('工作區記錄中'), findsOneWidget);
    expect(find.text('儲存'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    await tester.tap(find.byTooltip('前往手動控制'));
    expect(manualOpened, 1);

    await tester.tap(find.text('儲存'));
    await tester.pump();
    await tester.pump();
    expect(provider.recordingType, isNull);
    expect(find.text('儲存'), findsNothing);
    await _finish(tester, provider);
  });

  testWidgets('map record bar cancel ends the recording', (tester) async {
    final provider = await _provider(tester, demo: true);
    await tester.pumpWidget(_host(provider, MapRecordBar(onOpenManual: () {})));

    await provider.startRecording(RecordObjectType.channel);
    await tester.pump();
    expect(find.textContaining('通道記錄中'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await tester.pump();
    expect(provider.recordingType, isNull);
    expect(find.textContaining('通道記錄中'), findsNothing);
    await _finish(tester, provider);
  });

  testWidgets('demo recording stays on the map (nothing to drive)', (
    tester,
  ) async {
    final provider = await _provider(tester, demo: true);
    var started = 0;
    await tester.pumpWidget(
      _host(
        provider,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  AddObjectSheet(onRecordingStarted: () => started++),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('工作區'));
    await tester.pumpAndSettle();

    expect(provider.recordingType, RecordObjectType.zone);
    // The sheet closes itself, but there is no robot to drive in demo mode.
    expect(find.text('新增地圖物件'), findsNothing);
    expect(started, 0);
    await _finish(tester, provider);
  });

  testWidgets('add-object sheet shows why recording could not start', (
    tester,
  ) async {
    // Live mode with no robot connected: starting must fail visibly.
    final provider = await _provider(tester, demo: false);
    var started = 0;
    await tester.pumpWidget(
      _host(
        provider,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) =>
                  AddObjectSheet(onRecordingStarted: () => started++),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('禁入區'));
    await tester.pumpAndSettle();

    expect(find.textContaining('無法開始記錄'), findsOneWidget);
    expect(find.text('新增地圖物件'), findsOneWidget);
    expect(started, 0);
    expect(provider.recordingType, isNull);
    await _finish(tester, provider);
  });
}
