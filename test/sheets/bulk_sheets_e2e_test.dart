// End-to-end: the real Bulk screen with Google Sheets as the source, real
// SMTP over sockets (fake server from the existing bulk e2e test) and an
// in-memory Google backend.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/main.dart';
import 'package:pavan_residency/screens/bulk_screen.dart';
import 'package:pavan_residency/services/email_service.dart';
import 'package:pavan_residency/services/sent_log.dart';
import 'package:pavan_residency/services/settings_service.dart';
import 'package:pavan_residency/services/sheets/credential_store.dart';
import 'package:pavan_residency/services/sheets/google_credentials.dart';
import 'package:pavan_residency/services/sheets/sheets_config.dart';
import 'package:pavan_residency/services/sheets/sheets_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../bulk_parallel_e2e_test.dart' show FakeSmtpServer;
import 'fake_google.dart';
import 'test_credentials.dart';

const _timeout = Timeout(Duration(minutes: 3));
const _ssId = 'SPREADSHEET_ID_1234567890';

FakeGoogle _google({bool statusColumn = false}) => FakeGoogle(tabs: [
      FakeTab(1, 'Sep 2026', [
        [
          'name', 'email', 'amount', 'block', 'house_no', 'language',
          if (statusColumn) 'email_sent',
        ],
        ['Asha', 'asha@x.com', '7500', 'A', '101', 'english', if (statusColumn) ''],
        ['Ravi', 'ravi@x.com', '7500', 'A', '102', 'gujarati', if (statusColumn) 'FALSE'],
        ['Meena', 'meena@x.com', '7500', 'B', '201', 'hindi', if (statusColumn) ''],
        ['Bad', 'not-an-email', '7500', 'B', '202', '', if (statusColumn) ''],
        if (statusColumn)
          ['Done', 'done@x.com', '7500', 'C', '301', '', 'TRUE'],
      ]),
      FakeTab(2, 'Aug 2026', [
        ['name', 'email', 'amount'],
        ['Old', 'old@x.com', '100'],
      ]),
    ]);

Future<T> _withEnv<T>(
  WidgetTester tester,
  Future<T> Function(FakeSmtpServer server) body,
) async {
  final server = (await tester.runAsync(FakeSmtpServer.start))!;
  try {
    return await body(server);
  } finally {
    await tester.runAsync(server.close);
  }
}

