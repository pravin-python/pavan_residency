import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/receipt_data.dart';
import '../services/csv_service.dart';
import '../services/email_service.dart';
import '../services/pdf_service.dart';
import '../services/sent_log.dart';
import '../services/settings_service.dart';
import '../services/sheets/google_credentials.dart';
import '../services/sheets/sheet_recipient_reader.dart';
import '../services/sheets/sheet_status_writer.dart';
import '../services/sheets/sheets_api.dart';
import '../services/sheets/sheets_service.dart';
import '../utils/file_saver.dart';
import '../widgets/sheets_source_panel.dart';

/// Where the recipients come from.
enum _Source { sheets, csv }

class BulkScreen extends StatefulWidget {
  const BulkScreen({super.key, this.onOpenSettings});

  /// Lets the Google Sheets panel jump to the Settings tab.
  final VoidCallback? onOpenSettings;

  /// How many emails are sent at the same time (one SMTP connection each).
  /// Gmail allows a few parallel connections; more would risk being
  /// throttled.
  static const parallel = 4;

  @override
  State<BulkScreen> createState() => _BulkScreenState();
}

const _typeLabel = {
  PaymentType.maintenance: 'Maintenance',
  PaymentType.deposit: 'Deposit',
  PaymentType.transfer: 'Transfer Fee',
  PaymentType.other: 'Other',
};
const _modeLabel = {
  PaymentMode.cash: 'Cash',
  PaymentMode.cheque: 'Cheque',
  PaymentMode.online: 'Online',
};
const _langLabel = {'gu': 'Gujarati', 'hi': 'Hindi', 'en': 'English'};

class _BulkScreenState extends State<BulkScreen> {
  List<ReceiptData> _rows = [];
  bool _sending = false;
  int _done = 0;
  int _total = 0;
  bool _stop = false;

  /// Google Sheets is the default source; CSV stays available.
  _Source _source = _Source.sheets;

  /// The loaded worksheet (Google Sheets source only).
  SheetsSession? _sheet;

  /// Saving statuses again after a failed write is running.
  bool _savingStatus = false;

  /// Rows that own their receipt no. already (a send that may have been
  /// delivered, a number that could not be given back, or a deliberate
  /// re-send): a retry uses the same number and they don't trigger the
  /// "number may already be used" warning.
  final _ownsNumber = <ReceiptData>{};

