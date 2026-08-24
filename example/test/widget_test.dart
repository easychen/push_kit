// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:push_kit_example/main.dart';

void main() {
  testWidgets('push example starts', (WidgetTester tester) async {
    await tester.pumpWidget(const PushExample());
    expect(find.text('push_kit'), findsOneWidget);
    expect(find.text('No events'), findsOneWidget);
  });
}
