import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../models/receipt_data.dart';
import '../services/csv_service.dart';
import '../services/email_service.dart';
import '../services/pdf_service.dart';
import '../services/settings_service.dart';

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

  Future<void> _previewRow(ReceiptData r) async {
    final s = await SettingsService.load();
    final d = r..recNo = r.recNo == 0 ? s.nextReceiptNo : r.recNo;
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
      try {
        final fresh = await SettingsService.load();
        if (r.recNo == 0) r.recNo = fresh.nextReceiptNo;
        await EmailService.sendReceipt(fresh, r);
        r.status = SendStatus.sent;
      } catch (e) {
        r.status = SendStatus.error;
        r.error = '$e';
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
          const SizedBox(height: 4),
          const Text(
            'Columns: name, email, block, house_no, amount, cheque_no, '
            'cheque_bank, language, type  (optional: receipt_no, date)',
            style: TextStyle(fontSize: 11, color: Colors.grey),
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
                child: Text('CSV upload karo — sample assets/sample mein hai',
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
                    title: Text('${r.name}  •  ₹${r.amount.round()}'),
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
