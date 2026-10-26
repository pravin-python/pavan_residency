import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

import '../models/receipt_data.dart';

/// Parses an uploaded CSV into receipt rows.
///
/// Expected columns (order free, extra columns ignored):
/// name, email, block, house_no, amount, language, type,
/// mode (cash / cheque / online), cheque_no, transaction_number, bank_name,
/// remarks (details for type "Other"),
/// receipt_no (optional), date / received_date (optional)
/// Values match case-insensitively (block is stored upper-case).
class CsvService {
  static const _colMap = {
    'name': 'name',
    'email': 'email',
    'emailid': 'email',
    'emailaddress': 'email',
    'mail': 'email',
    'block': 'block',
    'blockno': 'block',
    'houseno': 'house',
    'house': 'house',
    'gharno': 'house',
    'ghar': 'house',
    'flatno': 'house',
    'flat': 'house',
    'shedno': 'house',
    'amount': 'amount',
    'amountrs': 'amount',
    'amountinr': 'amount',
    'rs': 'amount',
    'chequeno': 'chqno',
    'chqno': 'chqno',
    'checkno': 'chqno',
    'checknumber': 'chqno',
    'chequenumber': 'chqno',
    'chequebank': 'chqbank',
    'checkbank': 'chqbank',
    'bank': 'chqbank',
    'bankname': 'chqbank',
    'mode': 'mode',
    'paymentmode': 'mode',
    'paymode': 'mode',
    'transactionnumber': 'txnno',
    'transactionno': 'txnno',
    'transactionid': 'txnno',
    'txnno': 'txnno',
    'txnnumber': 'txnno',
    'txnid': 'txnno',
    'utr': 'txnno',
    'utrno': 'txnno',
    'utrnumber': 'txnno',
    'refno': 'txnno',
    'referenceno': 'txnno',
    'referencenumber': 'txnno',
    'language': 'lang',
    'lang': 'lang',
    'type': 'type',
    'remarks': 'remark',
    'remark': 'remark',
    'otherremarks': 'remark',
    'otherdetails': 'remark',
    'details': 'remark',
    'description': 'remark',
    'particulars': 'remark',
    'note': 'remark',
    'notes': 'remark',
    'receiptno': 'recno',
    'receiptnumber': 'recno',
    'recno': 'recno',
    'receipt': 'recno',
    'date': 'date',
    'receiptdate': 'date',
    'receiveddate': 'recdate',
    'receivedon': 'recdate',
    'paymentdate': 'recdate',
    'paiddate': 'recdate',
    'paidon': 'recdate',
  };

  static String todayStr() => DateFormat('dd-MM-yyyy').format(DateTime.now());

