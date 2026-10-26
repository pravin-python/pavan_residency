import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, HandshakeException, TlsException;

import 'package:googleapis_auth/googleapis_auth.dart'
    show AccessDeniedException, ServerRequestFailedException;
import 'package:http/http.dart' as http;

/// A failed Google API call. [message] is safe to show to the user (it says
/// what to do) and never contains credentials.
class SheetsApiException implements Exception {
  const SheetsApiException(this.message, {this.statusCode, this.reason});

  final String message;
  final int? statusCode;

  /// Google's machine-readable reason ('forbidden', 'SERVICE_DISABLED', ...)
  /// or 'network' / 'auth'.
  final String? reason;

  @override
  String toString() => message;
}

class SpreadsheetRef {
  const SpreadsheetRef(this.id, this.name);
  final String id;
  final String name;
}

class WorksheetInfo {
  const WorksheetInfo({
    required this.sheetId,
    required this.title,
    required this.index,
    required this.rowCount,
    required this.columnCount,
    this.hidden = false,
  });

  final int sheetId; // the "gid"
  final String title;
  final int index;
  final int rowCount;
  final int columnCount;
  final bool hidden;
}

class SpreadsheetMeta {
  const SpreadsheetMeta(this.id, this.title, this.worksheets);
  final String id;
  final String title;
  final List<WorksheetInfo> worksheets;
}

/// A1-notation helpers.
class A1 {
  /// 0 -> A, 25 -> Z, 26 -> AA ...
  static String column(int index) {
    var n = index + 1;
    final b = StringBuffer();
    while (n > 0) {
      final r = (n - 1) % 26;
      b.writeCharCode(65 + r);
      n = (n - 1) ~/ 26;
    }
    return b.toString().split('').reversed.join();
  }

  /// 'My tab' -> "'My tab'" (a quote inside the name is doubled).
  static String sheet(String title) => "'${title.replaceAll("'", "''")}'";

  /// Cell [col] (0-based) of [row] (1-based) on [title].
  static String cell(String title, int col, int row) =>
      '${sheet(title)}!${column(col)}$row';

  /// The whole column [col] (0-based) of [title].
  static String wholeColumn(String title, int col) =>
      '${sheet(title)}!${column(col)}:${column(col)}';
}

/// Talks to the Google Sheets v4 and Drive v3 REST APIs through an
/// authenticated [http.Client].
///
/// Transient failures (network errors, 429, 5xx, per-minute quota) are
/// retried with exponential backoff. A request that is not safe to repeat
/// (adding a column) is only retried when Google says it was rejected for
/// quota (429), never after an unknown outcome.
class SheetsApi {
  SheetsApi(
    this._http, {
    this.serviceAccountEmail = '',
    Future<void> Function(Duration)? delay,
    this.maxAttempts = 5,
    this.requestTimeout = const Duration(seconds: 30),
  }) : _delay = delay ?? ((d) => Future<void>.delayed(d));

  static const _sheetsBase = 'https://sheets.googleapis.com/v4/spreadsheets';
  static const _driveBase = 'https://www.googleapis.com/drive/v3/files';

  final http.Client _http;
  final Future<void> Function(Duration) _delay;
  final int maxAttempts;
  final Duration requestTimeout;

  /// Used in "share the sheet with ..." hints.
  final String serviceAccountEmail;

  /// Releases the underlying HTTP client (and its token refresher).
  void close() => _http.close();

  // ---------------------------------------------------------------- Drive

  /// Spreadsheets the credential's identity can see (Drive API). For a
  /// service account that is only what was shared with it.
  Future<List<SpreadsheetRef>> listSpreadsheets({int max = 1000}) async {
    final out = <SpreadsheetRef>[];
    String? pageToken;
    do {
      final body = await _call(
        'GET',
        Uri.parse(_driveBase).replace(queryParameters: {
          'q': "mimeType='application/vnd.google-apps.spreadsheet' "
              'and trashed=false',
          'fields': 'nextPageToken,files(id,name)',
          'orderBy': 'name',
          'pageSize': '100',
          'supportsAllDrives': 'true',
          'includeItemsFromAllDrives': 'true',
          if (pageToken != null) 'pageToken': pageToken,
        }),
      );
      for (final f in (body['files'] as List<dynamic>? ?? const [])) {
        if (f is Map && f['id'] is String) {
          out.add(SpreadsheetRef(f['id'] as String, '${f['name'] ?? f['id']}'));
        }
      }
      pageToken = body['nextPageToken'] as String?;
    } while (pageToken != null && out.length < max);
    return out;
  }

