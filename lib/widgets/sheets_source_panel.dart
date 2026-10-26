import 'package:flutter/material.dart';

import '../services/sheets/google_credentials.dart';
import '../services/sheets/sheet_recipient_reader.dart';
import '../services/sheets/sheets_api.dart';
import '../services/sheets/sheets_config.dart';
import '../services/sheets/sheets_service.dart';

/// Bulk tab, "Google Sheets" source: choose spreadsheet and worksheet tab,
/// then load the recipients. The choice is remembered.
///
/// Every failure is shown here and nothing falls back to CSV by itself.
class SheetsSourcePanel extends StatefulWidget {
  const SheetsSourcePanel({
    super.key,
    required this.enabled,
    required this.onLoaded,
    this.onOpenSettings,
  });

  /// false while an email run is going on.
  final bool enabled;
  final Future<void> Function(SheetsSession session, SheetLoad load) onLoaded;
  final VoidCallback? onOpenSettings;

  @override
  State<SheetsSourcePanel> createState() => _SheetsSourcePanelState();
}

class _SheetsSourcePanelState extends State<SheetsSourcePanel> {
  final _service = SheetsService.instance;

  bool _checking = true;
  GoogleCredentials? _creds;
  SheetsConfig _config = SheetsConfig();

  List<SpreadsheetRef> _spreadsheets = const [];
  SpreadsheetMeta? _meta;