  static const _months = {
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, //
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// dd-MM-yyyy for a date cell, or null if it can't be understood.
  /// Accepts 2026-09-25 (+ time), 25/09/2026, 25.9.26, 9/25/2026
  /// (month-first, see [monthFirst]), 25-Sep-2026, Sep 25, 2026 and Excel
  /// serial numbers (46290).
  static String? tryNormDate(String v, {bool monthFirst = false}) {
    final s = v.trim();
    String? out(int y, int m, int d) {
      if (y < 100) y += 2000;
      if (m < 1 || m > 12 || d < 1 || d > 31 || y < 2000 || y > 2100) {
        return null;
      }
      final dt = DateTime(y, m, d);
      if (dt.month != m) return null; // e.g. 31-02
      return DateFormat('dd-MM-yyyy').format(dt);
    }

    final iso = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T].*)?$')
        .firstMatch(s);
    if (iso != null) {
      return out(int.parse(iso.group(1)!), int.parse(iso.group(2)!),
          int.parse(iso.group(3)!));
    }
    // Indian day-first. Excel on a US-locale PC re-saves dates as 9/25/2026
    // (month first): swap when the second number can't be a month, or when
    // the whole file is month-first.
    final dmy =
        RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})(?:[ T].*)?$')
            .firstMatch(s);
    if (dmy != null) {
      var day = int.parse(dmy.group(1)!), month = int.parse(dmy.group(2)!);
      if (day <= 12 && (month > 12 || (monthFirst && month <= 12))) {
        (day, month) = (month, day);
      }
      return out(int.parse(dmy.group(3)!), month, day);
    }
    // 25-Sep-2026 / 25 September 2026
    final dMonY =
        RegExp(r'^(\d{1,2})[\s\-/.]+([A-Za-z]{3,})[\s\-/.,]+(\d{2,4})$')
            .firstMatch(s);
    if (dMonY != null) {
      final m = _months[dMonY.group(2)!.substring(0, 3).toLowerCase()];
      if (m == null) return null;
      return out(int.parse(dMonY.group(3)!), m, int.parse(dMonY.group(1)!));
    }
    // Sep 25, 2026
    final monDY =
        RegExp(r'^([A-Za-z]{3,})[\s\-/.]+(\d{1,2})[\s\-/.,]+(\d{2,4})$')
            .firstMatch(s);
    if (monDY != null) {
      final m = _months[monDY.group(1)!.substring(0, 3).toLowerCase()];
      if (m == null) return null;
      return out(int.parse(monDY.group(3)!), m, int.parse(monDY.group(2)!));
    }
    // Excel serial day number (days since 1899-12-30).
    final serial = RegExp(r'^(\d{5})(?:\.\d+)?$').firstMatch(s);
    if (serial != null) {
      final dt = DateTime(1899, 12, 30)
          .add(Duration(days: int.parse(serial.group(1)!)));
      return out(dt.year, dt.month, dt.day);
    }
    return null;
  }

  /// Like [tryNormDate]; blank => today, unknown text is kept as-is.
  static String normDate(String v, {bool monthFirst = false}) {
    if (v.trim().isEmpty) return todayStr();
    return tryNormDate(v, monthFirst: monthFirst) ?? v.trim();
  }

  /// "Other" details: the remarks column, else free text typed in the type
  /// column itself (e.g. type = "Parking charges"). Ignored for other types.
  /// Both are kept when present: type 'Parking charges' + remarks 'Sep'
  /// => 'Parking charges – Sep'.
  static String _remark(Map<String, String> m) {
    final type = m['type'] ?? '';
    if (ReceiptData.parseType(type) != PaymentType.other) return '';
    return [ReceiptData.otherText(type), m['remark'] ?? '']
        .where((x) => x.isNotEmpty)
        .join(' – ');
  }

  static final _dmyRe = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4}|\d{2})\b');

  /// True when the file's dates are M/D/YYYY: some date has a second part
  /// > 12 (9/25/2026) and none has a first part > 12 (25/9/2026). Decided
  /// once per file so 9/5/2026 and 9/25/2026 in one sheet agree.
  static bool _isMonthFirst(Iterable<String> dates) {
    var md = false, dm = false;
    for (final d in dates) {
      final x = _dmyRe.firstMatch(d.trim());
      if (x == null) continue;
      final a = int.parse(x.group(1)!), b = int.parse(x.group(2)!);
      if (a > 12) dm = true;
      if (b > 12) md = true;
    }
    return md && !dm;
  }

  /// UTF-8 (with or without BOM) or UTF-16 LE/BE (with a BOM, or detected by
  /// its zero bytes) Excel's "Unicode Text" / "CSV UTF-16" exports.
  static String decode(Uint8List bytes) {
    bool? littleEndian;
    var start = 0;
    if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
      littleEndian = true;
      start = 2;
    } else if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
      littleEndian = false;
      start = 2;
    } else if (bytes.length >= 4) {
      // No BOM: ASCII-heavy UTF-16 has a 0 in every other byte.
      final n = bytes.length < 400 ? bytes.length & ~1 : 400;
      var oddZero = 0, evenZero = 0;
      for (var k = 0; k < n; k++) {
        if (bytes[k] != 0) continue;
        if (k.isOdd) {
          oddZero++;
        } else {
          evenZero++;
        }
      }
      final pairs = n ~/ 2;
      if (oddZero > pairs * 0.3 && evenZero < pairs * 0.05) {
        littleEndian = true;
      } else if (evenZero > pairs * 0.3 && oddZero < pairs * 0.05) {
        littleEndian = false;
      }
    }
    if (littleEndian != null) {
      final units = <int>[];
      for (var k = start; k + 1 < bytes.length; k += 2) {
        units.add(littleEndian
            ? bytes[k] | (bytes[k + 1] << 8)
            : (bytes[k] << 8) | bytes[k + 1]);
      }
      return String.fromCharCodes(units);
    }
    final t = utf8.decode(bytes, allowMalformed: true);
    return t.startsWith('﻿') ? t.substring(1) : t;
  }

  /// Guess from the first line: ',' normally; ';' (Excel in comma-decimal
  /// locales) or TAB ("Unicode Text" export).
  static String _delimiter(String text) {
    final nl = text.indexOf('\n');
    final head = nl < 0 ? text : text.substring(0, nl);
    int n(String c) => c.allMatches(head).length;
    final comma = n(','), semi = n(';'), tab = n('\t');
    if (tab > comma && tab >= semi) return '\t';
    if (semi > comma) return ';';
    return ',';
  }

  static String _norm(dynamic h) =>
      h.toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

  /// Header text reduced the way column names are matched (lower-case
  /// letters only): 'Email_Sent' and 'email sent' are the same column.
  static String normHeader(String h) => _norm(h);

  /// The recipient field a header names ('email', 'amount', ...) or null.
  static String? columnKey(String header) => _colMap[_norm(header)];

  /// How many distinct known columns [row] names (to find the header row).
  static int _known(List<dynamic> row) =>
      row.map((h) => _colMap[_norm(h)]).whereType<String>().toSet().length;

  /// Index of the header row: the first of the first 10 rows that names at
  /// least two known columns, or -1.
  static int findHeaderRow(List<List<dynamic>> rows) {
    final limit = rows.length < 10 ? rows.length : 10;
    for (var i = 0; i < limit; i++) {
      if (_known(rows[i]) >= 2) return i;
    }
    return -1;
  }

  /// Recipients read from an already split table (a Google Sheets
  /// worksheet). [sourceRows] holds, for each receipt, its 0-based index in
  /// the table. Same rules as [parse].
  static ({int headerAt, List<ReceiptData> receipts, List<int> sourceRows})?
      parseTable(List<List<dynamic>> rows) {
    final headerAt = findHeaderRow(rows);
    if (headerAt < 0) return null;
    final built = _build(rows, headerAt);
    return (
      headerAt: headerAt,
      receipts: built.receipts,
      sourceRows: built.sourceRows,
    );
  }

  static List<ReceiptData> parse(Uint8List bytes) {
    var text = decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');

    // Excel's "sep=;" first line names the delimiter.
    String? sep;
    final sepLine =
        RegExp(r'^\s*sep=(.)\s*\n', caseSensitive: false).firstMatch(text);
    if (sepLine != null) {
      sep = sepLine.group(1);
      text = text.substring(sepLine.end);
    }

    // The header is the first row (of the first 10) that names at least two
    // known columns so a title / blank line above it doesn't break import.
    List<List<dynamic>> rows = const [];
    var headerAt = -1;
    final guess = sep ?? _delimiter(text);
    for (final delim in {guess, ',', ';', '\t'}) {
      final r = CsvToListConverter(
        shouldParseNumbers: false,
        eol: '\n',
        fieldDelimiter: delim,
      ).convert(text);
      final at = findHeaderRow(r);
      if (at >= 0) {
        rows = r;
        headerAt = at;
        break;
      }
    }
    if (headerAt < 0) return [];
    return _build(rows, headerAt).receipts;
  }

  /// Turns the rows below the header into receipts (shared by CSV files and
  /// Google Sheets worksheets). [sourceRows] are the table indexes the
  /// receipts came from.
  static ({List<ReceiptData> receipts, List<int> sourceRows}) _build(
      List<List<dynamic>> rows, int headerAt) {
    final header = rows[headerAt].map(_norm).toList();

    final maps = <Map<String, String>>[];
    final mapRows = <int>[]; // table index of each entry of [maps]
    for (var r = headerAt + 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c.toString().trim().isEmpty)) continue;

      final m = <String, String>{};
      for (var c = 0; c < header.length && c < row.length; c++) {
        final key = _colMap[header[c]];
        if (key == null) continue;
        final v = row[c].toString().trim();
        if (key == 'email' && v.isNotEmpty && (m['email'] ?? '').isNotEmpty) {
          m['email'] = '${m['email']}, $v'; // Email 1 + Email 2 columns
        } else if (v.isNotEmpty || !m.containsKey(key)) {
          // Two alias columns (e.g. cheque_bank + bank_name): a blank one
          // must not wipe the filled one.
          m[key] = v;
        }
      }
      // Template rows of the society sheet (only receipt_no / block /
      // house filled, nobody paid yet): nothing to send, don't list them.
      final placeholder =
          [m['name'], m['email'], m['amount']].every((v) => (v ?? '').isEmpty);
      if (!placeholder) {
        maps.add(m);
        mapRows.add(r);
      }
    }

    // `date` wins; otherwise the payment's received_date; else today.
    String rawDate(Map<String, String> m) =>
        (m['date'] ?? '').isNotEmpty ? m['date']! : (m['recdate'] ?? '');
    final monthFirst = _isMonthFirst(maps.map(rawDate));

    final out = <ReceiptData>[];
    for (final m in maps) {
      final problems = <String>[];

      final raw = rawDate(m);
      String date;
      if (raw.isEmpty) {
        date = todayStr();
      } else {
        final nd = tryNormDate(raw, monthFirst: monthFirst);
        if (nd == null) problems.add('date "$raw"');
        date = nd ?? raw;
      }

      final recRaw = (m['recno'] ?? '').trim();
      var recNo = 0;
      if (recRaw.isNotEmpty) {
        final x = RegExp(r'^(\d+)(?:\.0+)?$').firstMatch(recRaw);
        recNo = x == null ? 0 : int.parse(x.group(1)!);
        if (recNo <= 0) problems.add('receipt_no "$recRaw"');
      }

      final d = ReceiptData(
        name: m['name'] ?? '',
        email: m['email'] ?? '',
        block: (m['block'] ?? '').toUpperCase(),
        house: m['house'] ?? '',
        amount: ReceiptData.parseAmount(m['amount'] ?? ''),
        mode: ReceiptData.parseMode(m['mode'] ?? '',
            chqNo: m['chqno'] ?? '',
            txnNo: m['txnno'] ?? '',
            bank: m['chqbank'] ?? ''),
        chqNo: m['chqno'] ?? '',
        chqBank: m['chqbank'] ?? '',
        txnNo: m['txnno'] ?? '',
        lang: ReceiptData.parseLang(m['lang'] ?? ''),
        type: ReceiptData.parseType(m['type'] ?? ''),
        remark: _remark(m),
        recNo: recNo,
        date: date,
      )..dateDefaulted = raw.isEmpty;
      if (d.isValid && problems.isEmpty) {
        d.status = SendStatus.ready;
      } else {
        d.status = SendStatus.invalid;
        d.error = [
          if (!d.isValid) d.invalidReason,
          ...problems,
        ].join(', ');
      }
      out.add(d);
    }
    return (receipts: out, sourceRows: mapRows);
  }
}
