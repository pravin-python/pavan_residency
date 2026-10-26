// End-to-end test of Bulk parallel sending: the real BulkScreen UI, the real
// mailer package and real sockets, against a small fake SMTP server on
// 127.0.0.1. Checks that every ready row is mailed exactly once, receipt
// numbers are never duplicated or skipped, and a wrong login stops the run
// after a single attempt.
//
// `flutter test --dart-define=E2E_LOG=true test/bulk_parallel_e2e_test.dart`
// prints what every run did.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/main.dart';
import 'package:pavan_residency/screens/bulk_screen.dart';
import 'package:pavan_residency/services/email_service.dart';
import 'package:pavan_residency/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ---------------------------------------------------------------------------
// Fake SMTP server
// ---------------------------------------------------------------------------

/// One mail the fake server accepted.
class ReceivedMail {
  ReceivedMail(this.connection, this.from, this.rcpts, this.raw);

  /// 1-based number of the connection it arrived on.
  final int connection;
  final String from;
  final List<String> rcpts;
  final String raw;

  String header(String name) {
    final end = raw.indexOf('\r\n\r\n');
    final head = (end < 0 ? raw : raw.substring(0, end))
        .replaceAll(RegExp(r'\r\n[ \t]+'), ' '); // unfold
    for (final line in head.split('\r\n')) {
      final c = line.indexOf(':');
      if (c > 0 && line.substring(0, c).trim().toLowerCase() == name) {
        return _decodeWords(line.substring(c + 1).trim());
      }
    }
    return '';
  }

  String get subject => header('subject');

  /// From the default subject 'Pavan Residency Receipt #{no}'.
  int get receiptNo {
    final m = RegExp(r'Receipt #(\d+)').firstMatch(subject);
    if (m == null) throw StateError('no receipt no. in subject "$subject"');
    return int.parse(m[1]!);
  }

  /// RFC 2047 encoded words (=?utf-8?B?...?= / Q).
  static String _decodeWords(String v) => v
          .replaceAll(RegExp(r'\?=\s+=\?'), '?==?')
          .replaceAllMapped(RegExp(r'=\?([^?]+)\?([bBqQ])\?([^?]*)\?='), (m) {
        final text = m[3]!;
        final List<int> bytes;
        if (m[2]!.toUpperCase() == 'B') {
          bytes = base64.decode(text);
        } else {
          final out = <int>[];
          for (var i = 0; i < text.length; i++) {
            if (text[i] == '_') {
              out.add(0x20);
            } else if (text[i] == '=' && i + 2 < text.length) {
              out.add(int.parse(text.substring(i + 1, i + 3), radix: 16));
              i += 2;
            } else {
              out.add(text.codeUnitAt(i));
            }
          }
          bytes = out;
        }
        return utf8.decode(bytes, allowMalformed: true);
      });
}

/// Just enough ESMTP for the mailer package: greeting, EHLO (AUTH PLAIN
/// LOGIN, no STARTTLS), AUTH, MAIL / RCPT / DATA, RSET, NOOP, QUIT. As
/// strict as Postfix / Gmail about a new MAIL inside an open transaction.
class FakeSmtpServer {
  FakeSmtpServer._(this._server);

  final ServerSocket _server;
  final _clients = <Socket>{};

  int get port => _server.port;

  // Behaviour switches (may be changed between runs).
  bool rejectAuth = false;
  final rejectRcpt = <String>{};

  /// From this many accepted mails on, the final 250 waits for
  /// [releaseHeld]: those mails stay in flight (numbers taken, not yet
  /// confirmed) while other rows fail.
  int holdFrom = -1; // off
  int held = 0;
  final _gate = Completer<void>();
  void releaseHeld() {
    if (!_gate.isCompleted) _gate.complete();
  }

  /// Delay before the final 250 after the data.
  Duration dataReplyDelay = Duration.zero;

  /// More connections at once than this get "421 too many connections".
  int? maxConcurrent;

  /// After this many mails on one connection the next MAIL gets 421 and the
  /// connection is closed (per-connection limits of some providers).
  int? maxMailsPerConnection;

  /// MAIL FROM without an @domain gets 553, like real servers.
  bool rejectBadSender = false;

