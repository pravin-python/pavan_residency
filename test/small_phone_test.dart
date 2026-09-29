// Layout check on a small phone with a large font: any RenderFlex overflow
// throws a FlutterError and fails the test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/main.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('all tabs fit a 360x640 phone at font scale 1.3', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3;
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    await tester.pumpWidget(const PavanApp());
    await tester.pumpAndSettle();

    // Single: open the conditional fields too (Cheque + Other).
    await tester.tap(find.byType(DropdownButtonFormField<PaymentMode>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cheque').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<PaymentType>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Other').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('Other details'), findsOneWidget);
    expect(find.text('Cheque No. *'), findsOneWidget);

    // Validation messages must fit as well.
    // The Single tab's list is lazily built: scroll it to the button.
    await tester.scrollUntilVisible(find.text('Send Email'), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send Email'));
    await tester.pumpAndSettle();
    expect(find.text('Select a block'), findsOneWidget);

    await tester.tap(find.text('Bulk CSV'));
    await tester.pumpAndSettle();
    expect(find.text('Choose CSV File'), findsOneWidget);

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    expect(find.text('SMTP Settings'), findsOneWidget);
  });
}