  /// Whether the identity may edit [spreadsheetId] (Drive capabilities).
  /// null = could not be determined (e.g. the Drive API is not enabled).
  Future<bool?> canEdit(String spreadsheetId) async {
    try {
      final body = await _call(
        'GET',
        Uri.parse('$_driveBase/${Uri.encodeComponent(spreadsheetId)}')
            .replace(queryParameters: {
          'fields': 'capabilities/canEdit',
          'supportsAllDrives': 'true',
        }),
      );
      final caps = body['capabilities'];
      return caps is Map && caps['canEdit'] is bool
          ? caps['canEdit'] as bool
          : null;
    } on SheetsApiException {
      return null;
    }
  }

  // --------------------------------------------------------------- Sheets

  /// Spreadsheet title and its worksheet tabs (chart tabs are left out).
  Future<SpreadsheetMeta> getSpreadsheet(String spreadsheetId) async {
    final body = await _call(
      'GET',
      Uri.parse('$_sheetsBase/${Uri.encodeComponent(spreadsheetId)}')
          .replace(queryParameters: {
        'fields': 'spreadsheetId,properties.title,'
            'sheets.properties(sheetId,title,index,hidden,sheetType,'
            'gridProperties(rowCount,columnCount))',
      }),
    );
    final sheets = <WorksheetInfo>[];
    for (final s in (body['sheets'] as List<dynamic>? ?? const [])) {
      final p = (s as Map)['properties'] as Map? ?? const {};
      final type = p['sheetType'] as String?;
      if (type != null && type != 'GRID') continue;
      final grid = p['gridProperties'] as Map? ?? const {};
      sheets.add(WorksheetInfo(
        sheetId: (p['sheetId'] as num?)?.toInt() ?? 0,
        title: '${p['title'] ?? ''}',
        index: (p['index'] as num?)?.toInt() ?? sheets.length,
        rowCount: (grid['rowCount'] as num?)?.toInt() ?? 0,
        columnCount: (grid['columnCount'] as num?)?.toInt() ?? 0,
        hidden: p['hidden'] == true,
      ));
    }
    sheets.sort((a, b) => a.index.compareTo(b.index));
    final title = ((body['properties'] as Map?)?['title']) as String?;
    return SpreadsheetMeta(
        (body['spreadsheetId'] as String?) ?? spreadsheetId,
        title ?? spreadsheetId,
        sheets);
  }

  /// Every used cell of one worksheet as displayed text. Row i of the result
  /// is sheet row i + 1 and column j is sheet column j + 1 (leading blank
  /// rows / columns are kept; only trailing blanks are cut by Google).
  Future<List<List<String>>> readSheet(String spreadsheetId, String title) =>
      readRange(spreadsheetId, A1.sheet(title));

  /// One column of a worksheet; index i is sheet row i + 1.
  Future<List<String>> readColumn(
      String spreadsheetId, String title, int col) async {
    final rows =
        await readRange(spreadsheetId, A1.wholeColumn(title, col));
    return [for (final r in rows) r.isEmpty ? '' : r.first];
  }

  Future<List<List<String>>> readRange(String spreadsheetId, String a1) async {
    final body = await _call(
      'GET',
      Uri.parse('$_sheetsBase/${Uri.encodeComponent(spreadsheetId)}'
              '/values/${Uri.encodeComponent(a1)}')
          .replace(queryParameters: {
        'majorDimension': 'ROWS',
        'valueRenderOption': 'FORMATTED_VALUE',
      }),
    );
    return [
      for (final r in (body['values'] as List<dynamic>? ?? const []))
        [for (final c in (r as List<dynamic>)) '$c'],
    ];
  }

