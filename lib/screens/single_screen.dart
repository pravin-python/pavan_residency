import 'package:flutter/material.dart';
import 'package:printing/printing.dart';

import '../models/receipt_data.dart';
import '../services/csv_service.dart';
import '../services/email_service.dart';
import '../services/pdf_service.dart';
import '../services/settings_service.dart';

class SingleScreen extends StatefulWidget {
  const SingleScreen({super.key});

  @override
  State<SingleScreen> createState() => _SingleScreenState();
}

class _SingleScreenState extends State<SingleScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _block = TextEditingController();
  final _house = TextEditingController();
  final _amount = TextEditingController();
  final _chqNo = TextEditingController();
  final _chqBank = TextEditingController();
  final _recNo = TextEditingController();

  String _lang = 'gu';
  PaymentType _type = PaymentType.maintenance;
  DateTime _date = DateTime.now();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    SettingsService.load().then((s) {
      if (mounted) setState(() => _recNo.text = '${s.nextReceiptNo}');
    });
  }

  ReceiptData _collect() => ReceiptData(
        lang: _lang,
        name: _name.text.trim(),
        email: _email.text.trim(),
        block: _block.text.trim(),
        house: _house.text.trim(),
        amount: double.tryParse(_amount.text) ?? 0,
        type: _type,
        chqNo: _chqNo.text.trim(),
        chqBank: _chqBank.text.trim(),
        recNo: int.tryParse(_recNo.text) ?? 1,
        date:
            '${_date.day.toString().padLeft(2, '0')}-${_date.month.toString().padLeft(2, '0')}-${_date.year}',
      );

  Future<void> _preview() async {
    if (!_form.currentState!.validate()) return;
    final d = _collect();
    final s = await SettingsService.load();
    if (!mounted) return;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text('Receipt #${d.recNo} Preview')),
        body: PdfPreview(
          canChangeOrientation: false,
          canChangePageFormat: false,
          build: (_) =>
              PdfService.buildReceiptPdf(d, signature: s.signatureBytes),
        ),
      ),
    ));
  }

  Future<void> _send() async {
    if (!_form.currentState!.validate()) return;
    final d = _collect();
    final s = await SettingsService.load();
    if (!s.isConfigured) {
      _snack('Pehle Settings tab mein SMTP details bharo!', err: true);
      return;
    }
    setState(() => _sending = true);
    try {
      await EmailService.sendReceipt(s, d);
      _snack('✓ Email sent to ${d.email}');
      final ns = await SettingsService.load();
      _recNo.text = '${ns.nextReceiptNo}';
    } catch (e) {
      _snack('✗ Failed: $e', err: true);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: err ? Colors.red.shade800 : Colors.green.shade700,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Form(
      key: _form,
      child: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name *'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email *'),
                validator: (v) =>
                    (v == null || !v.contains('@')) ? 'Valid email' : null,
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _block,
                decoration: const InputDecoration(labelText: 'Block No.'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _house,
                decoration:
                    const InputDecoration(labelText: 'House / Shed No.'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _amount,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Amount (Rs.) *'),
                validator: (v) =>
                    ((double.tryParse(v ?? '') ?? 0) <= 0) ? '> 0' : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<PaymentType>(
                value: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(
                      value: PaymentType.maintenance,
                      child: Text('Maintenance')),
                  DropdownMenuItem(
                      value: PaymentType.deposit,
                      child: Text('Maintenance Deposit')),
                  DropdownMenuItem(
                      value: PaymentType.transfer, child: Text('Transfer Fee')),
                  DropdownMenuItem(
                      value: PaymentType.other, child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: TextFormField(
                controller: _chqNo,
                decoration: const InputDecoration(
                    labelText: 'Cheque No. (blank = Cash)'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _chqBank,
                decoration: const InputDecoration(labelText: 'Cheque Bank'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                value: _lang,
                decoration: const InputDecoration(labelText: 'Language'),
                items: const [
                  DropdownMenuItem(value: 'gu', child: Text('ગુજરાતી')),
                  DropdownMenuItem(value: 'hi', child: Text('हिन्दी')),
                  DropdownMenuItem(value: 'en', child: Text('English')),
                ],
                onChanged: (v) => setState(() => _lang = v!),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: TextFormField(
                controller: _recNo,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Receipt No.'),
              ),
            ),
          ]),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            icon: const Icon(Icons.calendar_today, size: 18),
            label: Text(
                'Date: ${CsvService.normDate('${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}')}'),
            onPressed: () async {
              final p = await showDatePicker(
                context: context,
                initialDate: _date,
                firstDate: DateTime(2020),
                lastDate: DateTime(2035),
              );
              if (p != null) setState(() => _date = p);
            },
          ),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                icon: const Icon(Icons.visibility),
                label: const Text('Preview'),
                onPressed: _sending ? null : _preview,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                icon: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.send),
                label: Text(_sending ? 'Sending…' : 'Send Email'),
                onPressed: _sending ? null : _send,
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