  // What happened.
  int connections = 0;
  int active = 0;
  int maxActive = 0;
  int authAttempts = 0;
  final credentials = <String>[]; // 'user:password' per AUTH
  final messages = <ReceivedMail>[];
  final refusedRcpts = <String>[];

  /// 'open #n' / 'mail #no' in the order they happened.
  final events = <String>[];

  List<int> get receiptNos => [for (final m in messages) m.receiptNo];

  @override
  String toString() => 'connections=$connections maxActive=$maxActive '
      'auth=$authAttempts mails=${messages.length} '
      'nos=${receiptNos..sort()} refused=$refusedRcpts\n  events=$events';

  static Future<FakeSmtpServer> start() async {
    final s = FakeSmtpServer._(
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));
    s._server.listen(s._serve);
    return s;
  }

  Future<void> close() async {
    releaseHeld();
    await _server.close();
    for (final c in _clients.toList()) {
      c.destroy();
    }
  }

  static String _b64(String s) {
    try {
      return utf8.decode(base64.decode(s.trim()), allowMalformed: true);
    } catch (_) {
      return '';
    }
  }

  static String _addr(String arg) =>
      RegExp(r'<([^>]*)>').firstMatch(arg)?.group(1) ?? arg.trim();

  Future<void> _serve(Socket sock) async {
    final id = ++connections;
    active++;
    maxActive = max(maxActive, active);
    events.add('open #$id');
    _clients.add(sock);
    sock.done.then((_) {}, onError: (_) {}); // write errors: client gone

    void reply(String line) {
      try {
        sock.write('$line\r\n');
      } catch (_) {}
    }

    void authResult(String user, String pass) {
      credentials.add('$user:$pass');
      reply(rejectAuth
          ? '535 5.7.8 Username and Password not accepted'
          : '235 2.7.0 Accepted');
    }

    void authPlain(String b64) {
      final parts = _b64(b64).split('\u0000');
      authResult(
          parts.length > 1 ? parts[1] : '', parts.length > 2 ? parts[2] : '');
    }

    try {
      if (maxConcurrent != null && active > maxConcurrent!) {
        reply('421 4.7.0 Too many concurrent SMTP connections');
        await sock.flush();
        return;
      }
      reply('220 fake.smtp.test ESMTP ready');
      var mode = 'cmd';
      var user = '';
      var from = '';
      var rcpts = <String>[];
      var inMail = false; // MAIL accepted, transaction not finished
      var mailsHere = 0;
      final data = <String>[];
      await for (final line
          in utf8.decoder.bind(sock).transform(const LineSplitter())) {
        switch (mode) {
          case 'data':
            if (line == '.') {
              mode = 'cmd';
              final mail = ReceivedMail(id, from, rcpts, data.join('\r\n'));
              data.clear();
              rcpts = [];
              if (dataReplyDelay > Duration.zero) {
                await Future<void>.delayed(dataReplyDelay);
              }
              if (holdFrom >= 0 && messages.length + held >= holdFrom) {
                held++;
                await _gate.future;
                held--;
              }
              messages.add(mail);
              events.add('mail #${mail.receiptNo}');
              inMail = false;
              mailsHere++;
              reply('250 2.0.0 OK queued');
            } else {
              data.add(line.startsWith('..') ? line.substring(1) : line);
            }
            continue;
          case 'login-user':
            user = _b64(line);
            mode = 'login-pass';
            reply('334 UGFzc3dvcmQ6'); // "Password:"
            continue;
          case 'login-pass':
            mode = 'cmd';
            authResult(user, _b64(line));
            continue;
          case 'plain':
            mode = 'cmd';
            authPlain(line);
            continue;
        }
        final sp = line.indexOf(' ');
        final verb = (sp < 0 ? line : line.substring(0, sp)).toUpperCase();
        final arg = sp < 0 ? '' : line.substring(sp + 1);
        switch (verb) {
          case 'EHLO':
            reply('250-fake.smtp.test');
            reply('250-AUTH PLAIN LOGIN');
            reply('250 OK');
          case 'HELO':
            reply('250 fake.smtp.test');
          case 'AUTH':
            authAttempts++;
            final a = arg.split(' ');
            final method = a.first.toUpperCase();
            if (method == 'LOGIN') {
              mode = 'login-user';
              reply('334 VXNlcm5hbWU6'); // "Username:"
            } else if (method == 'PLAIN' && a.length > 1) {
              authPlain(a[1]);
            } else if (method == 'PLAIN') {
              mode = 'plain';
              reply('334 ');
            } else {
              reply('504 5.5.4 Unrecognized authentication type');
            }
          case 'MAIL':
            if (maxMailsPerConnection != null &&
                mailsHere >= maxMailsPerConnection!) {
              reply('421 4.7.0 Too many messages on this connection');
              await sock.flush();
              return;
            }
            if (inMail) {
              reply('503 5.5.1 Error: nested MAIL command');
              continue;
            }
            if (rejectBadSender && !_addr(arg).contains('@')) {
              reply('553 5.1.7 <${_addr(arg)}>: Sender address rejected: '
                  'not a valid address');
              continue;
            }
            inMail = true;
            from = _addr(arg);
            rcpts = [];
            reply('250 2.1.0 OK');
          case 'RCPT':
            final to = _addr(arg);
            if (rejectRcpt.contains(to)) {
              refusedRcpts.add(to);
              reply('550 5.1.1 <$to>: Recipient address rejected: '
                  'User unknown');
            } else {
              rcpts.add(to);
              reply('250 2.1.5 OK');
            }
          case 'DATA':
            mode = 'data';
            reply('354 End data with <CR><LF>.<CR><LF>');
          case 'RSET':
            inMail = false;
            rcpts = [];
            reply('250 2.0.0 OK');
          case 'NOOP':
            reply('250 2.0.0 OK');
          case 'QUIT':
            reply('221 2.0.0 Bye');
            await sock.flush();
            return;
          default:
            reply('502 5.5.2 Command not recognized');
        }
      }
    } catch (_) {
      // The client went away.
    } finally {
      active--;
      _clients.remove(sock);
      sock.destroy();
    }
  }
}

