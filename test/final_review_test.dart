// Regression tests for the final pre-release review findings.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mailer/mailer.dart';
import 'package:pavan_residency/main.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/csv_service.dart';
import 'package:pavan_residency/services/email_service.dart';
import 'package:pavan_residency/services/sent_log.dart';
import 'package:pavan_residency/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<ReceiptData> parse(String csv) =>
    CsvService.parse(Uint8List.fromList(utf8.encode(csv)));

void main() {
  testWidgets('Settings Save never rolls the receipt counter back',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'pavan_settings_v1': jsonEncode(AppSettings(
        host: 'smtp.x.com',
        username: 'u@x.com',
        password: 'p',
        nextReceiptNo: 794,
      ).toJson()),
    });
    await tester.pumpWidget(const PavanApp());
    await tester.pumpAndSettle();

    // Three sends happen (e.g. from Bulk) after the app started.
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(SettingsService.takeReceiptNo);
    }
    await tester.pumpAndSettle();

    await tester.tap(find.text('Settings').last);
    await tester.pumpAndSettle();
    // The field is further down the (lazily built) Settings list.
    await tester.scrollUntilVisible(find.text('Next Receipt No.'), 200,
        scrollable: find
            .ancestor(
                of: find.text('SMTP Settings'),
                matching: find.byType(Scrollable))
            .first);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '797'), findsOneWidget);

    await tester.ensureVisible(find.text('Save Settings'));
    await tester.tap(find.text('Save Settings'));
    await tester.pumpAndSettle();
    // First save on this install asks to confirm the counter.
    expect(find.textContaining('#797'), findsOneWidget);
    await tester.tap(find.text('Yes, correct'));
    await tester.pumpAndSettle();

    final s = await tester.runAsync(SettingsService.load);
    expect(s!.nextReceiptNo, 797);
    expect(s.counterConfirmed, isTrue);
    expect(await tester.runAsync(SettingsService.takeReceiptNo), 797);
  });

  test('auto numbers skip reserved (typed) numbers', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await SettingsService.load();
    s.nextReceiptNo = 794;
    SettingsService.reserve([795]);
    expect(await SettingsService.takeReceiptNo(), 794);
    expect(await SettingsService.takeReceiptNo(), 796); // 795 is typed
    SettingsService.unreserve([795]);
    expect(await SettingsService.takeReceiptNo(), 797);
  });

  test('sent log: flat is part of the key; blank dates expire', () async {
    SharedPreferences.setMockInitialValues({});
    final a101 = ReceiptData(
        name: 'Patel',
        email: 'p@x.com',
        amount: 1500,
        block: 'A',
        house: '101',
        date: '28-09-2026')
      ..recNo = 900;
    await SentLog.add(a101);
    expect(await SentLog.sentNo(a101.copy()..recNo = 0), 900);
    expect(await SentLog.sentNo(a101.copy()..house = '202'), isNull);

    final t0 = DateTime(2026, 9, 28);
    final blank = a101.copy()
      ..house = '303'
      ..dateDefaulted = true
      ..recNo = 901;
    await SentLog.add(blank, now: t0);
    final nextDay = blank.copy()..date = '29-09-2026';
    expect(await SentLog.sentNo(nextDay, now: t0.add(const Duration(days: 1))),
        901); // resumed the next day: still "already sent"
    expect(await SentLog.sentNo(nextDay, now: t0.add(const Duration(days: 30))),
        isNull); // next month's receipt is a new one
  });

  test('server refusals are "not sent"; limits stop the bulk run', () {
    final quota = SmtpClientCommunicationException(
        'After sending DATA, response did not start with any of: [250].'
        '\nResponse from server: < 550 5.4.5 Daily user sending limit '
        'exceeded');
    expect(EmailService.isConfigError(quota), isTrue);
    expect(EmailService.friendlyError(quota), contains('daily limit'));

    final rcpt = SmtpClientCommunicationException(
        'After sending RCPT TO, response did not start with any of: [250].'
        '\nResponse from server: < 550 5.1.1 No such user');
    expect(EmailService.isConfigError(rcpt), isFalse);
    expect(EmailService.friendlyError(rcpt), contains('refused'));
  });

  test('amounts with a decimal comma or /-', () {
    expect(ReceiptData.parseAmount('7500,00'), 7500);
    expect(ReceiptData.parseAmount('7,50,000'), 750000);
    expect(ReceiptData.parseAmount('1,00,000.00'), 100000);
    expect(ReceiptData.parseAmount('7500/-'), 7500);
    expect(ReceiptData.parseAmount('Rs. 7,500/-'), 7500);
  });

  test('more date formats; unreadable dates flag the row', () {
    String? n(String v) => CsvService.tryNormDate(v);
    expect(n('25-Sep-2026'), '25-09-2026');
    expect(n('25 September 2026'), '25-09-2026');
    expect(n('Sep 25, 2026'), '25-09-2026');
    expect(n('25/9/26'), '25-09-2026');
    expect(n('46290'), '25-09-2026'); // Excel serial
    expect(n('31/02/2026'), isNull);
    expect(n('next monday'), isNull);

    final rows = parse('name,email,amount,received_date\n'
        'A,a@x.com,1,next monday\n'
        'B,b@x.com,1,\n');
    expect(rows[0].status, SendStatus.invalid);
    expect(rows[0].error, contains('date'));
    expect(rows[1].status, SendStatus.ready);
    expect(rows[1].dateDefaulted, isTrue);
  });

  test('receipt_no must be a positive whole number', () {
    final rows = parse('name,email,amount,receipt_no\n'
        'A,a@x.com,1,795.0\n'
        'B,b@x.com,1,abc\n'
        'C,c@x.com,1,-5\n');
    expect(rows[0].recNo, 795);
    expect(rows[0].status, SendStatus.ready);
    expect(rows[1].status, SendStatus.invalid);
    expect(rows[2].status, SendStatus.invalid);
  });

  test('header below a title / sep= line; more header names', () {
    final rows = parse('Pavan Residency - September\n'
        '\n'
        'Receipt Number,Name,Email 1,Email 2,Amount (Rs),Payment Date\n'
        '12,A,a@x.com,b@x.com,700,25/09/2026\n');
    expect(rows.single.recNo, 12);
    expect(rows.single.emails, ['a@x.com', 'b@x.com']);
    expect(rows.single.amount, 700);
    expect(rows.single.date, '25-09-2026');

    final sep = parse('sep=;\nname;email;amount\nA;a@x.com;"7500,00"\n');
    expect(sep.single.amount, 7500);
  });

  test('UTF-16 without BOM is detected', () {
    final units = 'name,email,amount\nA,a@x.com,700\n'.codeUnits;
    final le = <int>[];
    for (final u in units) {
      le
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    final rows = CsvService.parse(Uint8List.fromList(le));
    expect(rows.single.amount, 700);
  });

  test('maintenance misspellings stay maintenance', () {
    for (final v in ['Mantenance', 'Maintenence', 'Mentainance']) {
      expect(ReceiptData.parseType(v), PaymentType.maintenance, reason: v);
    }
  });
}
