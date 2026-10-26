import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/csv_service.dart';
import 'package:pavan_residency/services/sheets/sheet_layout.dart';
import 'package:pavan_residency/services/sheets/sheet_recipient_reader.dart';
import 'package:pavan_residency/services/sheets/sheet_status_writer.dart';
import 'package:pavan_residency/services/sheets/sheets_api.dart';
import 'package:pavan_residency/services/sheets/sheets_service.dart';

import 'fake_google.dart';

const id = 'SPREADSHEET_ID_1234567890';

List<List<String>> table(List<List<String>> rows) => rows;

void main() {
  group('reading recipients', () {
    final header = [
      'receipt_no', 'block', 'house_no', 'name', 'amount', 'mode',
      'cheque_no', 'type', 'transaction_number', 'bank_name', //
      'received_date', 'email', 'language',
    ];

    test('same result as the CSV import for the same data', () {
      final rows = [
        header,
        ['1', 'A', '101', 'Madanlal', '7,500', 'Cheque', '', 'Maintenance', '', '', '2026-09-25', 'a@x.com', 'English'],
        ['2', 'a', '102', 'Vinod', '7500', 'Online', '', 'Transfer Fee', 'UTR1', 'BOI', '', 'b@x.com', 'Hindi'],
        ['', 'B', '201', 'Asha', '₹ 8000', '', '79800', 'Deposit', '', 'BOI', '25/09/2026', 'c@x.com', 'Gujarati'],
        ['', 'B', '202', 'Other', '100', 'Cash', '', 'Parking charges', '', '', '', 'd@x.com', ''],
      ];
      final csv = rows.map((r) => r.map((c) => '"$c"').join(',')).join('\n');
      final fromCsv = CsvService.parse(Uint8List.fromList(utf8.encode(csv)));
      final fromSheet = SheetRecipientReader.read(rows).rows;

      expect(fromSheet, hasLength(fromCsv.length));
      for (var i = 0; i < fromCsv.length; i++) {
        final a = fromCsv[i], b = fromSheet[i];
        expect(
          [b.name, b.email, b.block, b.house, b.amount, b.mode, b.chqNo, b.chqBank, b.txnNo, b.lang, b.type, b.remark, b.recNo, b.date, b.status],
          [a.name, a.email, a.block, a.house, a.amount, a.mode, a.chqNo, a.chqBank, a.txnNo, a.lang, a.type, a.remark, a.recNo, a.date, a.status],
          reason: 'row $i',
        );
      }
    });

    test('maps header aliases and keeps personalisation fields', () {
      final r = SheetRecipientReader.read([
        ['Name', 'Email ID', 'Flat No', 'Block No', 'Amount (Rs)', 'Lang'],
        ['Asha Patel', 'asha@x.com', '12', 'c', '7500', 'gu'],
      ]).rows.single;
      expect(r.name, 'Asha Patel');
      expect(r.email, 'asha@x.com');
      expect(r.house, '12');
      expect(r.block, 'C');
      expect(r.amount, 7500);
      expect(r.lang, 'gu');
      expect(r.status, SendStatus.ready);
    });

    test('rows carry their REAL worksheet row, even with titles, blanks and invalid rows',
        () {
      final load = SheetRecipientReader.read([
        ['Society maintenance'], // row 1: a title
        [], // row 2
        ['name', 'email', 'amount'], // row 3: header
        ['Asha', 'asha@x.com', '100'], // row 4
        [], // row 5: blank
        ['Bad', 'not-an-email', '100'], // row 6: invalid
        ['', '', ''], // row 7: blank
        ['Ravi', 'ravi@x.com', '200'], // row 8
      ]);
      expect(load.layout.headerRow, 3);
      expect(load.rows.map((r) => (r.name, r.sourceRow, r.status)), [
        ('Asha', 4, SendStatus.ready),
        ('Bad', 6, SendStatus.invalid),
        ('Ravi', 8, SendStatus.ready),
      ]);
      // The list position of Ravi (2) is NOT his sheet row (8).
      expect(load.rows[2].sourceRow, isNot(2));
    });

    test('missing and invalid emails are flagged, not sent', () {
      final rows = SheetRecipientReader.read([
        ['name', 'email', 'amount'],
        ['NoMail', '', '100'],
        ['Bad', 'a@', '100'],
        ['Spaces', 'a b@x.com', '100'],
        ['Two', 'a@x.com, b@x.com', '100'],
        ['NoAmount', 'n@x.com', ''],
      ]).rows;
      expect(rows.map((r) => r.status), [
        SendStatus.invalid,
        SendStatus.invalid,
        SendStatus.invalid,
        SendStatus.ready,
        SendStatus.invalid,
      ]);
      expect(rows[0].error, contains('email'));
      expect(rows[4].error, contains('amount'));
    });

    test('an identical receipt twice: the later one is blocked; shared email is fine',
        () {
      final rows = SheetRecipientReader.read([
        ['name', 'email', 'amount', 'block', 'house_no'],
        ['Asha', 'asha@x.com', '100', 'A', '1'],
        ['Asha', 'asha@x.com', '100', 'A', '1'], // pasted twice
        ['Asha', 'asha@x.com', '100', 'A', '2'], // same person, other flat
      ]).rows;
      expect(rows[0].status, SendStatus.ready);
      expect(rows[1].status, SendStatus.invalid);
      expect(rows[1].error, 'duplicate of row 2');
      expect(rows[2].status, SendStatus.ready);
    });

    test('existing status is shown: TRUE = sent (skipped), FALSE / blank = ready',
        () {
      final rows = SheetRecipientReader.read([
        ['name', 'email', 'amount', 'Email_Sent'],
        ['A', 'a@x.com', '1', 'TRUE'],
        ['B', 'b@x.com', '2', 'FALSE'],
        ['C', 'c@x.com', '3', ''],
        ['D', 'd@x.com', '4', 'true'],
        ['E', 'e@x.com', '5'],
      ]).rows;
      expect(rows.map((r) => r.status), [
        SendStatus.sent,
        SendStatus.ready,
        SendStatus.ready,
        SendStatus.sent,
        SendStatus.ready,
      ]);
      expect(rows.map((r) => r.sheetStatus), ['TRUE', 'FALSE', '', 'true', '']);
      expect(rows[0].sentBefore, isTrue);
    });

    test('no header row / no email column are explained', () {
      expect(() => SheetRecipientReader.read([['foo', 'bar'], ['1', '2']]),
          throwsA(isA<SheetFormatException>()));
      expect(
          () => SheetRecipientReader.read([
                ['name', 'amount'],
                ['A', '1']
              ]),
          throwsA(isA<SheetFormatException>()
              .having((e) => e.message, 'message', contains('email'))));
      expect(SheetRecipientReader.read([['name', 'email', 'amount']]).rows,
          isEmpty);
    });

    test('CSV parsing itself is unchanged: bytes still go through parse()', () {
      final r = CsvService.parse(Uint8List.fromList(utf8
          .encode('name,email,amount\nAsha,asha@x.com,100\n\n,,\nRavi,r@x.com,5')));
      expect(r.map((e) => e.name), ['Asha', 'Ravi']);
      expect(r.every((e) => e.sourceRow == null), isTrue,
          reason: 'CSV rows have no sheet row');
    });
  });

  group('status column', () {
    FakeGoogle sheet({List<List<Object?>>? cells, int? columns}) => FakeGoogle(
          tabs: [
            FakeTab(
                1,
                'Sep',
                cells ??
                    [
                      ['name', 'email', 'amount', 'notes'],
                      ['Asha', 'asha@x.com', '100', 'vip'],
                      ['Ravi', 'ravi@x.com', '200', ''],
                    ],
                columns: columns),
          ],
        );

    SheetStatusWriter writer(FakeGoogle g, {String header = 'email_sent'}) =>
        SheetStatusWriter(
          api: g.api(),
          spreadsheetId: id,
          worksheetId: 1,
          worksheetTitle: 'Sep',
          statusHeader: header,
        );

    List<List<Object?>> snapshot(FakeGoogle g) =>
        [for (final r in g.tab('Sep').cells) List<Object?>.of(r)];

    test('an existing status column is found (any case / spacing) and reused',
        () async {
      for (final h in ['email_sent', 'Email_Sent', 'EMAIL SENT', ' email-sent ']) {
        final g = sheet(cells: [
          ['name', 'email', 'amount', h],
          ['Asha', 'asha@x.com', '100', ''],
        ]);
        final w = writer(g);
        await w.ensureStatusColumn();
        expect(w.statusColumn, 3, reason: h);
        expect(g.writes, isEmpty, reason: 'nothing to create for "$h"');
        expect(g.tab('Sep').columnCount, 26);
      }
    });

    test('a missing status column is created once, at the end of the header',
        () async {
      final g = sheet();
      final before = snapshot(g);
      final w = writer(g);
      await w.ensureStatusColumn();
      expect(w.statusColumn, 4); // E, right after "notes"
      final after = snapshot(g);
      expect(after[0], ['name', 'email', 'amount', 'notes', 'email_sent']);
      // Every other cell is exactly as it was.
      expect(after.skip(1).toList(), before.skip(1).toList());
    });

    test('never duplicated: repeated runs (new writer each time) add nothing',
        () async {
      final g = sheet();
      for (var run = 0; run < 3; run++) {
        await writer(g).ensureStatusColumn();
      }
      final headers = g.tab('Sep').cells.first;
      expect(headers.where((h) => h == 'email_sent'), hasLength(1));
      expect(g.writes.length, 1, reason: 'only the first run wrote the header');
    });

    test('a custom title is honoured; default title is not created then', () async {
      final g = sheet();
      await writer(g, header: 'Mail Status').ensureStatusColumn();
      expect(g.tab('Sep').cells.first.last, 'Mail Status');
      expect(g.tab('Sep').cells.first, isNot(contains('email_sent')));
    });

    test('the new column goes after the widest data, never over it', () async {
      // A data column without a header (column E has values) -> header in F.
      final g = sheet(cells: [
        ['name', 'email', 'amount'],
        ['Asha', 'asha@x.com', '100', 'x', 'orphan data'],
      ]);
      final w = writer(g);
      await w.ensureStatusColumn();
      expect(w.statusColumn, 5);
      expect(g.tab('Sep').cells[1], ['Asha', 'asha@x.com', '100', 'x', 'orphan data']);
      expect(g.tab('Sep').cells[0][5], 'email_sent');
    });

    test('a full grid is widened first (otherwise Google rejects the write)',
        () async {
      final g = sheet(columns: 4); // A..D exist and are all used
      await writer(g).ensureStatusColumn();
      expect(g.tab('Sep').columnCount, 5);
      expect(g.tab('Sep').cells.first[4], 'email_sent');
      expect(g.calls.any((c) => c.path.endsWith(':batchUpdate')), isTrue);
    });

    test('header below a title row goes in the real header row', () async {
      final g = sheet(cells: [
        ['Society maintenance'],
        ['name', 'email', 'amount'],
        ['Asha', 'asha@x.com', '100'],
      ]);
      await writer(g).ensureStatusColumn();
      expect(g.tab('Sep').cells[0], ['Society maintenance']);
      expect(g.tab('Sep').cells[1].last, 'email_sent');
    });

    test('two columns with the title: only the first is used, with a warning',
        () {
      final load = SheetRecipientReader.read([
        ['name', 'email', 'amount', 'email_sent', 'Email Sent'],
        ['A', 'a@x.com', '1', 'TRUE', ''],
      ]);
      expect(load.layout.statusCol, 3);
      expect(load.layout.extraStatusCols, [4]);
      expect(load.warnings, hasLength(1));
    });
  });

  group('writing statuses', () {
    late FakeGoogle g;
    late SheetsSession session;

    setUp(() {
      g = FakeGoogle(tabs: [
        FakeTab(1, 'Sep', [
          ['Society maintenance'],
          ['name', 'email', 'amount', 'total'],
          ['Asha', 'asha@x.com', '100', const Formula('=C3*2', '200')],
          [],
          ['Bad', 'oops', '100', ''],
          ['Ravi', 'ravi@x.com', '200', const Formula('=C6*2', '400')],
          ['Meena', 'meena@x.com', '300', ''],
        ]),
        FakeTab(2, 'Other tab', [
          ['name', 'email'],
          ['Asha', 'asha@x.com'],
        ]),
      ]);
      session = SheetsSession(
        api: g.api(),
        spreadsheetId: id,
        spreadsheetName: 'Maintenance 2026',
        worksheetId: 1,
        worksheetTitle: 'Sep',
        statusHeader: 'email_sent',
      );
    });

    Future<SheetLoad> loaded() async {
      await session.prepareForSending();
      return session.load();
    }

    test('TRUE goes to the right row, FALSE to another; nothing else changes',
        () async {
      final before = [for (final r in g.tab('Sep').cells) List<Object?>.of(r)];
      final load = await loaded();
      final ravi = load.rows.firstWhere((r) => r.name == 'Ravi');
      final meena = load.rows.firstWhere((r) => r.name == 'Meena');
      expect(ravi.sourceRow, 6);
      expect(meena.sourceRow, 7);

      final out = await session.writer
          .write([StatusUpdate(ravi, true), StatusUpdate(meena, false)]);
      expect(out.every((o) => o.saved), isTrue);

      final cells = g.tab('Sep').cells;
      final col = session.writer.statusColumn!;
      expect(col, 4);
      expect(cells[5][col], true); // Ravi -> TRUE
      expect(cells[6][col], false); // Meena -> FALSE
      // Everything except the header + the two status cells is untouched,
      // formulas included.
      for (var r = 0; r < before.length; r++) {
        for (var c = 0; c < before[r].length; c++) {
          if (r == 1 && c == col) continue;
          expect(cells[r][c], before[r][c], reason: 'cell r$r c$c');
        }
      }
      expect((cells[2][3] as Formula).formula, '=C3*2');
      expect((cells[5][3] as Formula).formula, '=C6*2');
      // Asha's and the invalid row's status cells were never touched.
      expect(cells[2].length, lessThanOrEqualTo(col));
      // The other worksheet is untouched.
      expect(g.tab('Other tab').cells, [
        ['name', 'email'],
        ['Asha', 'asha@x.com']
      ]);
    });

    test('statuses are real TRUE / FALSE cells, never appended rows', () async {
      final load = await loaded();
      await session.writer.write([StatusUpdate(load.rows.first, true)]);
      expect(g.calls.any((c) => c.path.contains(':append')), isFalse);
      expect(g.tab('Sep').cells.length, 7, reason: 'no row was added');
      final body = g.writes.last.body as Map;
      expect(body['valueInputOption'], 'RAW');
      expect(((body['data'] as List).single as Map)['values'], [
        [true]
      ]);
    });

    test('a moved row is found again by its email; the old row is not touched',
        () async {
      final load = await loaded();
      final ravi = load.rows.firstWhere((r) => r.name == 'Ravi'); // row 6
      // Somebody inserts two rows above him after loading.
      g.tab('Sep').cells.insertAll(2, [[], []]);

      final out = await session.writer.write([StatusUpdate(ravi, true)]);
      expect(out.single.saved, isTrue);
      final cells = g.tab('Sep').cells;
      expect(cells[7][1], 'ravi@x.com');
      expect(cells[7][4], true);
      expect(cells[5].length <= 4 || cells[5][4] != true, isTrue,
          reason: 'row 6 now belongs to someone else');
    });

    test('an ambiguous or vanished row is refused, nothing is written', () async {
      final load = await loaded();
      final meena = load.rows.firstWhere((r) => r.name == 'Meena');
      final ravi = load.rows.firstWhere((r) => r.name == 'Ravi');
      // Meena's row is deleted; Ravi's address now appears twice at other rows.
      g.tab('Sep').cells.removeAt(6);
      g.tab('Sep').cells.add(['Ravi 2', 'ravi@x.com', '1', '']);
      g.tab('Sep').cells[3] = ['Ravi 3', 'ravi@x.com', '1', ''];
      ravi.sourceRow = 99; // position no longer matches either

      final writesBefore = g.writes.length;
      final out = await session.writer
          .write([StatusUpdate(meena, true), StatusUpdate(ravi, true)]);
      expect(out.every((o) => !o.saved), isTrue);
      expect(out.first.error, contains('Reload'));
      expect(g.writes.length, writesBefore, reason: 'no write request at all');
    });

    test('a changed email cell at the same row is refused', () async {
      final load = await loaded();
      final ravi = load.rows.firstWhere((r) => r.name == 'Ravi');
      g.tab('Sep').cells[5][1] = 'someone.else@x.com';
      final out = await session.writer.write([StatusUpdate(ravi, true)]);
      expect(out.single.saved, isFalse);
    });

    test('a failed write is reported per recipient and leaves the sheet alone',
        () async {
      final load = await loaded();
      final ravi = load.rows.firstWhere((r) => r.name == 'Ravi');
      final snap = [for (final r in g.tab('Sep').cells) List<Object?>.of(r)];
      g.failures.addAll([0, 403]); // email-column read ok, write refused
      final out = await session.writer.write([StatusUpdate(ravi, true)]);
      expect(out.single.saved, isFalse);
      expect(out.single.error, contains('Share'));
      expect(g.tab('Sep').cells, snap);
      // Retrying later succeeds.
      final again = await session.writer.write([StatusUpdate(ravi, true)]);
      expect(again.single.saved, isTrue);
    });

    test('partial failure: the first 100 are saved, the next batch fails',
        () async {
      final rows = <List<Object?>>[
        ['name', 'email', 'amount', 'email_sent'],
        for (var i = 0; i < 150; i++) ['P$i', 'p$i@x.com', '1', ''],
      ];
      final big = FakeGoogle(tabs: [FakeTab(1, 'Sep', rows)]);
      final s = SheetsSession(
          api: big.api(),
          spreadsheetId: id,
          spreadsheetName: 'x',
          worksheetId: 1,
          worksheetTitle: 'Sep',
          statusHeader: 'email_sent');
      await s.prepareForSending();
      final load = await s.load();
      var posts = 0;
      big.onCall = (c) {
        if (c.path.endsWith('values:batchUpdate') && ++posts == 2) {
          big.failures.add(400); // the second chunk is rejected
        }
      };
      final out = await s.writer
          .write([for (final r in load.rows) StatusUpdate(r, true)]);
      expect(out.where((o) => o.saved), hasLength(100));
      expect(out.where((o) => !o.saved), hasLength(50));
      expect(rows[1][3], true);
      expect(rows[101][3], '');
    });
  });

  group('SheetStatusSync', () {
    late FakeGoogle g;
    late SheetsSession session;
    late List<ReceiptData> people;

    setUp(() async {
      g = FakeGoogle(tabs: [
        FakeTab(1, 'Sep', [
          ['name', 'email', 'amount'],
          for (var i = 0; i < 25; i++) ['P$i', 'p$i@x.com', '1'],
        ]),
      ]);
      session = SheetsSession(
          api: g.api(),
          spreadsheetId: id,
          spreadsheetName: 'x',
          worksheetId: 1,
          worksheetTitle: 'Sep',
          statusHeader: 'email_sent');
      await session.prepareForSending();
      people = (await session.load()).rows;
    });

    test('25 statuses are saved with 3 write requests, not 25', () async {
      final outcomes = <StatusOutcome>[];
      final sync = SheetStatusSync(session.writer,
          onOutcome: outcomes.add, maxDelay: const Duration(hours: 1));
      final writesBefore = g.writes.length;
      for (var i = 0; i < 25; i++) {
        sync.enqueue(people[i], i.isEven);
      }
      await sync.flush();
      expect(outcomes, hasLength(25));
      expect(outcomes.every((o) => o.saved), isTrue);
      expect(g.writes.length - writesBefore, 3); // 10 + 10 + 5
      final col = session.writer.statusColumn!;
      for (var i = 0; i < 25; i++) {
        expect(g.tab('Sep').cells[i + 1][col], i.isEven);
      }
    });

    test('statuses are also written by themselves after maxDelay', () async {
      final outcomes = <StatusOutcome>[];
      final sync = SheetStatusSync(session.writer,
          onOutcome: outcomes.add, maxDelay: const Duration(milliseconds: 20));
      sync.enqueue(people[0], true);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      await sync.flush();
      expect(outcomes.single.saved, isTrue);
    });

    test('the owed value stays on the row until it is really saved', () async {
      final outcomes = <StatusOutcome>[];
      final sync = SheetStatusSync(session.writer,
          onOutcome: outcomes.add, maxDelay: const Duration(hours: 1));
      g.failures.addAll([0, 503, 503, 503, 503, 503]);
      sync.enqueue(people[0], true);
      expect(people[0].sheetPending, isTrue, reason: 'queued, not saved yet');
      await sync.flush();
      expect(outcomes.single.saved, isFalse);
      expect(people[0].sheetPending, isTrue);
    });
  });

  group('before sending', () {
    FakeGoogle sheet() => FakeGoogle(tabs: [
          FakeTab(1, 'Sep', [
            ['name', 'email', 'amount'],
            ['Asha', 'asha@x.com', '100'],
          ]),
        ]);

    SheetsSession sessionOf(FakeGoogle g, {int tab = 1, String title = 'Sep'}) =>
        SheetsSession(
            api: g.api(),
            spreadsheetId: id,
            spreadsheetName: 'x',
            worksheetId: tab,
            worksheetTitle: title,
            statusHeader: 'email_sent');

    test('validates access and creates the status column', () async {
      final g = sheet();
      await sessionOf(g).prepareForSending();
      expect(g.tab('Sep').cells.first.last, 'email_sent');
    });

    test('viewer-only access stops the run before anything is written', () async {
      final g = sheet()..canEdit = false;
      await expectLater(
          sessionOf(g).prepareForSending(),
          throwsA(isA<SheetsApiException>()
              .having((e) => e.message, 'message', contains('Viewer'))));
      expect(g.writes, isEmpty);
    });

    test('a deleted tab stops the run', () async {
      final g = sheet();
      await expectLater(sessionOf(g, tab: 99).prepareForSending(),
          throwsA(isA<SheetsApiException>()));
    });

    test('a renamed tab is followed by its id', () async {
      final g = sheet();
      final s = sessionOf(g);
      g.tab('Sep').title = 'September';
      await s.prepareForSending();
      expect(s.worksheetTitle, 'September');
      expect(g.tab('September').cells.first.last, 'email_sent');
    });

    test('an unreachable spreadsheet stops the run with guidance', () async {
      final g = sheet()..failures.add(404);
      await expectLater(sessionOf(g).prepareForSending(),
          throwsA(isA<SheetsApiException>()));
    });

    test('a sheet without an email column cannot be sent from', () async {
      final g = FakeGoogle(tabs: [
        FakeTab(1, 'Sep', [
          ['name', 'amount'],
          ['Asha', '100']
        ])
      ]);
      await expectLater(sessionOf(g).prepareForSending(),
          throwsA(isA<SheetsApiException>()));
      expect(g.writes, isEmpty);
    });
  });
}