// ---------------------------------------------------------------------------
// App driver
// ---------------------------------------------------------------------------

/// Hands the screen a CSV file instead of opening the system picker.
class _FakeFilePicker extends FilePicker {
  _FakeFilePicker(String csv) : bytes = Uint8List.fromList(utf8.encode(csv));

  final Uint8List bytes;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    expect(withData, isTrue, reason: 'the screen reads the bytes');
    return FilePickerResult(
        [PlatformFile(name: 'bulk.csv', size: bytes.length, bytes: bytes)]);
  }
}

/// One row as the Bulk list shows it.
class _Row {
  _Row(this.title, this.chip, this.notes);

  final String title; // 'Name  •  ₹7000  •  #794' (number once sent)
  final String chip; // 'ready' / 'sending…' / '✓ sent' / '✗ error' ...
  final List<String> notes; // red / green lines under the row

  String get name => title.split('  •  ').first;

  int? get no {
    final m = RegExp(r'#(\d+)$').firstMatch(title);
    return m == null ? null : int.parse(m[1]!);
  }

  @override
  String toString() => '$chip #$no';
}

List<_Row> _rows(WidgetTester tester) {
  final tiles = find.descendant(
      of: find.byType(BulkScreen), matching: find.byType(ListTile));
  return [
    for (final e in tiles.evaluate())
      () {
        final tile = e.widget as ListTile;
        final chip = tester.widget<Chip>(find.descendant(
            of: find.byWidget(tile), matching: find.byType(Chip)));
        return _Row(
          (tile.title as Text).data!,
          (chip.label as Text).data!,
          [
            for (final w in (tile.subtitle as Column).children.skip(1))
              (w as Text).data!,
          ],
        );
      }(),
  ];
}

List<int> _sentNos(WidgetTester tester) => [
      for (final r in _rows(tester))
        if (r.no != null) r.no!
    ]..sort();

Future<int> _counter(WidgetTester tester) async =>
    (await tester.runAsync(SettingsService.load))!.nextReceiptNo;

List<int> _range(int from, int count) =>
    [for (var i = 0; i < count; i++) from + i];

const _log = bool.fromEnvironment('E2E_LOG');

