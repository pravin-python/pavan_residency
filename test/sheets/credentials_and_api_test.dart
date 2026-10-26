import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pavan_residency/services/sheets/credential_store.dart';
import 'package:pavan_residency/services/sheets/google_credentials.dart';
import 'package:pavan_residency/services/sheets/sheets_api.dart';
import 'package:pavan_residency/services/sheets/sheets_config.dart';
import 'package:pavan_residency/services/sheets/sheets_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_google.dart';
import 'test_credentials.dart';

void main() {
  group('credential validation', () {
    test('accepts a real-shaped service-account key', () {
      final c = GoogleCredentials.parse(credentialsJson());
      expect(c.clientEmail, 'mailer@proj-123.iam.gserviceaccount.com');
      expect(c.projectId, 'proj-123');
    });

    test('only the fields needed to sign in are kept', () {
      final stored =
          GoogleCredentials.parse(credentialsJson()).toStorageJson();
      expect(stored, isNot(contains('private_key_id')));
      expect(stored, isNot(contains('auth_uri')));
      expect(stored, contains('private_key'));
      // Round trip.
      expect(GoogleCredentials.parse(stored).clientEmail,
          'mailer@proj-123.iam.gserviceaccount.com');
    });

    void rejects(String text, Pattern message) {
      expect(
        () => GoogleCredentials.parse(text),
        throwsA(isA<CredentialException>()
            .having((e) => e.message, 'message', contains(message))),
      );
    }

    test('rejects files that are not service-account keys', () {
      rejects('', 'empty');
      rejects('   ', 'empty');
      rejects('not json {', 'not a valid JSON');
      rejects('[1,2]', 'not a Google credentials');
      rejects('{"hello":"world"}', 'not a Google service-account');
      rejects('{"installed":{"client_id":"x"}}', 'OAuth client');
      rejects('{"web":{"client_id":"x"}}', 'OAuth client');
      rejects('{"type":"authorized_user"}', 'personal');
      rejects('x' * (GoogleCredentials.maxFileChars + 1), 'too large');
    });

    test('rejects incomplete / altered key files and names what is missing', () {
      rejects(credentialsJson(without: ['private_key']), 'private_key');
      rejects(credentialsJson(without: ['client_email', 'client_id']),
          'client_email, client_id');
      rejects(credentialsJson(override: {'client_email': 42}), 'client_email');
      rejects(credentialsJson(email: 'someone@gmail.com'), 'gserviceaccount');
      rejects(
          credentialsJson(
              override: {'token_uri': 'https://evil.example.com/token'}),
          'does not point to Google');
      rejects(
          credentialsJson(
              override: {'token_uri': 'http://oauth2.googleapis.com/token'}),
          'does not point to Google');
      rejects(
          credentialsJson(override: {
            'private_key': '-----BEGIN PRIVATE KEY-----\nAAAA\n'
                '-----END PRIVATE KEY-----\n'
          }),
          'private key');
      rejects(credentialsJson(override: {'private_key': 'garbage'}),
          'private key');
    });

    test('error messages never contain the key or other file values', () {
      final bad = credentialsJson(
          override: {'private_key': '-----BEGIN PRIVATE KEY-----\nQUJD\n'
              '-----END PRIVATE KEY-----', 'client_id': 'SECRET-CLIENT-ID'});
      try {
        GoogleCredentials.parse(bad);
        fail('should have thrown');
      } on CredentialException catch (e) {
        expect(e.message, isNot(contains('QUJD')));
        expect(e.message, isNot(contains('SECRET-CLIENT-ID')));
        expect(e.message, isNot(contains('BEGIN')));
      }
    });

    test('toString never prints the private key', () {
      final c = GoogleCredentials.parse(credentialsJson());
      expect('$c', isNot(contains('PRIVATE')));
      expect('$c', contains('gserviceaccount.com'));
    });
  });

  group('secure configuration', () {
    test('the key lives in secure storage, never in SharedPreferences',
        () async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureCredentialStore();
      final service = SheetsService(store: store);

      await service.saveFromJson(credentialsJson());

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty,
          reason: 'the credentials must not be an ordinary preference');
      expect(
          prefs.getKeys().map(prefs.get).join(), isNot(contains('PRIVATE')));
      final back = await store.read();
      expect(back!.clientEmail, 'mailer@proj-123.iam.gserviceaccount.com');
    });

    test('persists across a restart (new service, same storage)', () async {
      FlutterSecureStorage.setMockInitialValues({});
      await SheetsService(store: SecureCredentialStore())
          .saveFromJson(credentialsJson());
      final restarted = SheetsService(store: SecureCredentialStore());
      expect((await restarted.credentials())!.projectId, 'proj-123');
    });

    test('an invalid file does not replace or erase the saved key', () async {
      final service =
          SheetsService(store: MemoryCredentialStore());
      await service.saveFromJson(credentialsJson());
      await expectLater(service.saveFromJson('{"type":"service_account"}'),
          throwsA(isA<CredentialException>()));
      expect((await service.credentials())!.clientEmail,
          'mailer@proj-123.iam.gserviceaccount.com');
    });

    test('replace and remove', () async {
      final service = SheetsService(store: MemoryCredentialStore());
      var bumps = 0;
      service.changes.addListener(() => bumps++);
      await service.saveFromJson(credentialsJson());
      await service.saveFromJson(
          credentialsJson(email: 'other@proj-9.iam.gserviceaccount.com'));
      expect((await service.credentials())!.clientEmail,
          'other@proj-9.iam.gserviceaccount.com');
      await service.remove();
      expect(await service.credentials(), isNull);
      expect(bumps, 3);
      await expectLater(
          service.api(), throwsA(isA<CredentialException>()),
          reason: 'no credentials -> a clear instruction, not a crash');
    });

    test('damaged stored data is reported, not trusted', () async {
      FlutterSecureStorage.setMockInitialValues(
          {'pavan_google_service_account_v1': '{"type":"service_account"}'});
      await expectLater(SecureCredentialStore().read(),
          throwsA(isA<CredentialException>()));
      FlutterSecureStorage.setMockInitialValues({});
    });
  });

  group('config', () {
    test('parses links and ids', () {
      final l = SpreadsheetLink.parse(
          'https://docs.google.com/spreadsheets/d/1AbC_dEf-1234567890abcdefGHIJ/edit#gid=987');
      expect(l!.id, '1AbC_dEf-1234567890abcdefGHIJ');
      expect(l.gid, 987);
      expect(
          SpreadsheetLink.parse(
                  'https://docs.google.com/spreadsheets/u/1/d/ABCDEFGHIJKLMNOPQRSTUV/edit')!
              .id,
          'ABCDEFGHIJKLMNOPQRSTUV');
      expect(SpreadsheetLink.parse(' ABCDEFGHIJKLMNOPQRSTUV ')!.gid, isNull);
      expect(SpreadsheetLink.parse('hello'), isNull);
      expect(SpreadsheetLink.parse('https://example.com/spreadsheets/d/x'),
          isNull);
      expect(SpreadsheetLink.parse(''), isNull);
    });

    test('status column title: default and validation', () {
      expect(SheetsConfig().statusHeader, 'email_sent');
      expect(SheetsConfig.validStatusHeader('email_sent'), isNull);
      expect(SheetsConfig.validStatusHeader('Mail Status'), isNull);
      expect(SheetsConfig.validStatusHeader(''), isNotNull);
      expect(SheetsConfig.validStatusHeader('   '), isNotNull);
      // Would be mistaken for the recipient's data columns.
      expect(SheetsConfig.validStatusHeader('email'), isNotNull);
      expect(SheetsConfig.validStatusHeader('Amount'), isNotNull);
      expect(SheetsConfig.validStatusHeader('x' * 51), isNotNull);
    });

    test('the selection is remembered', () async {
      SharedPreferences.setMockInitialValues({});
      await SheetsConfigStore.save(SheetsConfig(
        spreadsheetId: 'SID',
        spreadsheetName: 'Maintenance',
        worksheetTitle: 'Sep 2026',
        worksheetId: 77,
        statusHeader: 'mail_status',
      ));
      final c = await SheetsConfigStore.load();
      expect(
          [c.spreadsheetId, c.worksheetTitle, c.worksheetId, c.statusHeader],
          ['SID', 'Sep 2026', 77, 'mail_status']);
      expect(c.hasSelection, isTrue);
      SharedPreferences.setMockInitialValues({'pavan_sheets_v1': '{oops'});
      expect((await SheetsConfigStore.load()).statusHeader, 'email_sent');
    });
  });

  group('A1 helpers', () {
    test('column letters', () {
      expect([0, 1, 25, 26, 27, 51, 52, 701, 702].map(A1.column),
          ['A', 'B', 'Z', 'AA', 'AB', 'AZ', 'BA', 'ZZ', 'AAA']);
    });
    test('quoting', () {
      expect(A1.sheet("Rahul's tab"), "'Rahul''s tab'");
      expect(A1.cell('Sheet 1', 2, 5), "'Sheet 1'!C5");
      expect(A1.wholeColumn('S', 4), "'S'!E:E");
    });
  });

  group('spreadsheet and worksheet selection', () {
    FakeGoogle google() => FakeGoogle(tabs: [
          FakeTab(0, 'Sep 2026', [
            ['name', 'email', 'amount'],
            ['Asha', 'asha@x.com', '7500'],
          ]),
          FakeTab(11, 'Aug 2026', [
            ['name', 'email', 'amount'],
            ['Old', 'old@x.com', '1'],
          ]),
        ]);

    test('lists every spreadsheet shared with the account (paged)', () async {
      final g = google()
        ..otherSpreadsheets.addAll({'B' * 25: 'Second', 'C' * 25: 'Third'})
        ..drivePageSize = 1;
      final list = await g.api().listSpreadsheets();
      expect(list.map((s) => s.name), ['Maintenance 2026', 'Second', 'Third']);
      // 3 pages, and only the Drive metadata is asked for.
      expect(g.calls, hasLength(3));
      expect(g.calls.first.url.queryParameters['q'],
          contains('application/vnd.google-apps.spreadsheet'));
    });

    test('lists the worksheet tabs in order with their ids', () async {
      final meta = await google().api().getSpreadsheet('SPREADSHEET_ID_1234567890');
      expect(meta.title, 'Maintenance 2026');
      expect(meta.worksheets.map((w) => (w.sheetId, w.title)),
          [(0, 'Sep 2026'), (11, 'Aug 2026')]);
    });

    test('reads only the selected worksheet', () async {
      final g = google();
      final rows =
          await g.api().readSheet('SPREADSHEET_ID_1234567890', 'Aug 2026');
      expect(rows[1], ['Old', 'old@x.com', '1']);
      final reads = g.calls.where((c) => c.path.contains('/values/'));
      expect(reads, hasLength(1));
      expect(Uri.decodeComponent(reads.single.path), contains("'Aug 2026'"));
      expect(Uri.decodeComponent(reads.single.path), isNot(contains('Sep')));
    });

    test('a tab with an apostrophe in its name is addressed correctly',
        () async {
      final g = FakeGoogle(tabs: [
        FakeTab(5, "Rahul's list", [
          ['name', 'email'],
          ['A', 'a@x.com'],
        ])
      ]);
      expect(
          (await g.api().readSheet('SPREADSHEET_ID_1234567890', "Rahul's list"))[1],
          ['A', 'a@x.com']);
    });

    test('unknown spreadsheet -> clear message naming the account to share with',
        () async {
      final g = google();
      await expectLater(
          g.api().getSpreadsheet('NOPE'),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.statusCode, 'status', 404)
              .having((e) => e.message, 'message',
                  contains('mailer@proj.iam.gserviceaccount.com'))));
    });

    test('unknown tab is a 400 with Google\'s reason, not a crash', () async {
      await expectLater(
          google().api().readSheet('SPREADSHEET_ID_1234567890', 'Missing'),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.statusCode, 'status', 400)));
    });

    test('Drive API disabled: listing explains it, canEdit is unknown, links still work',
        () async {
      final g = google()..driveEnabled = false;
      final api = g.api();
      await expectLater(
          api.listSpreadsheets(),
          throwsA(isA<SheetsApiException>().having(
              (e) => e.message, 'message', contains('not enabled'))));
      expect(await api.canEdit('SPREADSHEET_ID_1234567890'), isNull);
      // Sheets itself still works.
      expect((await api.getSpreadsheet('SPREADSHEET_ID_1234567890')).worksheets,
          hasLength(2));
    });

    test('canEdit reflects the Drive capability', () async {
      final g = google();
      expect(await g.api().canEdit('SPREADSHEET_ID_1234567890'), isTrue);
      g.canEdit = false;
      expect(await g.api().canEdit('SPREADSHEET_ID_1234567890'), isFalse);
    });

    test('403 without the API-disabled reason asks to share the sheet',
        () async {
      final api = SheetsApi(
          MockClient((_) async => http.Response(
              '{"error":{"code":403,"message":"The caller does not have permission","errors":[{"reason":"forbidden"}]}}',
              403)),
          serviceAccountEmail: 'mailer@proj.iam.gserviceaccount.com');
      await expectLater(
          api.getSpreadsheet('x'),
          throwsA(isA<SheetsApiException>().having((e) => e.message, 'message',
              allOf(contains('Share the spreadsheet'), contains('Editor')))));
    });
  });

  group('API failures and retries', () {
    FakeGoogle google() => FakeGoogle(tabs: [
          FakeTab(0, 'T', [
            ['name', 'email']
          ])
        ]);
    const id = 'SPREADSHEET_ID_1234567890';

    test('429 then 503 then success: retried with growing waits', () async {
      final g = google()..failures.addAll([429, 503, 0]);
      final waits = <Duration>[];
      final api = SheetsApi(g.client, delay: (d) async => waits.add(d));
      expect((await api.readSheet(id, 'T')).first, ['name', 'email']);
      expect(g.calls, hasLength(3));
      expect(waits, hasLength(2));
      expect(waits[0], const Duration(seconds: 1)); // honours Retry-After
      expect(waits[1], greaterThan(Duration.zero));
    });

    test('backoff doubles on repeated 5xx', () async {
      final g = google()..failures.addAll([500, 500, 500, 0]);
      final waits = <Duration>[];
      final api = SheetsApi(g.client, delay: (d) async => waits.add(d));
      await api.readSheet(id, 'T');
      expect(waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
      ]);
    });

    test('gives up after maxAttempts with a readable message', () async {
      final g = google()..failures.addAll(List.filled(10, 503));
      await expectLater(
          g.api(maxAttempts: 3).readSheet(id, 'T'),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.statusCode, 'status', 503)
              .having((e) => e.message, 'message', contains('temporarily'))));
      expect(g.calls, hasLength(3));
    });

    test('quota (429) that never clears ends with a rate-limit message',
        () async {
      final g = google()..failures.addAll(List.filled(10, 429));
      await expectLater(
          g.api(maxAttempts: 2).readSheet(id, 'T'),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.message, 'message', contains('rate limit'))));
    });

    test('permanent errors are not retried', () async {
      final g = google()..failures.addAll([404]);
      await expectLater(
          g.api().readSheet(id, 'T'), throwsA(isA<SheetsApiException>()));
      expect(g.calls, hasLength(1));
    });

    test('timeouts and dropped connections are retried for reads and cell writes',
        () async {
      for (final fail in <Object>[
        TimeoutException('slow'),
        const SocketException('reset'),
        http.ClientException('closed'),
      ]) {
        final g = google();
        var thrown = false;
        g.onCall = (_) {
          if (!thrown) {
            thrown = true;
            throw fail;
          }
        };
        await g.api().writeCells(id, {"'T'!A1": 'x'});
        expect(g.calls, hasLength(2), reason: '$fail');
        expect(g.tab('T').cells.first.first, 'x');
      }
    });

    test('network down for good: friendly message, bounded attempts', () async {
      final g = google()..onCall = (_) => throw const SocketException('down');
      await expectLater(
          g.api(maxAttempts: 3).readSheet(id, 'T'),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.reason, 'reason', 'network')
              .having((e) => e.message, 'message', contains('internet'))));
      expect(g.calls, hasLength(3));
    });

    test('adding a column is NOT repeated after an unknown outcome', () async {
      final g = google()..onCall = (_) => throw TimeoutException('slow');
      await expectLater(g.api().addColumns(id, 0, 1),
          throwsA(isA<SheetsApiException>()));
      expect(g.calls, hasLength(1),
          reason: 'a repeated appendDimension could add two columns');
    });

    test('adding a column IS retried when Google rejected it for quota', () async {
      final g = google()..failures.addAll([429, 0]);
      await g.api().addColumns(id, 0, 2);
      expect(g.calls, hasLength(2));
      expect(g.tab('T').columnCount, 28); // added once, not twice
    });
  });
}