  Future<void> _pickCsv() async {
    try {
      final res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['csv'],
        withData: true,
      );
      final bytes = res?.files.single.bytes;
      if (bytes == null) return; // cancelled
      final rows = CsvService.parse(bytes);
      _flagDuplicateNos(rows);
      final before = await _markSentBefore(rows);
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _done = 0;
        _total = 0;
        _ownsNumber.clear();
      });
      if (rows.isEmpty) {
        _snack('No rows found in the CSV. Check the header and the data.',
            err: true);
      } else if (before > 0) {
        _snack('$before ${before == 1 ? 'row was' : 'rows were'} already sent '
            'and will be skipped. Long-press a row to send it again.');
      }
    } catch (e) {
      _snack('Could not read the CSV file: $e', err: true);
    }
  }

  /// Already mailed from this phone (e.g. an interrupted bulk run, then the
  /// same list loaded again): don't send those a second time. Returns how
  /// many rows were marked.
  Future<int> _markSentBefore(List<ReceiptData> rows) async {
    var before = 0;
    final matched = <String>{}; // one log entry marks at most one row
    for (final r in rows) {
      if (r.status != SendStatus.ready) continue;
      final no = await SentLog.sentNo(r);
      if (no != null && matched.add(SentLog.keyOf(r))) {
        r
          ..status = SendStatus.sent
          ..recNo = no
          ..sentBefore = true;
        before++;
      }
    }
    return before;
  }

  void _setSource(_Source s) {
    if (_sending || _savingStatus || s == _source) return;
    setState(() {
      _source = s;
      _rows = [];
      _sheet = null;
      _done = 0;
      _total = 0;
      _ownsNumber.clear();
    });
  }

  /// A worksheet was loaded from Google Sheets.
  Future<void> _onSheetLoaded(SheetsSession session, SheetLoad load) async {
    final rows = load.rows;
    _flagDuplicateNos(rows);
    final before = await _markSentBefore(rows);
    var owed = 0;
    for (final r in rows) {
      if (r.status != SendStatus.sent) continue;
      // Delivered (this phone's log or the sheet says so) -> show its number.
      if (r.recNo == 0) {
        final no = await SentLog.sentNo(r);
        if (no != null) r.recNo = no;
      }
      // This phone sent it but the sheet does not say TRUE: the status write
      // failed or the app was closed first. Offer to save it; never re-send.
      if (r.sentBefore && r.sheetStatus.toUpperCase() != 'TRUE') {
        r.sheetPending = true;
        owed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _rows = rows;
      _sheet = session;
      _done = 0;
      _total = 0;
      _ownsNumber.clear();
    });
    if (rows.isEmpty) {
      _snack('No recipients found in "${session.worksheetTitle}". Check the '
          'header row and the data.',
          err: true);
    } else if (load.warnings.isNotEmpty) {
      _snack(load.warnings.join(' '), err: true);
    } else if (owed > 0) {
      _snack('$owed ${owed == 1 ? 'email was' : 'emails were'} sent earlier '
          'but not marked TRUE in the sheet. Tap "Save $owed pending '
          '${owed == 1 ? 'status' : 'statuses'}".');
    } else if (before > 0) {
      _snack('$before ${before == 1 ? 'row was' : 'rows were'} already sent '
          'and will be skipped. Long-press a row to send it again.');
    }
  }

  /// A status write finished (saved or failed) for one recipient.
  void _onStatusOutcome(StatusOutcome o) {
    final r = o.update.receipt;
    if (o.saved) {
      r
        ..sheetStatus = o.update.sent ? 'TRUE' : 'FALSE'
        ..sheetPending = null
        ..sheetError = '';
    } else {
      r.sheetError = o.error!; // [sheetPending] keeps what is still owed
    }
    if (mounted) setState(() {});
  }

  int get _pendingStatuses =>
      _rows.where((r) => r.sheetPending != null && r.sourceRow != null).length;

  /// Writes the statuses that could not be saved earlier.
  Future<void> _savePendingStatuses() async {
    final sheet = _sheet;
    if (sheet == null || _sending || _savingStatus) return;
    final todo = _rows.where((r) => r.sheetPending != null).toList();
    if (todo.isEmpty) return;
    setState(() => _savingStatus = true);
    try {
      await sheet.prepareForSending();
      final sync = SheetStatusSync(sheet.writer, onOutcome: _onStatusOutcome);
      for (final r in todo) {
        sync.enqueue(r, r.sheetPending!);
      }
      await sync.flush();
      final left = todo.where((r) => r.sheetPending != null).length;
      _snack(
          left == 0
              ? '✓ Saved ${todo.length} '
                  '${todo.length == 1 ? 'status' : 'statuses'} to the sheet.'
              : '$left of ${todo.length} statuses still could not be saved. '
                  '${todo.firstWhere((r) => r.sheetPending != null).sheetError}',
          err: left > 0);
    } on SheetsApiException catch (e) {
      _snack('Google Sheets: ${e.message}', err: true);
    } on CredentialException catch (e) {
      _snack(e.message, err: true);
    } finally {
      if (mounted) setState(() => _savingStatus = false);
    }
  }

  /// Two rows with the same explicit receipt_no would issue one number
  /// twice: mark every such row invalid.
  static void _flagDuplicateNos(List<ReceiptData> rows) {
    final count = <int, int>{};
    for (final r in rows.where((r) => r.recNo > 0)) {
      count[r.recNo] = (count[r.recNo] ?? 0) + 1;
    }
    for (final r in rows) {
      if (r.recNo > 0 && count[r.recNo]! > 1) {
        r.status = SendStatus.invalid;
        r.error = 'duplicate receipt_no ${r.recNo}';
      }
    }
  }

  Future<bool> _confirm(String msg) async =>
      await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Yes, send')),
          ],
        ),
      ) ??
      false;

  Future<void> _downloadDemoCsv() async {
    try {
      final csvString =
          await rootBundle.loadString('assets/sample/pavan_bulk_sample.csv');
      final bytes = Uint8List.fromList(utf8.encode(csvString));
      final saved = await FileSaver.save(
        bytes: bytes,
        fileName: 'pavan_bulk_sample.csv',
        mimeType: 'text/csv',
      );
      if (saved) _snack('✓ Sample CSV saved');
    } catch (e) {
      _snack('Could not save the sample CSV: $e', err: true);
    }
  }

  Future<void> _previewRow(ReceiptData r) async {
    final s = await SettingsService.load();
    // Preview only: build a copy so the row's receipt no. is NOT locked in.
    // The real number is assigned at send time so bulk numbers stay
    // sequential.
    final d = r.copy()
      ..recNo = r.recNo == 0 ? SettingsService.peekReceiptNo(s) : r.recNo;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('Preview ${d.name}')),
        body: PdfPreview(
          canChangeOrientation: false,
          canChangePageFormat: false,
          build: (_) =>
              PdfService.buildReceiptPdf(d, signature: s.signatureBytes),
        ),
      ),
    ));
  }

  /// Long-press on an already-sent row: allow sending it again (same
  /// receipt no.).
  Future<void> _allowResend(ReceiptData r) async {
    if (_sending || r.status != SendStatus.sent) return;
    final ok = await _confirm('Send receipt #${r.recNo} to ${r.name} again?');
    if (!ok || !mounted) return;
    setState(() {
      r.status = SendStatus.ready;
      r.sentBefore = false;
      _ownsNumber.add(r);
    });
  }

  Future<void> _sendAll() async {
    final s = await SettingsService.load();
    if (!s.isConfigured) {
      _snack('Fill in the SMTP details on the Settings tab first.', err: true);
      return;
    }
    final todo = _rows
        .where(
            (r) => r.status == SendStatus.ready || r.status == SendStatus.error)
        .toList();
    if (todo.isEmpty) {
      _snack('No rows are ready to send.', err: true);
      return;
    }
    final used = todo
        .where((r) =>
            r.recNo > 0 &&
            r.recNo < s.nextReceiptNo &&
            !s.spareNos.contains(r.recNo) &&
            !_ownsNumber.contains(r))
        .map((r) => r.recNo)
        .toList();
    if (used.isNotEmpty) {
      final ok = await _confirm('${used.length} '
          '${used.length == 1 ? 'row uses a receipt number' : 'rows use receipt numbers'} '
          '(${used.take(5).join(', ')}${used.length > 5 ? ' …' : ''}) that may '
          'already have been issued. The next number is ${s.nextReceiptNo}. '
          'Send with these numbers anyway?\n\n'
          'Tip: leave receipt_no blank in the CSV to get automatic numbers.');
      if (!ok || !mounted) return;
    }
    // Google Sheets: before the first email, check that the spreadsheet and
    // tab are reachable and writable and that the status column exists, so
    // no status is lost for lack of access. Nothing is sent if this fails.
    final sheet = _source == _Source.sheets ? _sheet : null;
    if (sheet != null) {
      try {
        await sheet.prepareForSending();
      } on SheetsApiException catch (e) {
        _snack('Google Sheets: ${e.message} No emails were sent.', err: true);
        return;
      } on CredentialException catch (e) {
        _snack('${e.message} No emails were sent.', err: true);
        return;
      }
      if (!mounted) return;
    }
    final sync = sheet == null
        ? null
        : SheetStatusSync(sheet.writer, onOutcome: _onStatusOutcome);
    setState(() {
      _sending = true;
      _stop = false;
      _done = 0;
      _total = todo.length;
    });
    // Keep the screen on: a long bulk run must not be paused by the phone
    // sleeping (Android cuts network for sleeping apps). No permission needed.
    await WakelockPlus.enable().catchError((_) {});
    var sent = 0;
    String? abortReason;
    // Explicit receipt_no values of this batch: auto numbers must skip
    // them (CSV with blank + typed numbers, or a Single send meanwhile).
    final explicit = todo.where((r) => r.recNo > 0).map((r) => r.recNo).toSet();
    SettingsService.reserve(explicit);

    final sessions = <SmtpSession>[];
    SmtpSession newSession() {
      final x = SmtpSession(s);
      sessions.add(x);
      return x;
    }

    final first = newSession();
    var next = 0;
    final back = <ReceiptData>[]; // rows handed back by a refused connection
    var loginOk = false;
    bool keepGoing() =>
        !_stop &&
        abortReason == null &&
        (back.isNotEmpty || next < todo.length);
    ReceiptData take() => back.isNotEmpty ? back.removeAt(0) : todo[next++];

    /// Sends one row. Returns false when [session] should stop taking rows
    /// (an extra parallel connection the server refused the row was
    /// handed back to the others).
    Future<bool> sendOne(ReceiptData r, SmtpSession session) async {
      if (mounted) setState(() => r.status = SendStatus.sending);
      // Auto receipt no.: a blank row takes the next number (a spare one
      // first, then the live counter) → 794, 795, 796 … in sequence, never
      // shared with another connection or a Single send made meanwhile.
      final autoNo = r.recNo == 0;
      // What the sheet's status column is owed once this attempt is over:
      // true only after the mail was confirmed delivered, false only when it
      // was certainly NOT delivered. An uncertain outcome writes nothing.
      bool? statusToSave;
      try {
        if (autoNo) r.recNo = await SettingsService.takeReceiptNo();
        await session.sendReceipt(r);
        statusToSave = true;
        r.status = SendStatus.sent;
        r.error = '';
        _ownsNumber.remove(r);
        sent++;
        loginOk = true;
      } on NotSentException catch (e) {
        // Certainly not delivered: give the auto number back (it becomes a
        // spare if a later number was already taken, and is issued next).
        if (autoNo && r.recNo > 0 && !_ownsNumber.contains(r)) {
          await SettingsService.releaseReceiptNo(r.recNo);
          r.recNo = 0;
        }
        // An extra parallel connection refused while the others work (the
        // server allows fewer connections): hand the row back and let this
        // connection stop, instead of stopping the whole run.
        if (session != first &&
            session.delivered == 0 &&
            sent > 0 &&
            EmailService.isConfigError(e)) {
          r
            ..status = SendStatus.ready
            ..error = '';
          back.add(r);
          if (mounted) setState(() {});
          return false;
        }
        r.status = SendStatus.error;
        r.error = EmailService.friendlyError(e);
        statusToSave = false;
        // Wrong password / host / no internet / daily limit: every next row
        // would fail the same way (and repeated bad logins can lock Gmail).
        if (EmailService.isConfigError(e)) abortReason ??= r.error;
      } catch (e) {
        // The mail may have been delivered: keep its number so it is never
        // given to another resident. A retry re-sends this same receipt.
        r.status = SendStatus.error;
        r.error = 'Not sure whether the email was delivered '
            '(receipt #${r.recNo}). ${EmailService.friendlyError(e)} '
            'Check the Sent folder before sending again.';
        _ownsNumber.add(r);
        await SettingsService.bumpReceiptNo(r.recNo).catchError((_) {});
      }
      // Queued after the outcome is settled; saved in the background so the
      // sheet never slows the sending down.
      if (statusToSave != null) sync?.enqueue(r, statusToSave);
      if (mounted) setState(() => _done++);
      return true;
    }

    Future<void> worker(SmtpSession session) async {
      while (keepGoing()) {
        if (!await sendOne(take(), session)) return;
        // Small gap per connection so the SMTP server doesn't throttle us.
        if (keepGoing()) {
          await Future.delayed(const Duration(milliseconds: 250));
        }
      }
    }

    try {
      // Rows go one at a time until one email is delivered: that checks the
      // login once, so a wrong password fails one login instead of
      // [BulkScreen.parallel] at once.
      while (!loginOk && keepGoing()) {
        await sendOne(take(), first);
      }
      if (keepGoing()) {
        final extra =
            min(BulkScreen.parallel, todo.length - next + back.length) - 1;
        await Future.wait([
          worker(first),
          for (var i = 0; i < extra; i++) worker(newSession()),
        ]);
        // Rows handed back after the first connection had finished.
        await worker(first);
      }
    } finally {
      await Future.wait(sessions.map((x) => x.close()));
      await sync?.flush(); // never throws: failures are shown on the rows
      SettingsService.unreserve(explicit);
      await WakelockPlus.disable().catchError((_) {});
      for (final r in todo.where((r) => r.status == SendStatus.sending)) {
        r.status = SendStatus.ready;
      }
      if (mounted) setState(() => _sending = false);
    }
    final left = todo.where((r) => r.status == SendStatus.ready).length;
    final failed = todo.where((r) => r.status == SendStatus.error).length;
    // Emails that went out (or certainly did not) whose sheet status is not
    // saved yet: reported as such, never as failed emails.
    final unsaved = todo.where((r) => r.sheetPending != null).length;
    final sheetNote = unsaved == 0
        ? ''
        : ' $unsaved ${unsaved == 1 ? 'status' : 'statuses'} could not be '
            'saved to the Google Sheet (the emails themselves are not '
            'affected). Tap "Save $unsaved pending '
            '${unsaved == 1 ? 'status' : 'statuses'}".';
    if (abortReason != null) {
      _snack('Bulk send stopped. $abortReason$sheetNote', err: true);
    } else {
      _snack(
          'Bulk send finished: $sent sent, $failed failed'
          '${left > 0 ? ', $left not sent (stopped)' : ''}.$sheetNote',
          err: failed > 0 || unsaved > 0);
    }
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: err ? Colors.red.shade800 : Colors.green.shade700,
    ));
  }

  Widget _statusChip(ReceiptData r) {
    Chip chip(String text, [Color? bg]) => Chip(
        label: Text(text),
        backgroundColor: bg,
        visualDensity: VisualDensity.compact);
    const bad = Color(0xFFF9D6D6);
    switch (r.status) {
      case SendStatus.sent:
        return chip(
            r.sentBefore ? '✓ sent before' : '✓ sent', const Color(0xFFD9F2DF));
      case SendStatus.error:
        return chip('✗ error', bad);
      case SendStatus.invalid:
        return chip('✗ fix', bad);
      case SendStatus.sending:
        return chip('sending…');
      case SendStatus.ready:
        return chip('ready');
    }
  }

  /// Red line under a row explaining what is wrong.
  String _problem(ReceiptData r) => switch (r.status) {
        SendStatus.invalid =>
          'Fix: ${r.error.isNotEmpty ? r.error : r.invalidReason}',
        SendStatus.error => r.error,
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final ready = _rows
        .where(
            (r) => r.status == SendStatus.ready || r.status == SendStatus.error)
        .length;
    // Back during a bulk run would put the app in the background, where
    // Android may freeze or kill it half-way through.
    return PopScope(
      canPop: !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _snack('Bulk send is running. Tap Stop first.');
      },
      // One scroll view for header + rows: with a large font scale or a
      // small phone nothing gets pushed under the navigation bar.
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(
            child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            SegmentedButton<_Source>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                    value: _Source.sheets,
                    icon: Icon(Icons.table_chart),
                    label: Text('Google Sheets')),
                ButtonSegment(
                    value: _Source.csv,
                    icon: Icon(Icons.upload_file),
                    label: Text('CSV File')),
              ],
              selected: {_source},
              onSelectionChanged: _sending || _savingStatus
                  ? null
                  : (s) => _setSource(s.first),
            ),
            const SizedBox(height: 10),
            if (_source == _Source.sheets)
              SheetsSourcePanel(
                enabled: !_sending && !_savingStatus,
                onLoaded: _onSheetLoaded,
                onOpenSettings: widget.onOpenSettings,
              )
            else
              OutlinedButton.icon(
                icon: const Icon(Icons.upload_file),
                label: const Text('Choose CSV File'),
                onPressed: _sending ? null : _pickCsv,
              ),
            if (_rows.isEmpty && _source == _Source.csv) ...[
              const SizedBox(height: 8),
              Card(
                margin: EdgeInsets.zero,
                color: Theme.of(context)
                    .colorScheme
                    .surfaceContainerHighest
                    .withAlpha(76),
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                  side: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withAlpha(128),
                  ),
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Wrap: on a narrow phone / large font the button
                      // moves to its own line instead of overflowing.
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          const Text(
                            'CSV Format Guidelines:',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.download, size: 16),
                            label: const Text('Download Sample CSV',
                                style: TextStyle(fontSize: 12)),
                            onPressed: _downloadDemoCsv,
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      const Text(
                        '• Required columns: name, email, amount\n'
                        '• Optional columns: receipt_no, block, house_no, type, mode, cheque_no, transaction_number, bank_name, received_date, language, remarks\n'
                        '• Mode: Cash, Cheque, Online. If blank: Cheque when cheque_no is filled, Online when transaction_number or bank_name is filled, otherwise Cash.\n'
                        '• Block: A, B, C  •  Language: English, Gujarati, Hindi (blank = English)\n'
                        '• Type: Maintenance, Deposit, Transfer, Other. For Other, put the details in remarks (or write them in the type column).\n'
                        '• Values are not case-sensitive.',
                        style: TextStyle(
                            fontSize: 11.5, height: 1.4, color: Colors.black87),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            if (_rows.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                  '${_rows.length} ${_rows.length == 1 ? 'row' : 'rows'} • '
                  '$ready ready to send',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (_sending)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: LinearProgressIndicator(
                      value: _total == 0 ? 0 : _done / _total),
                ),
              if (_sending)
                OutlinedButton.icon(
                  icon: const Icon(Icons.stop),
                  label: Text(
                      _stop ? 'Stopping…' : 'Stop  ($_done / $_total done)'),
                  onPressed: _stop ? null : () => setState(() => _stop = true),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('Send All Emails'),
                  onPressed: _savingStatus ? null : _sendAll,
                ),
              if (!_sending && _pendingStatuses > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: OutlinedButton.icon(
                    icon: _savingStatus
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.cloud_upload),
                    label: Text('Save $_pendingStatuses pending '
                        '${_pendingStatuses == 1 ? 'status' : 'statuses'} '
                        'to the sheet'),
                    onPressed: _savingStatus ? null : _savePendingStatuses,
                  ),
                ),
            ],
          ]),
        )),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        _rows.isEmpty
            ? SliverToBoxAdapter(
                child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                    _source == _Source.csv
                        ? 'Upload a CSV file. You can download a sample file above.'
                        : 'Choose a spreadsheet and a worksheet tab, then tap '
                            '"Load recipients".',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey)),
              ))
            : SliverList.separated(
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = _rows[i];
                  final problem = _problem(r);
                  return ListTile(
                    dense: true,
                    onLongPress: () => _allowResend(r),
                    leading: CircleAvatar(
                        radius: 14,
                        child: Text('${i + 1}',
                            style: const TextStyle(fontSize: 12))),
                    title: Text('${r.name}  •  ₹${r.amount.round()}'
                        '${r.status == SendStatus.sent && r.recNo > 0 ? '  •  #${r.recNo}' : ''}'),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${r.email}  |  ${r.type == PaymentType.other && r.remark.isNotEmpty ? 'Other: ${r.remark}' : _typeLabel[r.type]}  |  ${_modeLabel[r.mode]}'
                              '${r.mode == PaymentMode.cheque && r.chqNo.isNotEmpty ? ' #${r.chqNo}' : ''}'
                              '${r.mode == PaymentMode.online && r.txnNo.isNotEmpty ? ' #${r.txnNo}' : ''}'
                              '  |  ${_langLabel[r.lang] ?? r.lang}',
                              style: const TextStyle(fontSize: 11.5)),
                          if (r.sourceRow != null)
                            Text(
                                'Sheet row ${r.sourceRow}  |  status: '
                                '${r.sheetStatus.isEmpty ? '—' : r.sheetStatus}'
                                '${r.sheetPending != null ? ' (saving ${r.sheetPending! ? 'TRUE' : 'FALSE'} pending)' : ''}',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.black54)),
                          if (r.sheetError.isNotEmpty)
                            Text(
                                r.status == SendStatus.sent
                                    ? 'Email sent, but its status could not be '
                                        'saved to the sheet: ${r.sheetError}'
                                    : 'Status could not be saved to the sheet: '
                                        '${r.sheetError}',
                                style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.orange.shade900)),
                          if (r.sentBefore)
                            const Text(
                                'Already sent. Long-press to send it again.',
                                style: TextStyle(
                                    fontSize: 11, color: Colors.green)),
                          if (problem.isNotEmpty)
                            Text(problem,
                                style: TextStyle(
                                    fontSize: 11, color: Colors.red.shade800)),
                        ]),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      IconButton(
                        icon: const Icon(Icons.visibility, size: 20),
                        onPressed: () => _previewRow(r),
                      ),
                      _statusChip(r),
                    ]),
                  );
                },
              ),
      ]),
    );
  }
}
