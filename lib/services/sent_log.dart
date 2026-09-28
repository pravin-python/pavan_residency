import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/receipt_data.dart';

/// Remembers which receipts were already emailed (on this phone), so loading
/// the same CSV again after an interrupted bulk run doesn't mail everyone a
/// second time.
class SentLog {
  static const _key = 'pavan_sent_log_v2';
  static const _max = 5000; // oldest entries are dropped beyond this

  /// A CSV row without a date gets "today" — so for those the date can't
  /// tell this month's receipt from next month's. They only count as
  /// "already sent" within this window (an interrupted run resumed later).
  static const blankDateWindow = Duration(days: 7);

  /// receipt key -> {n: receipt no., t: sent at (ms since epoch)}, oldest
  /// first.
  static Map<String, Map<String, dynamic>>? _cache;

  /// Same flat + payer + payment details = same receipt.
  static String keyOf(ReceiptData d) => [
        d.block.trim().toUpperCase(),
        d.house.trim().toLowerCase(),
        d.emails.join(',').toLowerCase(),
        d.name.trim().toLowerCase(),
        d.amount.round(),
        d.dateDefaulted ? '' : d.date,
        d.type.name,
        d.remark.trim().toLowerCase(),
        d.mode.name,
        d.chqNo.trim(),
        d.txnNo.trim(),
      ].join('|');

  static Future<Map<String, Map<String, dynamic>>> _load() async {
    if (_cache != null) return _cache!;
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    final log = <String, Map<String, dynamic>>{};
    if (raw != null) {
      try {
        (jsonDecode(raw) as Map<String, dynamic>).forEach((k, v) {
          if (v is Map<String, dynamic>) log[k] = v;
        });
      } catch (_) {
        // Corrupt log: start fresh rather than block sending.
      }
    }
    return _cache ??= log;
  }

  /// Receipt no. this receipt was already sent with, or null.
  static Future<int?> sentNo(ReceiptData d, {DateTime? now}) async {
    final e = (await _load())[keyOf(d)];
    if (e == null) return null;
    if (d.dateDefaulted) {
      final at = DateTime.fromMillisecondsSinceEpoch((e['t'] as num).toInt());
      if ((now ?? DateTime.now()).difference(at) > blankDateWindow) {
        return null;
      }
    }
    return (e['n'] as num).toInt();
  }

  static Future<void> add(ReceiptData d, {DateTime? now}) async {
    final log = await _load();
    final k = keyOf(d);
    log.remove(k); // re-insert at the end (newest)
    log[k] = {
      'n': d.recNo,
      't': (now ?? DateTime.now()).millisecondsSinceEpoch,
    };
    while (log.length > _max) {
      log.remove(log.keys.first);
    }
    await (await SharedPreferences.getInstance())
        .setString(_key, jsonEncode(log));
  }
}
