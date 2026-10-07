import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mower_stdio/providers/mission_mock_provider.dart';
import 'package:mower_stdio/services/rosbridge_service.dart';
import 'package:mower_stdio/widgets/manual_speed_setting.dart';

const _key = 'manual_linear_speed_m_s';

void main() {
  test(
    'defaults to 0.35 m/s and restores a saved speed on its nearest step',
    () async {
      for (final (saved, expected) in <(double?, double)>[
        (null, 0.35),
        (0.2, 0.2),
        (0.33, 0.35),
        (0.9, 0.45),
        (0.01, 0.1),
      ]) {
        SharedPreferences.setMockInitialValues({
          'mock_data_enabled': false,
          if (saved != null) _key: saved,
        });
        final mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
        await _flushEvents();
        expect(mission.manualLinearSpeed, expected, reason: 'saved $saved');
        mission.dispose();
      }
    },
  );

  test(
    'a pick is snapped and saved, and beats a stored speed still loading',
    () async {
      SharedPreferences.setMockInitialValues({
        'mock_data_enabled': false,
        _key: 0.15,
      });
      final mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
      // Slider values carry float noise; the stored 0.15 has not loaded yet,
      // and this pick equals the default shown until then.
      await mission.setManualLinearSpeed(0.35000000000000003);
      await _flushEvents();
      expect(mission.manualLinearSpeed, 0.35);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getDouble(_key), 0.35);

      await mission.setManualLinearSpeed(0.6);
      expect(mission.manualLinearSpeed, 0.45);
      expect(prefs.getDouble(_key), 0.45);
      mission.dispose();
    },
  );

  testWidgets('更多 slider: one labelled tick under each 0.05 m/s stop', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'mock_data_enabled': false});
    final mission = MissionMockProvider(rosbridge: _NoopRosbridgeService());
    await tester.pumpWidget(
      ChangeNotifierProvider<MissionMockProvider>.value(
        value: mission,
        child: const MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: EdgeInsets.all(16),
              child: ManualSpeedSetting(),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('0.35 m/s'), findsOneWidget);
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect((slider.min, slider.max, slider.divisions), (0.1, 0.45, 7));

    // Slider paints its own stops as small dots: each ruler label must sit
    // centred under one.
    final dots = <double>[];
    expect(
      find.byType(Slider),
      paints..everything((method, args) {
        if (method == #drawCircle && (args[1] as double) <= 2.0) {
          dots.add((args[0] as Offset).dx);
        }
        return true;
      }),
    );
    const labels = [
      '0.10',
      '0.15',
      '0.20',
      '0.25',
      '0.30',
      '0.35',
      '0.40',
      '0.45',
    ];
    expect(dots, hasLength(labels.length));
    final left = tester.getTopLeft(find.byType(Slider)).dx;
    for (var i = 0; i < labels.length; i++) {
      expect(
        tester.getCenter(find.text(labels[i])).dx,
        moreOrLessEquals(left + dots[i], epsilon: 0.5),
        reason: labels[i],
      );
    }

    // Tapping the track above a label picks that speed and saves it.
    final trackY = tester.getCenter(find.byType(Slider)).dy;
    await tester.tapAt(Offset(tester.getCenter(find.text('0.20')).dx, trackY));
    await tester.pump();
    expect(mission.manualLinearSpeed, 0.2);
    expect(find.text('0.20 m/s'), findsOneWidget);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(_key), 0.2);

    await tester.pumpWidget(const SizedBox.shrink());
    mission.dispose();
  });
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
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
  void subscribe(
    String topic, {
    String? type,
    int throttleRateMs = 0,
    Map<String, dynamic>? qos,
  }) {}
}
