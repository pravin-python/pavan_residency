import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pavan_residency/services/sheets/sheets_api.dart';

/// A cell holding a formula: reads show [value], writes elsewhere must never
/// change it.
class Formula {
  const Formula(this.formula, this.value);
  final String formula;
  final String value;
}

class FakeTab {
  FakeTab(this.sheetId, this.title, this.cells, {int? columns})
      : columnCount = columns ?? 26;

  final int sheetId;
  String title;
  final List<List<Object?>> cells; // row i = sheet row i + 1
  int columnCount;
  int get rowCount => cells.length < 1000 ? 1000 : cells.length;
}

/// One request the app made.
class Call {
  Call(this.method, this.url, this.body);
  final String method;
  final Uri url;
  final Object? body;
  String get path => url.path;
}

/// An in-memory stand-in for the Google Sheets v4 + Drive v3 REST APIs that
/// behaves like the real ones where it matters here:
///  * values.get trims trailing blank cells / rows;
///  * writing beyond the grid's column count is a 400 (the app must add
///    columns first);
///  * failures can be injected per request.
class FakeGoogle {
  FakeGoogle({
    this.spreadsheetId = 'SPREADSHEET_ID_1234567890',
    this.name = 'Maintenance 2026',
    required this.tabs,
  });

  final String spreadsheetId;
  String name;
  final List<FakeTab> tabs;
  bool canEdit = true;
  bool driveEnabled = true;

  /// Other spreadsheets the identity can see (id -> name).
  final Map<String, String> otherSpreadsheets = {};
  int drivePageSize = 100;

  final calls = <Call>[];

  /// Status codes to answer the next requests with, in order (0 = behave
  /// normally). e.g. [429, 503, 0].
  final failures = <int>[];

  /// Called for every request before it is answered; throw to simulate a
  /// network failure.
  void Function(Call call)? onCall;

  Iterable<Call> get writes => calls.where((c) => c.method == 'POST');

  late final MockClient client = MockClient(_handle);
  SheetsApi api({int maxAttempts = 5}) => SheetsApi(
        client,
        serviceAccountEmail: 'mailer@proj.iam.gserviceaccount.com',
        delay: (_) async {},
        maxAttempts: maxAttempts,
      );

  FakeTab tab(String title) => tabs.firstWhere((t) => t.title == title);

  Future<http.Response> _handle(http.Request req) async {
    final body = req.body.isEmpty ? null : jsonDecode(req.body);
    final call = Call(req.method, req.url, body);
    calls.add(call);
    onCall?.call(call);

    if (failures.isNotEmpty) {
      final f = failures.removeAt(0);
      if (f != 0) {
        return _json(f, {
          'error': {'code': f, 'message': 'injected $f', 'status': 'ERR'}
        }, headers: f == 429 ? {'retry-after': '1'} : const {});
      }
    }

    final seg = req.url.pathSegments;
    if (req.url.host == 'www.googleapis.com') return _drive(req, seg);
    return _sheets(req, seg, body);
  }

  http.Response _json(int status, Object body,
          {Map<String, String> headers = const {}}) =>
      http.Response(jsonEncode(body), status, headers: {
        'content-type': 'application/json',
        ...headers,
      });

  http.Response _err(int status, String message, {String? reason}) =>
      _json(status, {
        'error': {
          'code': status,
          'message': message,
          if (reason != null)
            'errors': [
              {'reason': reason}
            ],
        }
      });

  http.Response _drive(http.Request req, List<String> seg) {
    if (!driveEnabled) {
      return _err(403,
          'Google Drive API has not been used in project 123 before or it is disabled.',
          reason: 'accessNotConfigured');
    }
    // /drive/v3/files[/id]
    if (seg.length == 3) {
      final all = <Map<String, String>>[
        {'id': spreadsheetId, 'name': name},
        for (final e in otherSpreadsheets.entries)
          {'id': e.key, 'name': e.value},
      ];
      final start = int.tryParse(req.url.queryParameters['pageToken'] ?? '') ?? 0;
      final end = (start + drivePageSize).clamp(0, all.length);
      return _json(200, {
        'files': all.sublist(start, end),
        if (end < all.length) 'nextPageToken': '$end',
      });
    }
    if (seg[3] != spreadsheetId) return _err(404, 'File not found');
    return _json(200, {
      'capabilities': {'canEdit': canEdit}
    });
  }