  String? _busy; // what is going on, or null
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    _service.changes.addListener(_credentialsChanged);
    _init();
  }

  @override
  void dispose() {
    _service.changes.removeListener(_credentialsChanged);
    super.dispose();
  }

  void _credentialsChanged() {
    if (!mounted) return;
    setState(() {
      _meta = null;
      _spreadsheets = const [];
      _error = null;
      _notice = null;
    });
    _init();
  }

  Future<void> _init() async {
    GoogleCredentials? creds;
    String? credError;
    try {
      creds = await _service.credentials();
    } on CredentialException catch (e) {
      credError = e.message;
    } catch (_) {
      credError = 'The saved Google credentials could not be read.';
    }
    final config = await SheetsConfigStore.load();
    if (!mounted) return;
    setState(() {
      _creds = creds;
      _config = config;
      _error = credError;
      _checking = false;
    });
    // Show the remembered spreadsheet's tabs again.
    if (creds != null && config.spreadsheetId.isNotEmpty) {
      await _loadMeta(config.spreadsheetId, keepSelection: true);
    }
  }

  Future<T?> _run<T>(String label, Future<T> Function() job) async {
    setState(() {
      _busy = label;
      _error = null;
      _notice = null;
    });
    try {
      return await job();
    } on SheetsApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } on CredentialException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Something went wrong. Try again.');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
    return null;
  }

  Future<void> _listSpreadsheets() async {
    final list = await _run('Loading spreadsheets…', () async {
      final api = await _service.api();
      try {
        return await api.listSpreadsheets();
      } on SheetsApiException catch (e) {
        throw SheetsApiException(
            '${e.message}\nYou can still paste the spreadsheet link instead '
            '("Use link / ID").',
            statusCode: e.statusCode,
            reason: e.reason);
      }
    });
    if (list == null || !mounted) return;
    setState(() {
      _spreadsheets = list;
      if (list.isEmpty) {
        _notice = 'No spreadsheet is shared with '
            '${_creds?.clientEmail ?? 'the service account'} yet. Share '
            'one with that address (Editor), or paste its link.';
      }
    });
  }

  Future<void> _enterLink() async {
    final ctl = TextEditingController();
    final link = await showDialog<SpreadsheetLink>(
      context: context,
      builder: (ctx) {
        String? err;
        return StatefulBuilder(
          builder: (ctx, setD) => AlertDialog(
            title: const Text('Spreadsheet link or ID'),
            content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(
                controller: ctl,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: 'https://docs.google.com/spreadsheets/d/…',
                  errorText: err,
                ),
              ),
            ]),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () {
                  final l = SpreadsheetLink.parse(ctl.text);
                  if (l == null) {
                    setD(() => err = 'This is not a Google Sheets link or ID.');
                  } else {
                    Navigator.pop(ctx, l);
                  }
                },
                child: const Text('Use'),
              ),
            ],
          ),
        );
      },
    );
    ctl.dispose();
    if (link == null || !mounted) return;
    await _loadMeta(link.id, gid: link.gid);
  }

  /// Fetches the spreadsheet's tabs (this also proves it is reachable).
  Future<void> _loadMeta(String id, {int? gid, bool keepSelection = false}) async {
    final meta = await _run('Loading worksheet tabs…', () async {
      final api = await _service.api();
      return api.getSpreadsheet(id);
    });
    if (meta == null || !mounted) return;
    final keepTab = keepSelection && _config.spreadsheetId == id;
    WorksheetInfo? tab;
    if (gid != null) {
      tab = meta.worksheets.where((w) => w.sheetId == gid).firstOrNull;
    } else if (keepTab) {
      tab = meta.worksheets
              .where((w) => w.sheetId == _config.worksheetId)
              .firstOrNull ??
          meta.worksheets
              .where((w) => w.title == _config.worksheetTitle)
              .firstOrNull;
    }
    setState(() {
      _meta = meta;
      _config
        ..spreadsheetId = id
        ..spreadsheetName = meta.title
        ..worksheetId = tab?.sheetId
        ..worksheetTitle = tab?.title ?? '';
      if (keepTab && tab == null && _config.worksheetTitle.isEmpty) {
        _notice = 'The saved worksheet tab no longer exists. Choose a tab.';
      }
      if (meta.worksheets.length == 1 && tab == null) {
        tab = meta.worksheets.first; // only one tab: nothing to choose
        _config
          ..worksheetId = tab!.sheetId
          ..worksheetTitle = tab!.title;
      }
    });
    await SheetsConfigStore.save(_config);
  }

  Future<void> _pickTab(int? sheetId) async {
    final tab = _meta?.worksheets.where((w) => w.sheetId == sheetId).firstOrNull;
    if (tab == null) return;
    setState(() {
      _config
        ..worksheetId = tab.sheetId
        ..worksheetTitle = tab.title;
      _error = null;
      _notice = null;
    });
    await SheetsConfigStore.save(_config);
  }

  /// Validates the selection against Google and loads the recipients. Also
  /// the "Refresh" action: it always reads the sheet again.
  Future<void> _load() async {
    final id = _config.spreadsheetId;
    final tabId = _config.worksheetId;
    if (id.isEmpty || tabId == null) return;
    final result = await _run('Loading recipients…', () async {
      final api = await _service.api();
      // The spreadsheet and the tab must be reachable *now*; a renamed tab
      // is followed by its id.
      final meta = await api.getSpreadsheet(id);
      final tab = meta.worksheets.where((w) => w.sheetId == tabId).firstOrNull;
      if (tab == null) {
        throw const SheetsApiException(
            'This worksheet tab no longer exists. Choose a tab again.');
      }
      final cfg = await SheetsConfigStore.load();
      final session = SheetsSession(
        api: api,
        spreadsheetId: id,
        spreadsheetName: meta.title,
        worksheetId: tab.sheetId,
        worksheetTitle: tab.title,
        statusHeader: cfg.statusHeader,
      );
      return (meta: meta, tab: tab, session: session, load: await session.load());
    });
    if (result == null || !mounted) return;
    setState(() {
      _meta = result.meta;
      _config
        ..spreadsheetName = result.meta.title
        ..worksheetTitle = result.tab.title;
    });
    await SheetsConfigStore.save(_config);
    await widget.onLoaded(result.session, result.load);
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_creds == null) return _notConfigured(context);

    final busy = _busy != null;
    final can = widget.enabled && !busy;

    // Remembered spreadsheet must be selectable even before the list loads.
    final options = <String, String>{
      for (final s in _spreadsheets) s.id: s.name,
      if (_config.spreadsheetId.isNotEmpty)
        _config.spreadsheetId: _config.spreadsheetName.isEmpty
            ? _config.spreadsheetId
            : _config.spreadsheetName,
    };
    final tabs = _meta?.worksheets ?? const <WorksheetInfo>[];
    final tabSelected = tabs.any((w) => w.sheetId == _config.worksheetId);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('Google account: ${_creds!.clientEmail}',
          style: const TextStyle(fontSize: 11.5, color: Colors.black54),
          overflow: TextOverflow.ellipsis),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            key: ValueKey('ss-${options.length}-${_config.spreadsheetId}'),
            isExpanded: true,
            initialValue: options.containsKey(_config.spreadsheetId)
                ? _config.spreadsheetId
                : null,
            decoration: const InputDecoration(labelText: 'Spreadsheet'),
            hint: const Text('Choose a spreadsheet'),
            items: [
              for (final e in options.entries)
                DropdownMenuItem(
                    value: e.key,
                    child: Text(e.value, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: can
                ? (id) {
                    if (id != null && id != _config.spreadsheetId) {
                      _config.spreadsheetName = options[id] ?? '';
                      _loadMeta(id);
                    }
                  }
                : null,
          ),
        ),
        IconButton(
          tooltip: 'Find spreadsheets shared with this account',
          icon: const Icon(Icons.manage_search),
          onPressed: can ? _listSpreadsheets : null,
        ),
        IconButton(
          tooltip: 'Use a link / ID',
          icon: const Icon(Icons.link),
          onPressed: can ? _enterLink : null,
        ),
      ]),
      const SizedBox(height: 10),
      DropdownButtonFormField<int>(
        key: ValueKey('ws-${tabs.length}-${_config.worksheetId}'),
        isExpanded: true,
        initialValue: tabSelected ? _config.worksheetId : null,
        decoration: const InputDecoration(labelText: 'Worksheet tab'),
        hint: Text(tabs.isEmpty ? 'Choose a spreadsheet first' : 'Choose a tab'),
        items: [
          for (final w in tabs)
            DropdownMenuItem(
                value: w.sheetId,
                child: Text(w.hidden ? '${w.title} (hidden)' : w.title,
                    overflow: TextOverflow.ellipsis)),
        ],
        onChanged: can && tabs.isNotEmpty ? _pickTab : null,
      ),
      const SizedBox(height: 10),
      OutlinedButton.icon(
        icon: busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.refresh),
        label: Text(_busy ?? 'Load recipients'),
        onPressed: can && tabSelected ? _load : null,
      ),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(
          'Status is saved in the column "${_config.statusHeader}" '
          '(TRUE = sent, FALSE = failed).',
          style: const TextStyle(fontSize: 11, color: Colors.black54),
        ),
      ),
      if (_notice != null) _box(_notice!, Colors.blueGrey.shade700),
      if (_error != null) _box(_error!, Colors.red.shade800),
    ]);
  }

  Widget _box(String text, Color color) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(text, style: TextStyle(fontSize: 12, color: color)),
      );

  Widget _notConfigured(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(76),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Google Sheets is not set up yet',
                    style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                const Text(
                    'Upload your Google service-account key in Settings, then '
                    'share your spreadsheet with that account. You can also '
                    'switch to "CSV File" above.',
                    style: TextStyle(fontSize: 12.5)),
                if (_error != null) _box(_error!, Colors.red.shade800),
                if (widget.onOpenSettings != null) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    icon: const Icon(Icons.settings),
                    label: const Text('Open Settings'),
                    onPressed: widget.onOpenSettings,
                  ),
                ],
              ]),
        ),
      );
}
