import 'dart:async';
import 'dart:io' show SocketException;

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:googleapis_auth/auth_io.dart'
    show
        AccessDeniedException,
        ServerRequestFailedException,
        clientViaServiceAccount;

import 'credential_store.dart';
import 'google_credentials.dart';
import 'sheet_layout.dart';
import 'sheet_recipient_reader.dart';
import 'sheet_status_writer.dart';
import 'sheets_api.dart';

/// OAuth scopes requested for the service account:
///  * spreadsheets — read recipients and write the status column;
///  * drive.metadata.readonly — ONLY to list which spreadsheets are shared
///    with the account (the Sheets API cannot list spreadsheets) and to check
///    edit rights. It cannot read file contents. Entering a link / ID works
///    without listing.
const sheetsScopes = <String>[
  'https://www.googleapis.com/auth/spreadsheets',
  'https://www.googleapis.com/auth/drive.metadata.readonly',
];

typedef SheetsApiFactory = Future<SheetsApi> Function(
    GoogleCredentials credentials);

/// Owns the saved credentials and hands out a [SheetsApi] that is signed in
/// with them. One instance is shared by the Settings and Bulk screens.
class SheetsService {
  SheetsService({CredentialStore? store, SheetsApiFactory? apiFactory})
      : store = store ?? SecureCredentialStore(),
        _apiFactory = apiFactory ?? _connect;

  /// The app-wide instance. Tests replace it.
  static SheetsService instance = SheetsService();

  final CredentialStore store;
  final SheetsApiFactory _apiFactory;

  /// Bumped when credentials are added / replaced / removed, so open screens
  /// refresh.
  final changes = ValueNotifier<int>(0);

  SheetsApi? _api;
  Future<SheetsApi>? _opening;

  /// The saved credentials, or null when none are configured.
  Future<GoogleCredentials?> credentials() => store.read();

  /// Validates [jsonText] and, only if it is a usable service-account key,
  /// saves it (replacing any earlier one). Throws [CredentialException].
  Future<GoogleCredentials> saveFromJson(String jsonText) async {
    final creds = GoogleCredentials.parse(jsonText);
    await store.write(creds);
    _reset();
    changes.value++;
    return creds;
  }

  Future<void> remove() async {
    await store.delete();
    _reset();
    changes.value++;
  }

  /// A signed-in API. Throws [CredentialException] when nothing is configured
  /// and [SheetsApiException] when Google refuses the key. A failure is not
  /// remembered: the next call tries again.
  Future<SheetsApi> api() {
    final ready = _api;
    if (ready != null) return Future.value(ready);
    return _opening ??= _open().whenComplete(() => _opening = null);
  }

  Future<SheetsApi> _open() async {
    final creds = await store.read();
    if (creds == null) {
      throw const CredentialException(
          'Google credentials are not set up. Open Settings > Google Sheets '
          'and upload the service-account JSON file.');
    }
    return _api = await _apiFactory(creds);
  }

  void _reset() {
    _api?.close();
    _api = null;
    _opening = null;
  }

  static Future<SheetsApi> _connect(GoogleCredentials creds) async {
    try {
      final client =
          await clientViaServiceAccount(creds.toAuth(), sheetsScopes);
      return SheetsApi(client, serviceAccountEmail: creds.clientEmail);
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
      throw const SheetsApiException(
          'Could not sign in to Google right now. Try again shortly.',
          reason: 'network');
    } on SocketException {
      throw const SheetsApiException(
          'No connection to Google. Check the internet connection.',
          reason: 'network');
    } on TimeoutException {
      throw const SheetsApiException(
          'Google did not answer in time. Check the internet connection.',
          reason: 'network');
    }
  }
}

/// One loaded worksheet, ready to send from: remembers where the recipients
/// came from and writes their statuses back.
class SheetsSession {
  SheetsSession({
    required this.api,
    required this.spreadsheetId,
    required this.spreadsheetName,
    required this.worksheetId,
    required String worksheetTitle,
    required this.statusHeader,
  }) : writer = SheetStatusWriter(
          api: api,
          spreadsheetId: spreadsheetId,
          worksheetId: worksheetId,
          worksheetTitle: worksheetTitle,
          statusHeader: statusHeader,
        );

  final SheetsApi api;
  final String spreadsheetId;
  final String spreadsheetName;
  final int worksheetId;
  final String statusHeader;
  final SheetStatusWriter writer;

  String get worksheetTitle => writer.worksheetTitle;

  /// Reads the worksheet's recipients (fresh from Google).
  Future<SheetLoad> load() async {
    final table = await api.readSheet(spreadsheetId, worksheetTitle);
    try {
      return SheetRecipientReader.read(table, statusHeader: statusHeader);
    } on SheetFormatException catch (e) {
      throw SheetsApiException(e.message);
    }
  }

  /// Run before any email is sent: confirms the spreadsheet and the selected
  /// tab are reachable, that the account may edit them, and that the status
  /// column exists (creating it once if it does not). A failure here stops
  /// the run before the first email, so no status can be lost for lack of
  /// access.
  Future<void> prepareForSending() async {
    final meta = await api.getSpreadsheet(spreadsheetId);
    final tab = meta.worksheets.where((w) => w.sheetId == worksheetId);
    if (tab.isEmpty) {
      throw const SheetsApiException(
          'The selected worksheet tab no longer exists. Choose the tab '
          'again and reload.');
    }
    writer.worksheetTitle = tab.first.title; // follows a rename
    if (await api.canEdit(spreadsheetId) == false) {
      final who = api.serviceAccountEmail.isEmpty
          ? 'the service account'
          : api.serviceAccountEmail;
      throw SheetsApiException('The spreadsheet is shared with $who as '
          'Viewer only. Give it Editor access so email statuses can be '
          'saved.');
    }
    try {
      await writer.ensureStatusColumn();
    } on SheetFormatException catch (e) {
      throw SheetsApiException(e.message);
    }
  }
}