/// Settings pointing at [server] (next receipt no. 794, already confirmed),
/// the app on the Bulk tab and [csv] loaded through the file picker.
Future<void> _openBulk(
    WidgetTester tester, FakeSmtpServer server, String csv) async {
  // Tall window: every row of the list is built (no lazy scrolling).
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
  SharedPreferences.setMockInitialValues(
      {'pavan_settings_v1': jsonEncode(settings.toJson())});
  // SettingsService keeps one AppSettings per isolate: replace the one a
  // previous test left behind.
  await tester.runAsync(() => SettingsService.save(settings));

  FilePicker.platform = _FakeFilePicker(csv);
  await tester.pumpWidget(const PavanApp());
  await tester.pumpAndSettle();
  await tester.tap(find.text('Bulk'));
  await tester.pumpAndSettle();
  // Google Sheets is the default source; these tests exercise the CSV one.
  await tester.tap(find.text('CSV File'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Choose CSV File'));
  await tester.pumpAndSettle();
}

final _finalSnack =
    find.textContaining(RegExp(r'^Bulk send (finished|stopped)'));

/// Taps "Send All Emails" and lets real sockets / timers run until the run's
/// final snack bar shows; returns its text. [during] runs after every frame.
Future<String> _sendAll(WidgetTester tester,
    {FutureOr<void> Function()? during}) async {
  // Drop the previous run's snack bar.
  ScaffoldMessenger.of(tester.element(find.byType(BulkScreen)))
      .clearSnackBars();
  await tester.pumpAndSettle();
  expect(_finalSnack, findsNothing);

  final button = find.widgetWithText(FilledButton, 'Send All Emails');
  expect(button, findsOneWidget);
  // Tapped inside runAsync, so the whole send runs in the real zone: real
  // socket I/O and real timers (mailer timeouts, the gap between mails).
  await tester.runAsync(() => tester.tap(button));
  for (var i = 0; _finalSnack.evaluate().isEmpty; i++) {
    if (i > 3000) fail('the bulk send did not finish within ~90 s');
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    if (during != null) await during();
  }
  expect(find.byType(AlertDialog), findsNothing);
  final snack = tester.widget<Text>(_finalSnack.first).data!;
  if (_log) {
    debugPrint('snack: $snack\n  rows: ${_rows(tester)}\n  '
        'counter: ${await _counter(tester)}');
  }
  return snack;
}

/// Keeps [server] in flight until every parallel connection holds a mail.
Future<void> Function() _releaseWhenAllHeld(
        WidgetTester tester, FakeSmtpServer server) =>
    () async {
      if (server.held == BulkScreen.parallel) {
        await tester.runAsync(() async => server.releaseHeld());
      }
    };

String _csv(List<(String, String, String)> rows) => [
      'name,email,amount,receipt_no,block,house_no,language',
      for (final (i, (name, email, no)) in rows.indexed)
        '$name,$email,${7000 + i},$no,A,${101 + i},'
            '${const ['english', 'gujarati', 'hindi'][i % 3]}',
    ].join('\n');

/// [n] rows 'Tag 01' / tag01@tag.test with a blank receipt_no. Every test
/// uses its own names: the sent log is kept per isolate.
List<(String, String, String)> _people(String tag, int n) => [
      for (var i = 1; i <= n; i++)
        (
          '$tag ${'$i'.padLeft(2, '0')}',
          '${tag.toLowerCase()}${'$i'.padLeft(2, '0')}@'
              '${tag.toLowerCase()}.test',
          ''
        ),
    ];

/// Runs [body] against a fresh fake server and always shuts it down.
Future<void> _withServer(WidgetTester tester,
    Future<void> Function(FakeSmtpServer server) body) async {
  final server = (await tester.runAsync(FakeSmtpServer.start))!;
  try {
    await body(server);
  } finally {
    if (_log) debugPrint('server: $server');
    await tester.runAsync(server.close);
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() => EmailService.allowInsecureForTesting = true);
  tearDownAll(() => EmailService.allowInsecureForTesting = false);

  const timeout = Timeout(Duration(minutes: 3));

  testWidgets(
      '(a) 12 rows, blank receipt_no: all mailed in parallel, 794..805 once '
      'each, one login per connection', (tester) async {
    await _withServer(tester, (server) async {
      final people = _people('Alpha', 12);
      await _openBulk(tester, server, _csv(people));
      expect(find.text('12 rows • 12 ready to send'), findsOneWidget);

      var maxSendingChips = 0;
      final snack = await _sendAll(tester, during: () {
        maxSendingChips =
            max(maxSendingChips, find.text('sending…').evaluate().length);
      });
      expect(snack, 'Bulk send finished: 12 sent, 0 failed.');

      // Server: 12 mails, receipt numbers 794..805 each exactly once.
      expect(server.messages, hasLength(12));
      expect(server.receiptNos..sort(), _range(794, 12));
      // One login per connection, at most BulkScreen.parallel connections,
      // and they really ran side by side.
      expect(server.connections, lessThanOrEqualTo(BulkScreen.parallel));
      expect(server.authAttempts, server.connections);
      expect(server.maxActive, greaterThan(1));
      expect(server.maxActive, lessThanOrEqualTo(BulkScreen.parallel));
      expect(server.messages.map((m) => m.connection).toSet().length,
          greaterThan(1));
      expect(maxSendingChips, greaterThan(1));
      expect(server.credentials.toSet(), {'office@pavan.test:app-password'});
      // The first mail went alone (login check) before the other
      // connections were opened.
      expect(server.events.take(2), ['open #1', 'mail #794']);

      // Each resident got one mail, with their own number in the subject
      // and on the PDF.
      final rows = _rows(tester);
      expect(rows, hasLength(12));
      expect(rows.map((r) => r.chip), everyElement('✓ sent'));
      expect([for (final r in rows) r.no], _range(794, 12),
          reason: 'numbers follow the row order');
      for (final (name, email, _) in people) {
        final row = rows.singleWhere((r) => r.name == name);
        final mail =
            server.messages.singleWhere((m) => m.rcpts.contains(email));
        expect(mail.rcpts, [email]);
        expect(mail.from, 'office@pavan.test');
        expect(mail.receiptNo, row.no);
        expect(mail.raw, contains('Pavan_Receipt_${row.no}.pdf'));
      }
      expect(await _counter(tester), 806);
    });
  }, timeout: timeout);

  testWidgets(
      '(b) login refused: one AUTH attempt, run stops, number given back; '
      'after fixing the login the same rows get 794..', (tester) async {
    await _withServer(tester, (server) async {
      await _openBulk(tester, server, _csv(_people('Bravo', 5)));
      server.rejectAuth = true;

      var snack = await _sendAll(tester);
      expect(snack, startsWith('Bulk send stopped. Login failed'));
      expect(server.authAttempts, 1);
      expect(server.connections, 1);
      expect(server.messages, isEmpty);
      expect(await _counter(tester), 794, reason: 'number given back');

      var rows = _rows(tester);
      expect(rows.first.chip, '✗ error');
      expect(rows.first.notes.single, startsWith('Login failed'));
      expect(rows.first.no, isNull);
      expect(rows.skip(1).map((r) => r.chip), everyElement('ready'));
      expect(rows.skip(1).expand((r) => r.notes), isEmpty);

      // Login fixed: the failed row and the untouched ones all go out.
      server.rejectAuth = false;
      snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 5 sent, 0 failed.');
      rows = _rows(tester);
      expect([for (final r in rows) r.no], _range(794, 5));
      expect(server.receiptNos..sort(), _range(794, 5));
      expect(await _counter(tester), 799);
    });
  }, timeout: timeout);

  testWidgets(
      '(c) blank, blank, receipt_no 795: auto numbers skip the typed one',
      (tester) async {
    await _withServer(tester, (server) async {
      final p = _people('Charlie', 3);
      await _openBulk(
          tester, server, _csv([p[0], p[1], (p[2].$1, p[2].$2, '795')]));
      expect(find.text('3 rows • 3 ready to send'), findsOneWidget);

      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 3 sent, 0 failed.');
      final rows = _rows(tester);
      expect([for (final r in rows) r.no], [794, 796, 795]);
      expect(server.receiptNos..sort(), [794, 795, 796]);
      for (final (name, email, _) in p) {
        expect(
            server.messages
                .singleWhere((m) => m.rcpts.contains(email))
                .receiptNo,
            rows.singleWhere((r) => r.name == name).no);
      }
      expect(await _counter(tester), 797);
    });
  }, timeout: timeout);

  testWidgets(
      '(d) one address refused (550): that row fails, the others go out, '
      'no number is duplicated; the retry fills the sequence', (tester) async {
    await _withServer(tester, (server) async {
      final people = _people('Delta', 6);
      final bad = people[2].$2;
      await _openBulk(tester, server, _csv(people));
      server.rejectRcpt.add(bad);

      var snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 5 sent, 1 failed.');
      expect(server.refusedRcpts, [bad]);
      expect(server.messages.where((m) => m.rcpts.contains(bad)), isEmpty);
      expect(server.authAttempts, server.connections,
          reason: 'a new connection (and login) only after the error');

      final badRow = _rows(tester)[2];
      expect(badRow.chip, '✗ error');
      expect(badRow.notes.single, contains('refused'));
      expect(badRow.notes.single, contains('550 5.1.1'));
      final sent = _sentNos(tester);
      expect(sent, hasLength(5));
      expect(sent.toSet(), hasLength(5), reason: 'no duplicate numbers');
      expect(server.receiptNos..sort(), sent);
      // The failed row either gave its number back or kept it for its
      // retry (a later one was already taken): either way nothing issued
      // lies outside 794 .. counter - 1.
      final counter = await _counter(tester);
      expect(counter, anyOf(799, 800));
      expect(sent.every((n) => n >= 794 && n < counter), isTrue);

      // Address fixed on the server: the retry sends only the failed row.
      server.rejectRcpt.clear();
      snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 1 sent, 0 failed.');
      expect(_rows(tester).map((r) => r.chip), everyElement('✓ sent'));
      expect(_sentNos(tester), _range(794, 6));
      expect(server.receiptNos..sort(), _range(794, 6));
      expect(await _counter(tester), 800);
    });
  }, timeout: timeout);

  testWidgets(
      '(d2) the FIRST address refused: not a settings problem, the run '
      'goes on and the number is given back', (tester) async {
    await _withServer(tester, (server) async {
      final people = _people('Echo', 5);
      await _openBulk(tester, server, _csv(people));
      server.rejectRcpt.add(people.first.$2);

      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 4 sent, 1 failed.');
      final rows = _rows(tester);
      expect(rows.first.chip, '✗ error');
      expect(rows.first.no, isNull);
      expect([for (final r in rows.skip(1)) r.no], _range(794, 4));
      expect(server.receiptNos..sort(), _range(794, 4));
      expect(await _counter(tester), 798);
    });
  }, timeout: timeout);

  testWidgets(
      '(d3) two addresses refused while later numbers are still in flight: '
      'nothing is duplicated, the retry fills the sequence', (tester) async {
    await _withServer(tester, (server) async {
      final people = _people('Golf', 12);
      await _openBulk(tester, server, _csv(people));
      server.rejectRcpt.addAll([people[2].$2, people[3].$2]);
      // Every mail after the first waits on the server, so rows 3 and 4 are
      // refused while 795 and 798 are taken but not yet confirmed.
      server.holdFrom = 1;

      var snack =
          await _sendAll(tester, during: _releaseWhenAllHeld(tester, server));
      expect(snack, 'Bulk send finished: 10 sent, 2 failed.');
      expect([
        for (final r in _rows(tester)) r.chip
      ], [
        for (var i = 0; i < 12; i++) i == 2 || i == 3 ? '✗ error' : '✓ sent'
      ]);
      final sent = _sentNos(tester);
      expect(sent.toSet(), hasLength(10), reason: 'no duplicate numbers');
      expect(server.receiptNos..sort(), sent);

      server.rejectRcpt.clear();
      snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 2 sent, 0 failed.');
      expect(_sentNos(tester), _range(794, 12));
      expect(server.receiptNos..sort(), _range(794, 12));
      expect(await _counter(tester), 806);
    });
  }, timeout: timeout);

  testWidgets(
      '(e) Stop: mails in flight finish, the rest stay ready without a '
      'number; Send All later continues the sequence', (tester) async {
    await _withServer(tester, (server) async {
      await _openBulk(tester, server, _csv(_people('Foxtrot', 12)));
      server.dataReplyDelay = const Duration(milliseconds: 150);

      var stopped = false;
      var snack = await _sendAll(tester, during: () async {
        if (!stopped && server.messages.length >= 3) {
          stopped = true;
          await tester.tap(find.textContaining('Stop  ('));
          await tester.pump();
          expect(find.text('Stopping…'), findsOneWidget);
        }
      });
      final m = RegExp(r'^Bulk send finished: (\d+) sent, 0 failed, '
              r'(\d+) not sent \(stopped\)\.$')
          .firstMatch(snack);
      expect(m, isNotNull, reason: snack);
      final sentCount = int.parse(m![1]!);
      expect(sentCount + int.parse(m[2]!), 12);
      expect(sentCount, lessThan(12));

      final rows = _rows(tester);
      expect(rows.where((r) => r.chip == '✓ sent'), hasLength(sentCount));
      expect(rows.where((r) => r.chip == 'ready'), hasLength(12 - sentCount));
      expect(_sentNos(tester), _range(794, sentCount));
      expect(server.receiptNos..sort(), _range(794, sentCount));
      expect(await _counter(tester), 794 + sentCount,
          reason: 'rows not sent took no number');

      snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: ${12 - sentCount} sent, 0 failed.');
      expect(_sentNos(tester), _range(794, 12));
      expect(server.receiptNos..sort(), _range(794, 12));
      expect(await _counter(tester), 806);
    });
  }, timeout: timeout);

  // -------------------------------------------------------------------------
  // Regressions found while building this test (all fixed in lib).
  // -------------------------------------------------------------------------

  // A PersistentConnection does not run mailer's message validation (send()
  // does), so a bad sender reaches the server for every row: one login per
  // row, no stop, and the raw server reply instead of the Settings hint.
  testWidgets(
      '(K1) invalid sender in Settings: stops at the first row without '
      'logging in', (tester) async {
    await _withServer(tester, (server) async {
      await _openBulk(tester, server, _csv(_people('Kilo', 8)));
      (await tester.runAsync(SettingsService.load))!.senderEmail = 'office';
      server.rejectBadSender = true;

      final snack = await _sendAll(tester);
      expect(snack, startsWith('Bulk send stopped. Invalid sender email'));
      expect(server.authAttempts, 0);
      final rows = _rows(tester);
      expect(rows.first.chip, '✗ error');
      expect(rows.skip(1).map((r) => r.chip), everyElement('ready'));
      expect(await _counter(tester), 794);
    });
  }, timeout: timeout);

  // A refused row often keeps its number (a later one was already taken by
  // another connection). Fixing the address in the sheet and loading it
  // again drops that number for good: 796 / 797 are never issued.
  testWidgets(
      '(K2) refused rows, sheet fixed and loaded again: no receipt number '
      'is lost', (tester) async {
    await _withServer(tester, (server) async {
      final people = _people('Lima', 12);
      await _openBulk(tester, server, _csv(people));
      server.rejectRcpt.addAll([people[2].$2, people[3].$2]);
      server.holdFrom = 1;
      await _sendAll(tester, during: _releaseWhenAllHeld(tester, server));

      server.rejectRcpt.clear();
      await tester.tap(find.text('Choose CSV File'));
      await tester.pumpAndSettle();
      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 2 sent, 0 failed.');
      expect(server.receiptNos..sort(), _range(794, 12));
      expect(await _counter(tester), 806);
    });
  }, timeout: timeout);

  // A server that allows fewer parallel connections answers the extra ones
  // with 421: today that counts as "daily limit reached" and stops the
  // whole run although the first connection works.
  testWidgets(
      '(K3) server allows only 2 connections: the run still sends every '
      'row', (tester) async {
    await _withServer(tester, (server) async {
      await _openBulk(tester, server, _csv(_people('Mike', 8)));
      server.maxConcurrent = 2;

      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 8 sent, 0 failed.');
      expect(server.receiptNos..sort(), _range(794, 8));
      expect(_sentNos(tester), _range(794, 8));
      expect(await _counter(tester), 802);
    });
  }, timeout: timeout);

  // 421 at MAIL on a connection that already sent mails (per-connection
  // limit, idle timeout): the mail was not accepted and a fresh connection
  // would work, but today the whole run stops as "daily limit reached".
  testWidgets(
      '(K4) server allows 2 mails per connection: the run still sends '
      'every row', (tester) async {
    await _withServer(tester, (server) async {
      await _openBulk(tester, server, _csv(_people('November', 8)));
      server.maxMailsPerConnection = 2;

      final snack = await _sendAll(tester);
      expect(snack, 'Bulk send finished: 8 sent, 0 failed.');
      expect(server.receiptNos..sort(), _range(794, 8));
      expect(_sentNos(tester), _range(794, 8));
      expect(await _counter(tester), 802);
    });
  }, timeout: timeout);
}
