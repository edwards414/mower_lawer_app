import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mower_stdio/main.dart';

void main() {
  testWidgets('shows self check then mission map shell', (tester) async {
    await tester.pumpWidget(const MowerApp());

    expect(find.text('任務自檢'), findsOneWidget);
    expect(find.text('進入任務地圖'), findsOneWidget);

    await tester.tap(find.text('進入任務地圖'));
    await tester.pumpAndSettle();

    expect(find.text('物件'), findsOneWidget);
    expect(find.text('記錄'), findsOneWidget);
    expect(find.text('規劃'), findsOneWidget);
    expect(find.text('執行'), findsOneWidget);
    expect(find.text('日誌'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
