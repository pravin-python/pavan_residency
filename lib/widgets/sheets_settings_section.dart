import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/sheets/google_credentials.dart';
import '../services/sheets/sheets_api.dart';
import '../services/sheets/sheets_config.dart';
import '../services/sheets/sheets_service.dart';

/// Settings tab: Google Sheets access. Upload / replace / remove the
/// service-account key, test the connection, choose the status column title
/// and read the one-time Google setup steps.
class SheetsSettingsSection extends StatefulWidget {
  const SheetsSettingsSection({super.key});

  @override
  State<SheetsSettingsSection> createState() => _SheetsSettingsSectionState();
}

class _SheetsSettingsSectionState extends State<SheetsSettingsSection> {
  final _service = SheetsService.instance;
  final _header = TextEditingController();

  bool _loading = true;
  bool _busy = false;
  GoogleCredentials? _creds;
  String? _loadError;
  String? _headerError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _header.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    GoogleCredentials? creds;
    String? err;
    try {
      creds = await _service.credentials();
    } on CredentialException catch (e) {
      err = e.message;
    } catch (_) {
      err = 'The saved Google credentials could not be read.';
    }
    final cfg = await SheetsConfigStore.load();
    if (!mounted) return;
    setState(() {
      _creds = creds;
      _loadError = err;
      _header.text = cfg.statusHeader;
      _loading = false;
    });
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: err ? Colors.red.shade800 : Colors.green,
    ));
  }

  Future<void> _pickCredentials() async {
    final FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
        withData: true,
      );
    } catch (e) {
      _snack('Could not open the file picker.', err: true);
      return;
    }
    final bytes = res?.files.single.bytes;
    if (bytes == null) return; // cancelled
    setState(() => _busy = true);
    try {
      // The text is only held in memory while it is validated; only the
      // fields needed to sign in are stored, in secure storage.
      final creds =
          await _service.saveFromJson(utf8.decode(bytes, allowMalformed: true));
      if (!mounted) return;
      setState(() {
        _creds = creds;
        _loadError = null;
      });
      _snack('✓ Credentials saved for ${creds.clientEmail}. Share your '
          'spreadsheet with this address (Editor). You can now delete the '
          'downloaded JSON file from this phone.');
    } on CredentialException catch (e) {
      _snack(e.message, err: true); // nothing was changed
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove() async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Remove Google credentials?'),
            content: const Text(
                'Google Sheets stops working until you upload a key again. '
                'Nothing in your spreadsheets is changed.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Remove')),
            ],
          ),
        ) ??
        false;
    if (!ok || !mounted) return;
    try {
      await _service.remove();
      if (!mounted) return;
      setState(() {
        _creds = null;
        _loadError = null;
      });
      _snack('Google credentials removed.');
    } on CredentialException catch (e) {
      _snack(e.message, err: true);
    }
  }

  Future<void> _test() async {
    setState(() => _busy = true);
    try {
      final api = await _service.api();
      final meta = await api.listSpreadsheets();
      _snack('✓ Connected to Google. ${meta.length} '
          '${meta.length == 1 ? 'spreadsheet is' : 'spreadsheets are'} '
          'shared with this account.');
    } on SheetsApiException catch (e) {
      _snack(e.message, err: true);
    } on CredentialException catch (e) {
      _snack(e.message, err: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveHeader() async {
    final err = SheetsConfig.validStatusHeader(_header.text);
    setState(() => _headerError = err);
    if (err != null) return;
    final cfg = await SheetsConfigStore.load(); // keep the selection as is
    cfg.statusHeader = _header.text.trim();
    await SheetsConfigStore.save(cfg);
    if (!mounted) return;

    _snack('✓ Status column title saved. Reload the sheet in the Bulk tab.');
  }

  static const _steps = '''
1. Open console.cloud.google.com and create a project (or pick one).
2. APIs & Services > Library: enable "Google Sheets API" and "Google Drive API". (Enabling the Sheets API alone does not let the app list your spreadsheets; the Drive API is needed for that. If you only paste spreadsheet links you can skip Drive.)
3. IAM & Admin > Service Accounts > Create service account (no roles needed).
4. Open the account > Keys > Add key > Create new key > JSON. A .json file downloads.
5. Tap "Upload credentials" above and choose that file.
6. Open your spreadsheet in Google Sheets > Share, paste the service-account email shown above and give it Editor access. A service account can only see spreadsheets that are shared with it; the key alone gives no access to any of your files.
7. In the Bulk tab choose the spreadsheet and the worksheet tab, then tap Load recipients.''';

  @override
  Widget build(BuildContext context) {
    final creds = _creds;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Google Sheets',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
      const SizedBox(height: 10),
      if (_loading)
        const LinearProgressIndicator()
      else ...[
        if (creds != null)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
                border: Border.all(color: Colors.green.shade300),
                borderRadius: BorderRadius.circular(8)),
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('✓ Credentials configured',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 4),
                  SelectableText('Share your spreadsheet with:\n'
                      '${creds.clientEmail}',
                      style: const TextStyle(fontSize: 12)),
                  if (creds.projectId.isNotEmpty)
                    Text('Project: ${creds.projectId}',
                        style: const TextStyle(
                            fontSize: 11.5, color: Colors.black54)),
                ]),
          )
        else
          Text(
              _loadError ??
                  'No credentials yet. Upload the service-account JSON key '
                      'from Google Cloud (steps below).',
              style: TextStyle(
                  fontSize: 12.5,
                  color: _loadError != null ? Colors.red.shade800 : null)),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 4, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.key),
            label: Text(creds == null ? 'Upload credentials' : 'Replace'),
            onPressed: _busy ? null : _pickCredentials,
          ),
          if (creds != null)
            OutlinedButton.icon(
              icon: const Icon(Icons.wifi_tethering),
              label: const Text('Test connection'),
              onPressed: _busy ? null : _test,
            ),
          if (creds != null || _loadError != null)
            TextButton(
              onPressed: _busy ? null : _remove,
              child: const Text('Remove'),
            ),
        ]),
        const SizedBox(height: 12),
        TextField(
          controller: _header,
          decoration: InputDecoration(
            labelText: 'Status column title',
            helperText: 'Created once in the worksheet if it is missing. '
                'TRUE = email sent, FALSE = failed.',
            helperMaxLines: 2,
            errorText: _headerError,
            suffixIcon: IconButton(
              tooltip: 'Save title',
              icon: const Icon(Icons.check),
              onPressed: _saveHeader,
            ),
          ),
          onSubmitted: (_) => _saveHeader(),
        ),
        const SizedBox(height: 6),
        const ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text('Setup instructions',
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
          childrenPadding: EdgeInsets.only(bottom: 8),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_steps, style: TextStyle(fontSize: 12, height: 1.4)),
            SizedBox(height: 8),
            Text(
                'Security: the key is kept only in this phone\'s encrypted '
                '(Android Keystore) storage, is never logged, and is not '
                'included in backups. Anyone who gets the JSON file can act '
                'as this account on the spreadsheets shared with it, so '
                'share only the sheets you need and delete the downloaded '
                'file after uploading. Revoke a lost key in Google Cloud > '
                'Service Accounts > Keys.',
                style: TextStyle(fontSize: 12, height: 1.4)),
          ],
        ),
      ],
    ]);
  }
}