  /// Writes single cells (a1 -> value) in one request. Values are stored as
  /// given: a Dart bool becomes a real TRUE / FALSE cell, text stays text
  /// (RAW, so nothing is evaluated as a formula). Setting a cell to the same
  /// value twice is harmless, so this is retried freely.
  Future<void> writeCells(String spreadsheetId, Map<String, Object> cells) async {
    if (cells.isEmpty) return;
    await _call(
      'POST',
      Uri.parse('$_sheetsBase/${Uri.encodeComponent(spreadsheetId)}'
          '/values:batchUpdate'),
      body: {
        'valueInputOption': 'RAW',
        'data': [
          for (final e in cells.entries)
            {
              'range': e.key,
              'majorDimension': 'ROWS',
              'values': [
                [e.value]
              ],
            },
        ],
      },
    );
  }

  /// Adds [count] empty columns at the right edge of the worksheet.
  Future<void> addColumns(String spreadsheetId, int sheetId, int count) =>
      _call(
        'POST',
        Uri.parse('$_sheetsBase/${Uri.encodeComponent(spreadsheetId)}'
            ':batchUpdate'),
        body: {
          'requests': [
            {
              'appendDimension': {
                'sheetId': sheetId,
                'dimension': 'COLUMNS',
                'length': count,
              },
            },
          ],
        },
        idempotent: false,
      );

  // ------------------------------------------------------------ transport

  Future<Map<String, dynamic>> _call(String method, Uri url,
      {Object? body, bool idempotent = true}) async {
    for (var attempt = 1;; attempt++) {
      final http.Response res;
      try {
        final fut = method == 'GET'
            ? _http.get(url)
            : _http.post(url,
                headers: const {'content-type': 'application/json'},
                body: jsonEncode(body));
        res = await fut.timeout(requestTimeout);
      } on AccessDeniedException {
        throw const SheetsApiException(
            'Google did not accept the saved credentials. Upload the '
            'service-account JSON file again in Settings.',
            reason: 'auth');
      } on ServerRequestFailedException catch (e) {
        final s = e.statusCode;
        if (s != null && s >= 400 && s < 500 && s != 429) {
          throw const SheetsApiException(
              'Google refused to sign in with the saved credentials (the key '
              'may have been deleted or disabled). Upload a new JSON key in '
              'Settings.',
              reason: 'auth');
        }
        if (await _canRetry(attempt, idempotent: idempotent, quota: s == 429)) {
          continue;
        }
        throw const SheetsApiException(
            'Could not sign in to Google right now. Try again shortly.',
            reason: 'network');
      } on TimeoutException {
        if (await _canRetry(attempt, idempotent: idempotent)) continue;
        throw SheetsApiException(
            'Google did not answer in time. Check the internet connection.'
            '${idempotent ? '' : ' The change may or may not have been applied.'}',
            reason: 'network');
      } on SocketException catch (_) {
        if (await _canRetry(attempt, idempotent: idempotent)) continue;
        throw const SheetsApiException(
            'No connection to Google. Check the internet connection.',
            reason: 'network');
      } on HandshakeException catch (_) {
        throw const SheetsApiException(
            'A secure connection to Google could not be made. Check the '
            'phone date/time and the network.',
            reason: 'network');
      } on TlsException catch (_) {
        throw const SheetsApiException(
            'A secure connection to Google could not be made.',
            reason: 'network');
      } on http.ClientException catch (_) {
        if (await _canRetry(attempt, idempotent: idempotent)) continue;
        throw const SheetsApiException(
            'The connection to Google was interrupted. Try again.',
            reason: 'network');
      }

      if (res.statusCode >= 200 && res.statusCode < 300) {
        if (res.body.trim().isEmpty) return const {};
        final decoded = jsonDecode(res.body);
        return decoded is Map<String, dynamic> ? decoded : const {};
      }

      final err = _errorOf(res);
      final quota = res.statusCode == 429 ||
          (res.statusCode == 403 &&
              (err.reason == 'rateLimitExceeded' ||
                  err.reason == 'userRateLimitExceeded'));
      final transient =
          quota || (res.statusCode >= 500 && res.statusCode < 600);
      if (transient &&
          await _canRetry(attempt,
              idempotent: idempotent,
              quota: quota,
              retryAfter: res.headers['retry-after'])) {
        continue;
      }
      throw _friendly(res.statusCode, err);
    }
  }

