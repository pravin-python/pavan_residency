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
    'date': 'date',
    'receiveddate': 'recdate',
    'receivedon': 'recdate',
  };

  static String todayStr() => DateFormat('dd-MM-yyyy').format(DateTime.now());

  /// [monthFirst]: the file uses M/D/YYYY (see [_isMonthFirst]).
  static String normDate(String v, {bool monthFirst = false}) {
    final s = v.trim();
    if (s.isEmpty) return todayStr();
    String p2(String x) => x.padLeft(2, '0');
    // 2026-09-25 / 2026/9/25 / 2026-09-25 10:30:00 (ISO, as exported by
    // Google Sheets / Excel; a trailing time is dropped)
    final iso = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})(?:[ T].*)?$')
        .firstMatch(s);
    if (iso != null) {
      return '${p2(iso.group(3)!)}-${p2(iso.group(2)!)}-${iso.group(1)}';
    }
    // 25/09/2026 / 25.9.2026 (Indian day-first). Excel on a US-locale PC
    // re-saves dates as 9/25/2026 (month first): swap when the second
    // number can't be a month, or when the whole file is month-first.
    final dmy = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})(?:[ T].*)?$')
        .firstMatch(s);
    if (dmy != null) {
      var day = int.parse(dmy.group(1)!), month = int.parse(dmy.group(2)!);
      if (day <= 12 && (month > 12 || (monthFirst && month <= 12))) {
        (day, month) = (month, day);
      }
      return '${p2('$day')}-${p2('$month')}-${dmy.group(3)}';
    }
    return s;
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

  static final _dmyRe = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.]\d{4}');

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

  /// UTF-8 (with or without BOM) or UTF-16 LE/BE with BOM — Excel's
  /// "Unicode Text" / "CSV UTF-16" exports.
  static String decode(Uint8List bytes) {
    if (bytes.length >= 2) {
      final le = bytes[0] == 0xFF && bytes[1] == 0xFE;
      final be = bytes[0] == 0xFE && bytes[1] == 0xFF;
      if (le || be) {
        final units = <int>[];
        for (var k = 2; k + 1 < bytes.length; k += 2) {
          units.add(le
              ? bytes[k] | (bytes[k + 1] << 8)
              : (bytes[k] << 8) | bytes[k + 1]);
        }
        return String.fromCharCodes(units);
      }
    }
    final t = utf8.decode(bytes, allowMalformed: true);
    return t.startsWith('﻿') ? t.substring(1) : t;
  }

  /// ',' normally; ';' (Excel in comma-decimal locales) or TAB ("Unicode
  /// Text" export) when the header line uses those instead.
  static String _delimiter(String text) {
    final nl = text.indexOf('\n');
    final head = nl < 0 ? text : text.substring(0, nl);
    int n(String c) => c.allMatches(head).length;
    final comma = n(','), semi = n(';'), tab = n('\t');
    if (tab > comma && tab >= semi) return '\t';
    if (semi > comma) return ';';
    return ',';
  }

  static List<ReceiptData> parse(Uint8List bytes) {
    final text = decode(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final rows = CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
      fieldDelimiter: _delimiter(text),
    ).convert(text);

    if (rows.isEmpty) return [];

    final header = rows.first
        .map(
            (h) => h.toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''))
        .toList();

    final maps = <Map<String, String>>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c.toString().trim().isEmpty)) continue;

      final m = <String, String>{};
      for (var c = 0; c < header.length && c < row.length; c++) {
        final key = _colMap[header[c]];
        final v = row[c].toString().trim();
        // Two alias columns (e.g. cheque_bank + bank_name): a blank one
        // must not wipe the filled one.
        if (key != null && (v.isNotEmpty || !m.containsKey(key))) m[key] = v;
      }
      maps.add(m);
    }

    // `date` wins; otherwise the payment's received_date; else today.
    String rawDate(Map<String, String> m) =>
        (m['date'] ?? '').isNotEmpty ? m['date']! : (m['recdate'] ?? '');
    final monthFirst = _isMonthFirst(maps.map(rawDate));

    final out = <ReceiptData>[];
    for (final m in maps) {
      final d = ReceiptData(
        name: m['name'] ?? '',
        email: m['email'] ?? '',
        block: (m['block'] ?? '').toUpperCase(),
        house: m['house'] ?? '',
        amount: ReceiptData.parseAmount(m['amount'] ?? ''),
        mode: ReceiptData.parseMode(m['mode'] ?? '',
            chqNo: m['chqno'] ?? '', txnNo: m['txnno'] ?? ''),
        chqNo: m['chqno'] ?? '',
        chqBank: m['chqbank'] ?? '',
        txnNo: m['txnno'] ?? '',
        lang: ReceiptData.parseLang(m['lang'] ?? ''),
        type: ReceiptData.parseType(m['type'] ?? ''),
        remark: _remark(m),
        recNo: int.tryParse(m['recno'] ?? '') ?? 0,
        date: normDate(rawDate(m), monthFirst: monthFirst),
      );
      d.status = d.isValid ? SendStatus.ready : SendStatus.invalid;
      out.add(d);
    }
    return out;
  }
}