/// Pumps the app on the Bulk tab. [google] is the identity's Drive; when
/// [remember] the sheet / tab are already chosen.
Future<void> _openBulk(
  WidgetTester tester,
  FakeSmtpServer server, {
  FakeGoogle? google,
  bool withCredentials = true,
  bool remember = true,
}) async {
  tester.view.physicalSize = const Size(1000, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final settings = AppSettings(
    host: '127.0.0.1',
    port: server.port,
    ssl: false,
    username: 'office@pavan.test',
    password: 'app-password',
    nextReceiptNo: 794,
    counterConfirmed: true,
  );
  SharedPreferences.setMockInitialValues({
    'pavan_settings_v1': jsonEncode(settings.toJson()),
    if (remember && google != null)
      'pavan_sheets_v1': jsonEncode(SheetsConfig(
        spreadsheetId: _ssId,
        spreadsheetName: 'Maintenance 2026',
        worksheetTitle: 'Sep 2026',
        worksheetId: 1,
      ).toJson()),
  });
  await tester.runAsync(() => SettingsService.save(settings));
  SentLog.resetForTesting();

  SheetsService.instance = SheetsService(
    store: MemoryCredentialStore(
        withCredentials ? GoogleCredentials.parse(credentialsJson()) : null),
    apiFactory: (_) async => google!.api(),
  );

  await tester.pumpWidget(const PavanApp());
  await tester.pumpAndSettle();
  await tester.tap(find.text('Bulk'));
  await tester.pumpAndSettle();
}


final _finalSnack = find.textContaining(RegExp(r'^Bulk send (finished|stopped)'));

Future<String> _sendAll(WidgetTester tester) async {
  ScaffoldMessenger.of(tester.element(find.byType(BulkScreen))).clearSnackBars();
  await tester.pumpAndSettle();
  final button = find.widgetWithText(FilledButton, 'Send All Emails');
  expect(button, findsOneWidget);
  await tester.runAsync(() => tester.tap(button));
  for (var i = 0; _finalSnack.evaluate().isEmpty; i++) {
    if (i > 3000) fail('the bulk send did not finish');
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
  }
  await tester.pumpAndSettle();
  return tester.widget<Text>(_finalSnack.first).data!;
}

Future<void> _loadRecipients(WidgetTester tester) async {
  await tester.tap(find.text('Load recipients'));
  await tester.pumpAndSettle();
}

String _chipOf(WidgetTester tester, String name) {
  final tile = find.ancestor(
      of: find.textContaining('$name  •'), matching: find.byType(ListTile));
  final chip = find.descendant(of: tile, matching: find.byType(Chip));
  return (tester.widget<Chip>(chip).label as Text).data!;
}

bool _hasText(String s) => find.textContaining(s).evaluate().isNotEmpty;

void main() {
  setUpAll(() => EmailService.allowInsecureForTesting = true);
  tearDownAll(() => EmailService.allowInsecureForTesting = false);

  testWidgets('Google Sheets is the default source; CSV is one tap away and untouched',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google();
      await _openBulk(tester, server, google: g);
      expect(find.text('Choose CSV File'), findsNothing);
      expect(find.text('Load recipients'), findsOneWidget);
      expect(find.text('Google Sheets'), findsOneWidget);

      await tester.tap(find.text('CSV File'));
      await tester.pumpAndSettle();
      expect(find.text('Choose CSV File'), findsOneWidget);
      expect(find.text('Load recipients'), findsNothing);
      // Switching sources does no Google writes.
      expect(g.writes, isEmpty);
    });
  }, timeout: _timeout);

  testWidgets('without credentials it explains what to do and does not fall back to CSV',
      (tester) async {
    await _withEnv(tester, (server) async {
      SharedPreferences.setMockInitialValues({});
      await _openBulk(tester, server, google: _google(), withCredentials: false);
      expect(find.textContaining('not set up yet'), findsOneWidget);
      expect(find.text('Choose CSV File'), findsNothing);
    });
  }, timeout: _timeout);

  testWidgets('choose spreadsheet and tab through the UI, then load; selection is remembered',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google();
      await _openBulk(tester, server, google: g, remember: false);

      expect(find.textContaining('mailer@proj-123.iam.gserviceaccount.com'),
          findsOneWidget);
      await tester.tap(find.byTooltip('Find spreadsheets shared with this account'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Maintenance 2026').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byType(DropdownButtonFormField<int>));
      await tester.pumpAndSettle();
      expect(find.text('Aug 2026'), findsWidgets); // both tabs are offered
      await tester.tap(find.text('Sep 2026').last);
      await tester.pumpAndSettle();
      await _loadRecipients(tester);

      expect(find.textContaining('4 rows'), findsOneWidget);
      expect(find.textContaining('Sheet row 2'), findsOneWidget);
      expect(find.textContaining('Old'), findsNothing,
          reason: 'only the selected tab is read');
      // Remembered for next time.
      final c = await tester.runAsync(SheetsConfigStore.load);
      expect([c!.spreadsheetId, c.worksheetTitle, c.worksheetId],
          [_ssId, 'Sep 2026', 1]);
      expect(g.writes, isEmpty, reason: 'loading never writes to the sheet');
    });
  }, timeout: _timeout);

  testWidgets(
      'confirmed sends -> TRUE, refused address -> FALSE, invalid row untouched, header added once',
      (tester) async {
    await _withEnv(tester, (server) async {
      server.rejectRcpt.add('meena@x.com');
      final g = _google();
      await _openBulk(tester, server, google: g);
      await _loadRecipients(tester);
      expect(_chipOf(tester, 'Bad'), '✗ fix');

      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 2 sent, 1 failed.');
      expect(server.messages.map((m) => m.rcpts.single).toSet(),
          {'asha@x.com', 'ravi@x.com'});

      final cells = g.tab('Sep 2026').cells;
      expect(cells[0].last, 'email_sent');
      expect(cells[0].where((c) => c == 'email_sent'), hasLength(1));
      expect(cells[1][6], true); // Asha
      expect(cells[2][6], true); // Ravi
      expect(cells[3][6], false); // Meena: refused -> FALSE
      expect(cells[4].length, lessThanOrEqualTo(6), reason: 'invalid row: no status');
      expect(g.calls.any((c) => c.path.contains(':append')), isFalse);
      expect(g.tab('Aug 2026').cells, hasLength(2));

      expect(_chipOf(tester, 'Asha'), '✓ sent');
      expect(_chipOf(tester, 'Meena'), '✗ error');
      expect(find.textContaining('status: TRUE'), findsNWidgets(2));
      expect(find.textContaining('status: FALSE'), findsOneWidget);
    });
  }, timeout: _timeout);

  testWidgets('a TRUE row is skipped, a FALSE row is retried and flips to TRUE',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google(statusColumn: true);
      await _openBulk(tester, server, google: g);
      await _loadRecipients(tester);
      expect(_chipOf(tester, 'Done'), '✓ sent before');

      final writesBefore = g.writes.length;
      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 3 sent, 0 failed.');
      expect(server.messages.any((m) => m.rcpts.contains('done@x.com')), isFalse);

      final cells = g.tab('Sep 2026').cells;
      expect(cells[2][6], true, reason: 'Ravi was FALSE, now delivered');
      expect(cells[5][6], 'TRUE', reason: 'Done is untouched');
      expect(cells[0].where((c) => c == 'email_sent'), hasLength(1),
          reason: 'the existing column is reused');
      expect(g.tab('Sep 2026').columnCount, 26);
      expect(g.writes.length, greaterThan(writesBefore));
    });
  }, timeout: _timeout);

  testWidgets(
      'status write fails after a successful send: reported as "sent, status not saved", '
      'never re-sent, and can be saved later', (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google(statusColumn: true);
      await _openBulk(tester, server, google: g);
      await _loadRecipients(tester);

      // Status writes are refused (e.g. access revoked mid-run).
      var refuse = false;
      g.onCall = (c) {
        if (refuse && c.path.endsWith('values:batchUpdate')) {
          g.failures.add(403);
        }
      };
      refuse = true;
      final snack = await _sendAll(tester);
      expect(snack, contains('3 sent, 0 failed'));
      expect(snack, contains('could not be saved to the Google Sheet'));
      expect(snack, contains('emails themselves are not affected'));
      expect(server.messages, hasLength(3));
      expect(_chipOf(tester, 'Asha'), '✓ sent',
          reason: 'the email is NOT reported as failed');
      expect(_hasText('Email sent, but its status could not be saved'), isTrue);
      expect(g.tab('Sep 2026').cells[1][6], '');

      // Reloading the sheet does not mail anybody again: this phone knows
      // they were sent, and offers to save the owed statuses.
      refuse = false;
      await _loadRecipients(tester);
      expect(_chipOf(tester, 'Asha'), '✓ sent before');
      expect(find.text('Save 3 pending statuses to the sheet'), findsOneWidget);
      await tester.runAsync(() => tester.tap(find.widgetWithText(FilledButton, 'Send All Emails')));
      await tester.pumpAndSettle();
      expect(server.messages, hasLength(3),
          reason: 'nothing is sent a second time');

      await tester.tap(find.text('Save 3 pending statuses to the sheet'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      final cells = g.tab('Sep 2026').cells;
      expect([cells[1][6], cells[2][6], cells[3][6]], [true, true, true]);
      expect(find.text('Save 3 pending statuses to the sheet'), findsNothing);
      expect(server.messages, hasLength(3));
    });
  }, timeout: _timeout);

  testWidgets('viewer-only access: nothing is sent and the reason is shown',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google()..canEdit = false;
      await _openBulk(tester, server, google: g);
      await _loadRecipients(tester);
      await tester.runAsync(() => tester.tap(find.text('Send All Emails')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await tester.pumpAndSettle();
      expect(find.textContaining('Viewer only'), findsOneWidget);
      expect(find.textContaining('No emails were sent'), findsOneWidget);
      expect(server.messages, isEmpty);
      expect(server.connections, 0);
      expect(g.tab('Sep 2026').cells[0], hasLength(6), reason: 'no column added');
    });
  }, timeout: _timeout);

  testWidgets('a Sheets error is shown and stays on Google Sheets (no silent CSV)',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google();
      await _openBulk(tester, server, google: g);
      g.failures.addAll(List.filled(10, 403));
      await tester.tap(find.text('Load recipients'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Share the spreadsheet'), findsOneWidget);
      expect(find.text('Choose CSV File'), findsNothing);
      expect(find.text('Load recipients'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    });
  }, timeout: _timeout);

  testWidgets('an unsuitable worksheet (no email column) is explained',
      (tester) async {
    await _withEnv(tester, (server) async {
      final g = FakeGoogle(tabs: [
        FakeTab(1, 'Sep 2026', [
          ['name', 'amount'],
          ['Asha', '100'],
        ])
      ]);
      await _openBulk(tester, server, google: g);
      await _loadRecipients(tester);
      expect(find.textContaining('No email column'), findsOneWidget);
    });
  }, timeout: _timeout);

  testWidgets('CSV workflow does not touch Google at all', (tester) async {
    await _withEnv(tester, (server) async {
      final g = _google();
      await _openBulk(tester, server, google: g);
      final atStart = g.calls.length; // read-only tab list of the remembered sheet
      expect(g.calls.every((c) => c.method == 'GET'), isTrue);
      await tester.tap(find.text('CSV File'));
      await tester.pumpAndSettle();
      expect(g.calls.length, atStart);
      expect(g.writes, isEmpty);
      expect(find.text('Choose CSV File'), findsOneWidget);
    });
  }, timeout: _timeout);
}
