import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/receipt_data.dart';

/// Remembers which receipts were already emailed (on this phone), so loading
/// the same CSV again after an interrupted bulk run doesn't mail everyone a
/// second time.
class SentLog {
  static const _key = 'pavan_sent_log_v1';
  static const _max = 5000; // oldest entries are dropped beyond this

  static Map<String, int>? _cache; // receipt key -> receipt no. (in order)

  /// Same payer + same payment details = same receipt.
  static String keyOf(ReceiptData d) => [
        d.emails.join(',').toLowerCase(),
        d.name.trim().toLowerCase(),
        d.amount.round(),
        d.date,
        d.type.name,
        d.remark.trim().toLowerCase(),
        d.mode.name,
        d.chqNo.trim(),
        d.txnNo.trim(),
      ].join('|');

  static Future<Map<String, int>> _load() async {
    if (_cache != null) return _cache!;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    _cache = <String, int>{};
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>)
            .forEach((k, v) => _cache![k] = (v as num).toInt());
      } catch (_) {
        // Corrupt log: start fresh rather than block sending.
      }
    }
    return _cache!;
  }

  /// Receipt no. this receipt was already sent with, or null.
  static Future<int?> sentNo(ReceiptData d) async => (await _load())[keyOf(d)];

  static Future<void> add(ReceiptData d) async {
    final log = await _load();
    final k = keyOf(d);
    log.remove(k); // re-insert at the end (newest)
    log[k] = d.recNo;
    while (log.length > _max) {
      log.remove(log.keys.first);
    }
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(log));
  }
}
