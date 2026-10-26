import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'amount_words.dart';

/// All app settings, persisted on the device (SharedPreferences).
class AppSettings {
  // SMTP
  String host;
  int port;
  bool ssl; // true = SSL (465), false = STARTTLS (587)
  String username;
  String password;
  String senderName;
  String senderEmail;

  // Email / receipt
  String subjectTpl; // {no} {name} {amount}
  bool attachPdf;
  int nextReceiptNo;

  /// The user confirmed [nextReceiptNo] at least once on this install.
  bool counterConfirmed;

  /// Receipt numbers that were taken for a send that then certainly failed,
  /// but could not be given back because a later number was already taken
  /// (parallel sends). They are issued again first, so the sequence has no
  /// gaps also after the CSV is loaded again or the app restarts.
  List<int> spareNos;

  // Signature image (base64) - jpg/jpeg/png
  String signatureB64;
  String signatureMime;

  AppSettings({
    this.host = '',
    this.port = 465,
    this.ssl = true,
    this.username = '',
    this.password = '',
    this.senderName = 'Pavan Residency',
    this.senderEmail = '',
    this.subjectTpl = 'Pavan Residency Receipt #{no}',
    this.attachPdf = true,
    this.nextReceiptNo = 794,
    this.counterConfirmed = false,
    List<int>? spareNos,
    this.signatureB64 = '',
    this.signatureMime = 'image/png',
  }) : spareNos = spareNos ?? [];

  bool get isConfigured =>
      host.isNotEmpty && username.isNotEmpty && password.isNotEmpty;

  Uint8List? get signatureBytes =>
      signatureB64.isEmpty ? null : base64Decode(signatureB64);

  String buildSubject(int no, String name, num amount) => subjectTpl
      .replaceAll('{no}', '$no')
      .replaceAll('{name}', name)
      .replaceAll('{amount}', formatIndian(amount));

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'ssl': ssl,
        'username': username,
        'password': password,
        'senderName': senderName,
        'senderEmail': senderEmail,
        'subjectTpl': subjectTpl,
        'attachPdf': attachPdf,
        'nextReceiptNo': nextReceiptNo,
        'counterConfirmed': counterConfirmed,
        'spareNos': spareNos,
        'signatureB64': signatureB64,
        'signatureMime': signatureMime,
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        host: j['host'] ?? '',
        port: j['port'] ?? 465,
        ssl: j['ssl'] ?? true,
        username: j['username'] ?? '',
        password: j['password'] ?? '',
        senderName: j['senderName'] ?? 'Pavan Residency',
        senderEmail: j['senderEmail'] ?? '',
        subjectTpl: j['subjectTpl'] ?? 'Pavan Residency Receipt #{no}',
        attachPdf: j['attachPdf'] ?? true,
        nextReceiptNo: j['nextReceiptNo'] ?? 794,
        counterConfirmed: j['counterConfirmed'] ?? false,
        spareNos: [
          for (final n in (j['spareNos'] as List<dynamic>? ?? const []))
            if (n is num) n.toInt(),
        ],
        signatureB64: j['signatureB64'] ?? '',
        signatureMime: j['signatureMime'] ?? 'image/png',
      );
}

class SettingsService {
  static const _key = 'pavan_settings_v1';
  static AppSettings? _cache;
  static Future<AppSettings>? _loading;

  /// Bumped after every save, so open screens can refresh what they show
  /// (e.g. the next receipt no. after a send from another tab).
  static final changes = ValueNotifier<int>(0);

  /// Receipt numbers that are about to be used explicitly (a typed number in
  /// Single, receipt_no values of a running Bulk batch): auto numbers skip
  /// them, so an auto row can never get a number that is also typed.
  static final _reserved = <int>{};

  static void reserve(Iterable<int> nos) => _reserved.addAll(nos);
  static void unreserve(Iterable<int> nos) => _reserved.removeAll(nos);

  /// Every caller gets the SAME [AppSettings] instance the screens keep a
  /// reference to it, and a second copy would save a stale receipt counter
  /// over the live one.
  static Future<AppSettings> load() {
    if (_cache != null) return Future.value(_cache!);
    return _loading ??= _doLoad().whenComplete(() => _loading = null);
  }

  static Future<AppSettings> _doLoad() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    AppSettings loaded;
    try {
      loaded = raw == null
          ? AppSettings()
          : AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      loaded = AppSettings(); // corrupt JSON: start with defaults
    }
    return _cache ??= loaded;
  }

  static Future<void> save(AppSettings s) async {
    _cache = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(s.toJson()));
    changes.value++;
  }

  /// The number the next [takeReceiptNo] will return (for display).
  static int peekReceiptNo(AppSettings s) {
    final spare = _smallestSpare(s);
    if (spare != null) return spare;
    var n = s.nextReceiptNo;
    while (_reserved.contains(n)) {
      n++;
    }
    return n;
  }

  static int? _smallestSpare(AppSettings s) {
    int? best;
    for (final n in s.spareNos) {
      if (_reserved.contains(n)) continue;
      if (best == null || n < best) best = n;
    }
    return best;
  }

  /// Reserves the next receipt no. so a Single send and a running Bulk send
  /// (several parallel connections) can never get the same number. A spare
  /// number (see [AppSettings.spareNos]) is used first; otherwise the
  /// counter moves +1 immediately, skipping numbers [reserve]d for explicit
  /// use.
  static Future<int> takeReceiptNo() async {
    final s = await load();
    // read + change with no await in between
    final spare = _smallestSpare(s);
    final int n;
    if (spare != null) {
      s.spareNos.remove(spare);
      n = spare;
    } else {
      var next = s.nextReceiptNo;
      while (_reserved.contains(next)) {
        next++;
      }
      s.nextReceiptNo = next + 1;
      n = next;
    }
    await save(s);
    return n;
  }

  /// Gives back a number from [takeReceiptNo] whose send certainly failed.
  /// If it is the last one issued the counter goes back; otherwise (a later
  /// number was already taken) it is kept as a spare and issued next. Either
  /// way the sequence ends up with no gaps and no duplicates.
  static Future<void> releaseReceiptNo(int n) async {
    final s = await load();
    if (n >= s.nextReceiptNo || s.spareNos.contains(n)) return;
    if (s.nextReceiptNo == n + 1) {
      s.nextReceiptNo = n;
      // Spares right below the counter become the counter again.
      while (s.spareNos.remove(s.nextReceiptNo - 1)) {
        s.nextReceiptNo--;
      }
    } else {
      s.spareNos.add(n);
    }
    await save(s);
  }

  /// Marks [used] as issued: the counter moves past it (and it is no longer
  /// a spare).
  static Future<void> bumpReceiptNo(int used) async {
    final s = await load();
    final wasSpare = s.spareNos.remove(used);
    if (used >= s.nextReceiptNo) {
      s.nextReceiptNo = used + 1;
    } else if (!wasSpare) {
      return;
    }
    await save(s);
  }
}
