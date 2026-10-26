// Basic smoke test: the app boots and shows the three navigation tabs.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pavan_residency/main.dart';

void main() {
  testWidgets('App boots and shows the three navigation tabs',
      (WidgetTester tester) async {
    // Screens read settings from SharedPreferences in initState; provide a
    // mock store so the plugin channel is available under the test binding.
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const PavanApp());
    await tester.pump();

    // Bottom navigation exposes Single / Bulk / Settings destinations.
    expect(find.text('Single'), findsWidgets);
    expect(find.text('Bulk'), findsWidgets);
    expect(find.text('Settings'), findsWidgets);
  });
}
