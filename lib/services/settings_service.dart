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
    this.signatureB64 = '',
    this.signatureMime = 'image/png',
  });

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

  /// Every caller gets the SAME [AppSettings] instance — the screens keep a
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

  /// Reserves the next receipt no. (counter +1 immediately), so a Single
  /// send and a running Bulk send can never get the same number. Skips
  /// numbers [reserve]d for explicit use.
  static Future<int> takeReceiptNo() async {
    final s = await load();
    // read + bump with no await in between
    var n = s.nextReceiptNo;
    while (_reserved.contains(n)) {
      n++;
    }
    s.nextReceiptNo = n + 1;
    await save(s);
    return n;
  }

  /// Gives back a number from [takeReceiptNo] whose send failed — only if
  /// nothing was taken after it, so the sequence has no gaps / duplicates.
  static Future<void> releaseReceiptNo(int n) async {
    final s = await load();
    if (s.nextReceiptNo == n + 1) {
      s.nextReceiptNo = n;
      await save(s);
    }
  }

  /// Marks [used] as issued: the counter moves past it.
  static Future<void> bumpReceiptNo(int used) async {
    final s = await load();
    if (used >= s.nextReceiptNo) {
      s.nextReceiptNo = used + 1;
      await save(s);
    }
  }
}
