import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

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
      .replaceAll('{amount}', '$amount');

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
        signatureB64: j['signatureB64'] ?? '',
        signatureMime: j['signatureMime'] ?? 'image/png',
      );
}

class SettingsService {
  static const _key = 'pavan_settings_v1';
  static AppSettings? _cache;

  static Future<AppSettings> load() async {
    if (_cache != null) return _cache!;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    _cache = raw == null
        ? AppSettings()
        : AppSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    return _cache!;
  }

  static Future<void> save(AppSettings s) async {
    _cache = s;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(s.toJson()));
  }

  /// Call after a successful send so receipt numbers keep increasing.
  static Future<void> bumpReceiptNo(int used) async {
    final s = await load();
    if (used >= s.nextReceiptNo) {
      s.nextReceiptNo = used + 1;
      await save(s);
    }
  }
}