  /// Sleeps (exponential backoff) and returns true when another attempt is
  /// allowed.
  Future<bool> _canRetry(int attempt,
      {required bool idempotent, bool quota = false, String? retryAfter}) async {
    if (attempt >= maxAttempts) return false;
    if (!idempotent && !quota) return false; // outcome unknown: never repeat
    final hinted = int.tryParse(retryAfter ?? '');
    final base = quota ? 4 : 1; // seconds; Sheets quotas reset per minute
    var wait = hinted != null && hinted > 0
        ? Duration(seconds: hinted)
        : Duration(seconds: base * (1 << (attempt - 1)));
    if (wait > const Duration(seconds: 60)) wait = const Duration(seconds: 60);
    await _delay(wait);
    return true;
  }

  ({String message, String? reason}) _errorOf(http.Response res) {
    try {
      final j = jsonDecode(res.body);
      final e = j is Map ? j['error'] : null;
      if (e is Map) {
        String? reason;
        final errors = e['errors'];
        if (errors is List && errors.isNotEmpty && errors.first is Map) {
          reason = (errors.first as Map)['reason'] as String?;
        }
        final details = e['details'];
        if (reason == null && details is List) {
          for (final d in details) {
            if (d is Map && d['reason'] is String) {
              reason = d['reason'] as String;
              break;
            }
          }
        }
        return (message: '${e['message'] ?? ''}', reason: reason);
      }
    } catch (_) {}
    return (message: '', reason: null);
  }

  SheetsApiException _friendly(
      int status, ({String message, String? reason}) err) {
    final who = serviceAccountEmail.isEmpty
        ? 'the service-account email'
        : serviceAccountEmail;
    final lower = err.message.toLowerCase();
    switch (status) {
      case 400:
        return SheetsApiException(
            'Google rejected the request'
            '${err.message.isEmpty ? '' : ': ${_clip(err.message)}'}',
            statusCode: status,
            reason: err.reason);
      case 401:
        return SheetsApiException(
            'Google did not accept the credentials. Upload the '
            'service-account JSON file again in Settings.',
            statusCode: status,
            reason: err.reason);
      case 403:
        if (err.reason == 'accessNotConfigured' ||
            err.reason == 'SERVICE_DISABLED' ||
            lower.contains('has not been used in project') ||
            lower.contains('is disabled') ||
            lower.contains('not enabled')) {
          return SheetsApiException(
              'The Google Sheets API and/or Google Drive API is not enabled '
              'for the Google Cloud project of these credentials. Enable '
              'both in APIs & Services > Library, wait a minute, and try '
              'again.',
              statusCode: status,
              reason: err.reason);
        }
        return SheetsApiException(
            'No permission. Share the spreadsheet with $who and give it '
            'Editor access.',
            statusCode: status,
            reason: err.reason);
      case 404:
        return SheetsApiException(
            'Spreadsheet or tab not found. Check the link / ID, and that '
            'the spreadsheet is shared with $who.',
            statusCode: status,
            reason: err.reason);
      case 429:
        return SheetsApiException(
            'Google rate limit reached. Wait a minute and try again.',
            statusCode: status,
            reason: err.reason);
    }
    if (status >= 500) {
      return SheetsApiException(
          'Google Sheets is temporarily unavailable (error $status). Try '
          'again shortly.',
          statusCode: status,
          reason: err.reason);
    }
    return SheetsApiException(
        'Google returned error $status'
        '${err.message.isEmpty ? '' : ': ${_clip(err.message)}'}',
        statusCode: status,
        reason: err.reason);
  }

  static String _clip(String s) => s.length <= 200 ? s : '${s.substring(0, 200)}…';
}
