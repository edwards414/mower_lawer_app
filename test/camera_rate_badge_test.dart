import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/widgets/webrtc_camera_view.dart';

/// A frozen last frame must never pass for live video, in the big view or in
/// the small picture-in-picture.
void main() {
  Future<void> pump(WidgetTester tester, double fps, {bool compact = false}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CameraRateBadge(fps: fps, compact: compact),
          ),
        ),
      );

  testWidgets('the big view shows the rate, red when it stalls', (
    tester,
  ) async {
    await pump(tester, 24);
    expect(find.text('24 Hz'), findsOneWidget);
    expect(tester.widget<Text>(find.text('24 Hz')).style?.color, Colors.white);

    await pump(tester, 8.54);
    expect(find.text('8.5 Hz'), findsOneWidget);

    await pump(tester, 0);
    final stalled = tester.widget<Text>(find.text('0.0 Hz'));
    expect(stalled.style?.color, const Color(0xFFFF6B6B));
  });

  testWidgets('the small view stays silent while live', (tester) async {
    await pump(tester, 24, compact: true);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets('the small view says 停格 when the stream stalls', (tester) async {
    await pump(tester, 0.4, compact: true);
    expect(find.text('停格'), findsOneWidget);
    // Red, so it cannot be read as a label.
    final badge = tester.widget<Container>(find.byType(Container));
    expect((badge.decoration as BoxDecoration).color, const Color(0xE6D32F2F));
  });
}
