import 'dart:convert';
import 'dart:typed_data';

import 'package:csv/csv.dart';
import 'package:intl/intl.dart';

import '../models/receipt_data.dart';

/// Parses an uploaded CSV into receipt rows.
///
/// Expected columns (order free, extra columns ignored):
/// name, email, block, house_no, amount, cheque_no, cheque_bank,
/// language, type, receipt_no (optional), date (optional)
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
    'checkno': 'chqno',
    'checknumber': 'chqno',
    'chequenumber': 'chqno',
    'chequebank': 'chqbank',
    'checkbank': 'chqbank',
    'bank': 'chqbank',
    'language': 'lang',
    'lang': 'lang',
    'type': 'type',
    'receiptno': 'recno',
    'date': 'date',
  };

  static String todayStr() => DateFormat('dd-MM-yyyy').format(DateTime.now());

  static String normDate(String v) {
    final s = v.trim();
    if (s.isEmpty) return todayStr();
    final iso = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(s);
    if (iso != null) {
      return '${iso.group(3)}-${iso.group(2)}-${iso.group(1)}';
    }
    return s;
  }

  static List<ReceiptData> parse(Uint8List bytes) {
    final text = utf8.decode(bytes, allowMalformed: true);
    final rows = const CsvToListConverter(
      shouldParseNumbers: false,
      eol: '\n',
    ).convert(text.replaceAll('\r\n', '\n'));

    if (rows.isEmpty) return [];

    final header = rows.first
        .map((h) => h.toString().toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''))
        .toList();

    final out = <ReceiptData>[];
    for (var r = 1; r < rows.length; r++) {
      final row = rows[r];
      if (row.every((c) => c.toString().trim().isEmpty)) continue;

      final m = <String, String>{};
      for (var c = 0; c < header.length && c < row.length; c++) {
        final key = _colMap[header[c]];
        if (key != null) m[key] = row[c].toString().trim();
      }

      final d = ReceiptData(
        name: m['name'] ?? '',
        email: m['email'] ?? '',
        block: m['block'] ?? '',
        house: m['house'] ?? '',
        amount: double.tryParse(m['amount'] ?? '') ?? 0,
        chqNo: m['chqno'] ?? '',
        chqBank: m['chqbank'] ?? '',
        lang: ReceiptData.parseLang(m['lang'] ?? ''),
        type: ReceiptData.parseType(m['type'] ?? ''),
        recNo: int.tryParse(m['recno'] ?? '') ?? 0,
        date: normDate(m['date'] ?? ''),
      );
      d.status = d.isValid ? SendStatus.ready : SendStatus.invalid;
      out.add(d);
    }
    return out;
  }
}
