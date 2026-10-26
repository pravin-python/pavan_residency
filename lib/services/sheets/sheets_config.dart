import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../csv_service.dart';

/// The user's Google Sheets choices. Nothing secret lives here (the key is in
/// secure storage), so plain SharedPreferences is fine.
class SheetsConfig {
  SheetsConfig({
    this.spreadsheetId = '',
    this.spreadsheetName = '',
    this.worksheetTitle = '',
    this.worksheetId,
    this.statusHeader = defaultStatusHeader,
  });

  static const defaultStatusHeader = 'email_sent';

  String spreadsheetId;
  String spreadsheetName;
  String worksheetTitle;

  /// The worksheet's gid. Stays the same when the tab is renamed.
  int? worksheetId;
  String statusHeader;

  bool get hasSelection => spreadsheetId.isNotEmpty && worksheetTitle.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'spreadsheetId': spreadsheetId,
        'spreadsheetName': spreadsheetName,
        'worksheetTitle': worksheetTitle,
        'worksheetId': worksheetId,
        'statusHeader': statusHeader,
      };

  factory SheetsConfig.fromJson(Map<String, dynamic> j) => SheetsConfig(
        spreadsheetId: j['spreadsheetId'] is String ? j['spreadsheetId'] : '',
        spreadsheetName:
            j['spreadsheetName'] is String ? j['spreadsheetName'] : '',
        worksheetTitle:
            j['worksheetTitle'] is String ? j['worksheetTitle'] : '',
        worksheetId: j['worksheetId'] is num
            ? (j['worksheetId'] as num).toInt()
            : null,
        statusHeader: validStatusHeader(j['statusHeader']) == null &&
                j['statusHeader'] is String
            ? (j['statusHeader'] as String).trim()
            : defaultStatusHeader,
      );

  /// null when [header] can be used as the status column title, otherwise
  /// why not. A recipient column name ("email", "amount" ...) is refused:
  /// it would be mistaken for data.
  static String? validStatusHeader(Object? header) {
    if (header is! String || header.trim().isEmpty) {
      return 'Enter a column title (for example $defaultStatusHeader).';
    }
    final h = header.trim();
    if (h.length > 50) return 'The column title is too long (max 50).';
    if (RegExp(r'[\x00-\x1f]').hasMatch(h)) {
      return 'The column title has invalid characters.';
    }
    if (CsvService.columnKey(h) != null) {
      return '"$h" is one of the recipient columns. Use a different title '
          '(for example $defaultStatusHeader).';
    }
    return null;
  }
}

class SheetsConfigStore {
  static const _key = 'pavan_sheets_v1';

  static Future<SheetsConfig> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    if (raw == null) return SheetsConfig();
    try {
      return SheetsConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return SheetsConfig(); // corrupt: start with defaults
    }
  }

  static Future<void> save(SheetsConfig c) async =>
      (await SharedPreferences.getInstance())
          .setString(_key, jsonEncode(c.toJson()));
}

/// A spreadsheet link or bare ID pasted by the user.
class SpreadsheetLink {
  const SpreadsheetLink(this.id, this.gid);
  final String id;

  /// The tab named by "#gid=123" in a link, if any.
  final int? gid;

  static final _idRe = RegExp(r'^[A-Za-z0-9_-]{20,}$');

  /// https://docs.google.com/spreadsheets/d/<id>/edit#gid=123 or just <id>.
  /// null when the text is neither.
  static SpreadsheetLink? parse(String input) {
    final s = input.trim();
    if (s.isEmpty) return null;
    final m = RegExp(r'^https?://docs\.google\.com/spreadsheets/(?:u/\d+/)?d/'
            r'([A-Za-z0-9_-]+)')
        .firstMatch(s);
    if (m != null) {
      final g = RegExp(r'[#&?]gid=(\d+)').firstMatch(s);
      return SpreadsheetLink(
          m.group(1)!, g == null ? null : int.parse(g.group(1)!));
    }
    return _idRe.hasMatch(s) ? SpreadsheetLink(s, null) : null;
  }
}
