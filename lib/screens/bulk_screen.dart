import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:printing/printing.dart';

import '../models/receipt_data.dart';
import '../services/csv_service.dart';
import '../services/email_service.dart';
import '../services/pdf_service.dart';
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

  Future<void> _pickCsv() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['csv'],
      withData: true,
    );
    final bytes = res?.files.single.bytes;
    if (bytes == null) return;
    setState(() {
      _rows = CsvService.parse(bytes);
      _done = 0;
    });
  }

  Future<void> _downloadDemoCsv() async {
    try {
      final csvString = await rootBundle.loadString('assets/sample/pavan_bulk_sample.csv');
      final bytes = Uint8List.fromList(utf8.encode(csvString));
      await FileSaver.save(
        bytes: bytes,
        fileName: 'pavan_bulk_sample.csv',
        mimeType: 'text/csv',
      );
      _snack('✓ Demo CSV downloaded successfully');
    } catch (e) {
      _snack('Error downloading demo CSV: $e', err: true);
    }
  }

  Future<void> _previewRow(ReceiptData r) async {
    final s = await SettingsService.load();
    // Preview only: build a copy so the row's receipt no. is NOT locked in.
    // The real number is assigned at send time so bulk stays 1++ sequential.
    final d = ReceiptData(
      lang: r.lang,
      name: r.name,
      email: r.email,
      block: r.block,
      house: r.house,
      amount: r.amount,
      type: r.type,
      chqNo: r.chqNo,
      chqBank: r.chqBank,
      recNo: r.recNo == 0 ? s.nextReceiptNo : r.recNo,
      date: r.date,
    );
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

  Future<void> _sendAll() async {
    final s = await SettingsService.load();
    if (!s.isConfigured) {
      _snack('Pehle Settings mein SMTP details bharo!', err: true);
      return;
    }
    final todo = _rows
        .where((r) =>
            r.status == SendStatus.ready || r.status == SendStatus.error)
        .toList();
    if (todo.isEmpty) {
      _snack('Koi row ready nahi hai', err: true);
      return;
    }
    setState(() {
      _sending = true;
      _done = 0;
    });
    for (final r in todo) {
      setState(() => r.status = SendStatus.sending);
      final fresh = await SettingsService.load();
      // Auto receipt no.: a blank row takes the live counter, which bumps
      // +1 after every successful send → 794, 795, 796 … (1++).
      final autoNo = r.recNo == 0;
      if (autoNo) r.recNo = fresh.nextReceiptNo;
      try {
        await EmailService.sendReceipt(fresh, r);
        r.status = SendStatus.sent;
      } catch (e) {
        r.status = SendStatus.error;
        r.error = '$e';
        // Release the auto number so a later retry picks a fresh one
        // (no duplicate, no gap in the sequence).
        if (autoNo) r.recNo = 0;
      }
      setState(() => _done++);
      // Small gap so SMTP servers don't rate-limit us.
      await Future.delayed(const Duration(milliseconds: 1200));
    }
    setState(() => _sending = false);
    final sent = _rows.where((r) => r.status == SendStatus.sent).length;
    _snack('Bulk complete: $sent sent, ${todo.length - sent} failed');
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: err ? Colors.red.shade800 : Colors.green.shade700,
    ));
  }

  Widget _statusChip(ReceiptData r) {
    switch (r.status) {
      case SendStatus.sent:
        return const Chip(
            label: Text('✓ sent'),
            backgroundColor: Color(0xFFD9F2DF),
            visualDensity: VisualDensity.compact);
      case SendStatus.error:
        return Tooltip(
            message: r.error,
            child: const Chip(
                label: Text('✗ error'),
                backgroundColor: Color(0xFFF9D6D6),
                visualDensity: VisualDensity.compact));
      case SendStatus.invalid:
        return const Chip(
            label: Text('missing data'),
            backgroundColor: Color(0xFFF9D6D6),
            visualDensity: VisualDensity.compact);
      case SendStatus.sending:
        return const Chip(
            label: Text('sending…'), visualDensity: VisualDensity.compact);
      default:
        return const Chip(
            label: Text('ready'), visualDensity: VisualDensity.compact);
    }
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        _rows.where((r) => r.status != SendStatus.invalid).length;
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.upload_file),
            label: const Text('CSV File Choose Karo'),
            onPressed: _sending ? null : _pickCsv,
          ),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            color: Theme.of(context).colorScheme.surfaceContainerHighest.withAlpha(76),
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: Theme.of(context).colorScheme.outlineVariant.withAlpha(128),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Expanded(
                        child: Text(
                          'CSV Format Guidelines:',
                          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                        ),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.download, size: 16),
                        label: const Text('Download Demo CSV', style: TextStyle(fontSize: 12)),
                        onPressed: _downloadDemoCsv,
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    '• Required columns: name, email, block, house_no, amount, language, type\n'
                    '• Optional columns: cheque_no, cheque_bank, receipt_no, date\n'
                    '• Languages: english, gujarati, hindi\n'
                    '• Types: maintenance, deposit, transfer, other',
                    style: TextStyle(fontSize: 11.5, height: 1.4, color: Colors.black87),
                  ),
                ],
              ),
            ),
          ),
          if (_rows.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('${_rows.length} rows • $valid ready',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (_sending)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: LinearProgressIndicator(
                    value: _rows.isEmpty ? 0 : _done / _rows.length),
              ),
            FilledButton.icon(
              icon: const Icon(Icons.send),
              label: Text(_sending ? 'Sending $_done…' : 'Send All Emails'),
              onPressed: _sending ? null : _sendAll,
            ),
          ],
        ]),
      ),
      const Divider(height: 1),
      Expanded(
        child: _rows.isEmpty
            ? const Center(
                child: Text('CSV upload karo — sample/demo file download option upar hai',
                    style: TextStyle(color: Colors.grey)))
            : ListView.separated(
                itemCount: _rows.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (_, i) {
                  final r = _rows[i];
                  return ListTile(
                    dense: true,
                    leading: CircleAvatar(
                        radius: 14,
                        child: Text('${i + 1}',
                            style: const TextStyle(fontSize: 12))),
                    title: Text('${r.name}  •  ₹${r.amount.round()}'
                        '${r.status == SendStatus.sent ? '  •  #${r.recNo}' : ''}'),
                    subtitle: Text(
                        '${r.email}  |  ${r.type.name}  |  ${r.lang}',
                        style: const TextStyle(fontSize: 11.5)),
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
      ),
    ]);
  }
}