  http.Response _sheets(http.Request req, List<String> seg, Object? body) {
    // /v4/spreadsheets/{id}[:batchUpdate | /values/{range} | /values:batchUpdate]
    final first = seg[2];
    final id = first.split(':').first;
    if (id != spreadsheetId) {
      return _err(404, 'Requested entity was not found.');
    }

    if (req.method == 'GET' && seg.length == 3) {
      return _json(200, {
        'spreadsheetId': spreadsheetId,
        'properties': {'title': name},
        'sheets': [
          for (var i = 0; i < tabs.length; i++)
            {
              'properties': {
                'sheetId': tabs[i].sheetId,
                'title': tabs[i].title,
                'index': i,
                'sheetType': 'GRID',
                'gridProperties': {
                  'rowCount': tabs[i].rowCount,
                  'columnCount': tabs[i].columnCount,
                },
              }
            }
        ],
      });
    }

    if (req.method == 'GET' && seg.length == 5 && seg[3] == 'values') {
      return _readValues(Uri.decodeComponent(seg[4]));
    }

    if (req.method == 'POST' && seg.length == 4 && seg[3] == 'values:batchUpdate') {
      return _writeValues(body as Map<String, dynamic>);
    }

    if (req.method == 'POST' && first.endsWith(':batchUpdate')) {
      for (final r in (body as Map)['requests'] as List) {
        final a = (r as Map)['appendDimension'] as Map;
        final t = tabs.firstWhere((t) => t.sheetId == a['sheetId']);
        if (a['dimension'] != 'COLUMNS') {
          return _err(400, 'only COLUMNS supported by the fake');
        }
        t.columnCount += (a['length'] as int);
      }
      return _json(200, {'spreadsheetId': spreadsheetId, 'replies': [{}]});
    }

    return _err(400, 'unsupported request ${req.method} ${req.url.path}');
  }

  // 'Tab' | 'Tab'!E:E | 'Tab'!C5
  ({FakeTab tab, String? a1})? _parseRange(String range) {
    final m = RegExp(r"^'((?:[^']|'')+)'(?:!(.+))?$").firstMatch(range);
    if (m == null) return null;
    final title = m.group(1)!.replaceAll("''", "'");
    final t = tabs.where((t) => t.title == title);
    if (t.isEmpty) return null;
    return (tab: t.first, a1: m.group(2));
  }

  static int _colIndex(String letters) {
    var n = 0;
    for (final c in letters.codeUnits) {
      n = n * 26 + (c - 64);
    }
    return n - 1;
  }

  String _text(Object? v) => switch (v) {
        null => '',
        bool b => b ? 'TRUE' : 'FALSE',
        Formula f => f.value,
        _ => '$v',
      };

  http.Response _readValues(String range) {
    final p = _parseRange(range);
    if (p == null) return _err(400, 'Unable to parse range: $range');
    final rows = p.tab.cells;
    int? only;
    if (p.a1 != null) {
      final m = RegExp(r'^([A-Z]+):([A-Z]+)$').firstMatch(p.a1!);
      if (m == null) return _err(400, 'fake supports only whole columns');
      only = _colIndex(m.group(1)!);
    }
    final out = <List<String>>[];
    for (final r in rows) {
      final texts = [for (final c in r) _text(c)];
      if (only != null) {
        out.add(only < texts.length && texts[only].isNotEmpty ? [texts[only]] : []);
      } else {
        while (texts.isNotEmpty && texts.last.isEmpty) {
          texts.removeLast();
        }
        out.add(texts);
      }
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    return _json(200, {'range': range, 'majorDimension': 'ROWS', 'values': out});
  }

  http.Response _writeValues(Map<String, dynamic> body) {
    // Validate everything first: a real batchUpdate is all-or-nothing.
    final writes = <(FakeTab, int, int, Object?)>[];
    for (final d in body['data'] as List) {
      final range = (d as Map)['range'] as String;
      final p = _parseRange(range);
      final m = p?.a1 == null
          ? null
          : RegExp(r'^([A-Z]+)(\d+)$').firstMatch(p!.a1!);
      if (p == null || m == null) {
        return _err(400, 'Unable to parse range: $range');
      }
      final col = _colIndex(m.group(1)!);
      final row = int.parse(m.group(2)!);
      if (col >= p.tab.columnCount) {
        return _err(400,
            'Range ($range) exceeds grid limits. Max columns: ${p.tab.columnCount}');
      }
      final v = ((d['values'] as List).first as List).first;
      writes.add((p.tab, row, col, v));
    }
    for (final (tab, row, col, v) in writes) {
      while (tab.cells.length < row) {
        tab.cells.add([]);
      }
      final r = tab.cells[row - 1];
      while (r.length <= col) {
        r.add(null);
      }
      r[col] = v;
    }
    return _json(200, {'totalUpdatedCells': writes.length});
  }
}
