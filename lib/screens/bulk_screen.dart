import 'dart:convert';
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
import '../utils/file_saver.dart';

class BulkScreen extends StatefulWidget {
  const BulkScreen({super.key});

  @override
  State<BulkScreen> createState() => _BulkScreenState();
}

class _BulkScreenState extends State<BulkScreen> {
  List<ReceiptData> _rows = [];
  bool _sending = false;
  int _done = 0;
  int _total = 0;
  bool _stop = false;

  /// Rows whose send failed after the mail may already have gone out: they
  /// keep their receipt no. (a retry re-sends the same receipt).
  final _uncertain = <ReceiptData>{};

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
      // Already mailed from this phone (e.g. an interrupted bulk run, then
      // the same CSV loaded again): don't send those a second time.
      var before = 0;
      for (final r in rows) {
        if (r.status != SendStatus.ready) continue;
        final no = await SentLog.sentNo(r);
        if (no != null) {
          r
            ..status = SendStatus.sent
            ..recNo = no
            ..sentBefore = true;
          before++;
        }
      }
      if (!mounted) return;
      setState(() {
        _rows = rows;
        _done = 0;
        _total = 0;
        _uncertain.clear();
      });
      if (rows.isEmpty) {
        _snack('CSV mein koi row nahi mili — header + data check karo',
            err: true);
      } else if (before > 0) {
        _snack('$before row pehle hi bheji ja chuki hain — woh skip hongi. '
            'Dobara bhejni ho to row par long-press karo.');
      }
    } catch (e) {
      _snack('CSV read nahi hui: $e', err: true);
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
        r.error = 'receipt_no ${r.recNo} duplicate';
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
                child: const Text('Haan, bhejo')),
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
      if (saved) _snack('✓ Demo CSV saved');
    } catch (e) {
      _snack('Error downloading demo CSV: $e', err: true);
    }
  }

  Future<void> _previewRow(ReceiptData r) async {
    final s = await SettingsService.load();
    // Preview only: build a copy so the row's receipt no. is NOT locked in.
    // The real number is assigned at send time so bulk stays 1++ sequential.
    final d = r.copy()..recNo = r.recNo == 0 ? s.nextReceiptNo : r.recNo;
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('Preview — ${d.name}')),
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
    final ok = await _confirm('${r.name} ko receipt #${r.recNo} dobara '
        'bhejni hai?');
    if (!ok || !mounted) return;
    setState(() {
      r.status = SendStatus.ready;
      r.sentBefore = false;
      _uncertain.add(r); // keeps its number, no "used number" warning
    });
  }

  Future<void> _sendAll() async {
    final s = await SettingsService.load();
    if (!s.isConfigured) {
      _snack('Pehle Settings mein SMTP details bharo!', err: true);
      return;
    }
    final todo = _rows
        .where(
            (r) => r.status == SendStatus.ready || r.status == SendStatus.error)
        .toList();
    if (todo.isEmpty) {
      _snack('Koi row ready nahi hai', err: true);
      return;
    }
    final used = todo
        .where((r) =>
            r.recNo > 0 && r.recNo < s.nextReceiptNo && !_uncertain.contains(r))
        .map((r) => r.recNo)
        .toList();
    if (used.isNotEmpty) {
      final ok = await _confirm('${used.length} row ke receipt no. '
          '(${used.take(5).join(', ')}${used.length > 5 ? ' …' : ''}) pehle '
          'issue ho chuke ho sakte hain — next no. ${s.nextReceiptNo} hai. '
          'Phir bhi inhi numbers se bhejna hai?\n\n'
          '(Auto number ke liye CSV mein receipt_no khali chhodo.)');
      if (!ok || !mounted) return;
    }
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
    try {
      for (final r in todo) {
        if (_stop) break;
        if (mounted) setState(() => r.status = SendStatus.sending);
        final fresh = await SettingsService.load();
        // Auto receipt no.: a blank row reserves the next number from the
        // live counter → 794, 795, 796 … (1++), never shared with a Single
        // send made meanwhile.
        final autoNo = r.recNo == 0;
        if (autoNo) r.recNo = await SettingsService.takeReceiptNo();
        try {
          await EmailService.sendReceipt(fresh, r);
          r.status = SendStatus.sent;
          r.error = '';
          _uncertain.remove(r);
          sent++;
        } on NotSentException catch (e) {
          r.status = SendStatus.error;
          r.error = EmailService.friendlyError(e);
          // Certainly not delivered: give the auto number back so a retry
          // takes a fresh one (no duplicate, no gap).
          if (autoNo && !_uncertain.contains(r)) {
            await SettingsService.releaseReceiptNo(r.recNo);
            r.recNo = 0;
          }
          // Wrong password / host / no internet: every next row would fail
          // the same way (and repeated bad logins can lock the Gmail).
          if (EmailService.isConfigError(e)) abortReason = r.error;
        } catch (e) {
          // The mail may have been delivered: keep its number so it is
          // never given to another resident. A retry re-sends this receipt.
          r.status = SendStatus.error;
          r.error = 'Pata nahi mail gaya ya nahi (receipt #${r.recNo}) — '
              '${EmailService.friendlyError(e)}';
          _uncertain.add(r);
        }
        if (mounted) setState(() => _done++);
        if (abortReason != null) break;
        // Small gap so SMTP servers don't rate-limit us.
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    } finally {
      await WakelockPlus.disable().catchError((_) {});
      for (final r in todo.where((r) => r.status == SendStatus.sending)) {
        r.status = SendStatus.ready;
      }
      if (mounted) setState(() => _sending = false);
    }
    final left = todo.where((r) => r.status == SendStatus.ready).length;
    final failed = todo.where((r) => r.status == SendStatus.error).length;
    if (abortReason != null) {
      _snack('Bulk ruk gaya: $abortReason (Settings check karo)', err: true);
    } else {
      _snack(
          'Bulk: $sent sent, $failed failed'
          '${left > 0 ? ', $left baaki (stopped)' : ''}',
          err: failed > 0);
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
            r.sentBefore ? '✓ earlier' : '✓ sent', const Color(0xFFD9F2DF));
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
    final valid = _rows.where((r) => r.status != SendStatus.invalid).length;
    // Back during a bulk run would put the app in the background, where
    // Android may freeze or kill it half-way through.
    return PopScope(
      canPop: !_sending,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _snack('Bulk send chal raha hai — pehle Stop dabao');
      },
      // One scroll view for header + rows: with a large font scale or a
      // small phone nothing gets pushed under the navigation bar.
      child: CustomScrollView(slivers: [
        SliverToBoxAdapter(
            child: Padding(
          padding: const EdgeInsets.all(14),
          child:
              Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            OutlinedButton.icon(
              icon: const Icon(Icons.upload_file),
              label: const Text('CSV File Choose Karo'),
              onPressed: _sending ? null : _pickCsv,
            ),
            if (_rows.isEmpty) ...[
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
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Expanded(
                            child: Text(
                              'CSV Format Guidelines:',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold, fontSize: 13),
                            ),
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.download, size: 16),
                            label: const Text('Download Demo CSV',
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
                        '• Required columns: name, email, block, house_no, amount, language, type\n'
                        '• Optional columns: receipt_no, mode, cheque_no, transaction_number, bank_name, received_date, remarks\n'
                        '• Mode: cash, cheque, online (blank = cheque_no ho to Cheque, transaction_number ho to Online, warna Cash)\n'
                        '• Block: A, B, C  •  Languages: english, gujarati, hindi\n'
                        '• Types: maintenance, deposit, transfer, other (details remarks column mein, ya type mein hi text likho)\n'
                        '• Capital / small letters dono chalenge',
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
              Text('${_rows.length} rows • $valid ready',
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
                      _stop ? 'Stopping…' : 'Stop  ($_done / $_total sent)'),
                  onPressed: _stop ? null : () => setState(() => _stop = true),
                )
              else
                FilledButton.icon(
                  icon: const Icon(Icons.send),
                  label: const Text('Send All Emails'),
                  onPressed: _sendAll,
                ),
            ],
          ]),
        )),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        _rows.isEmpty
            ? const SliverToBoxAdapter(
                child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                    'CSV upload karo — sample/demo file download option upar hai',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey)),
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
                        '${r.status == SendStatus.sent ? '  •  #${r.recNo}' : ''}'),
                    subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                              '${r.email}  |  ${r.type == PaymentType.other && r.remark.isNotEmpty ? 'other: ${r.remark}' : r.type.name}  |  ${r.mode.name}'
                              '${r.mode == PaymentMode.cheque && r.chqNo.isNotEmpty ? ' #${r.chqNo}' : ''}'
                              '${r.mode == PaymentMode.online && r.txnNo.isNotEmpty ? ' #${r.txnNo}' : ''}'
                              '  |  ${r.lang}',
                              style: const TextStyle(fontSize: 11.5)),
                          if (r.sentBefore)
                            const Text(
                                'Pehle bheja ja chuka — long-press = dobara',
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
