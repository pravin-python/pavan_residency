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
  final _house = TextEditingController();
  final _amount = TextEditingController();
  final _chqNo = TextEditingController();
  final _chqBank = TextEditingController();
  final _txnNo = TextEditingController();
  final _remark = TextEditingController();
  final _recNo = TextEditingController();

  String _lang = 'gu';
  String? _block;
  PaymentType _type = PaymentType.maintenance;
  PaymentMode _mode = PaymentMode.cash;
  DateTime _date = DateTime.now();
  bool _sending = false;

  /// The auto receipt no. last shown in the field. While the field still
  /// shows it (or is blank) the number is taken from the live counter at
  /// send time; a different number typed by the user is used as-is.
  int? _suggestedNo;

  @override
  void initState() {
    super.initState();
    _refreshRecNo();
    // A Bulk send or a Settings change moves the counter: keep the field
    // current instead of re-using a stale number.
    SettingsService.changes.addListener(_refreshRecNo);
  }

  @override
  void dispose() {
    SettingsService.changes.removeListener(_refreshRecNo);
    for (final c in [
      _name,
      _email,
      _house,
      _amount,
      _chqNo,
      _chqBank,
      _txnNo,
      _remark,
      _recNo,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool get _recNoIsAuto {
    final t = _recNo.text.trim();
    return t.isEmpty || t == '$_suggestedNo';
  }

  Future<void> _refreshRecNo() async {
    final s = await SettingsService.load();
    if (!mounted || !_recNoIsAuto) return;
    setState(() {
      _suggestedNo = s.nextReceiptNo;
      _recNo.text = '${s.nextReceiptNo}';
    });
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

  ReceiptData _collect() => ReceiptData(
        lang: _lang,
        name: _name.text.trim(),
        email: _email.text.trim(),
        block: _block ?? '',
        house: _house.text.trim(),
        amount: ReceiptData.parseAmount(_amount.text),
        type: _type,
        remark: _type == PaymentType.other ? _remark.text.trim() : '',
        mode: _mode,
        chqNo: _mode == PaymentMode.cheque ? _chqNo.text.trim() : '',
        chqBank: _mode == PaymentMode.cash ? '' : _chqBank.text.trim(),
        txnNo: _mode == PaymentMode.online ? _txnNo.text.trim() : '',
        recNo: int.tryParse(_recNo.text.trim()) ?? _suggestedNo ?? 0,
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
    final auto = _recNoIsAuto;
    if (!auto && d.recNo < s.nextReceiptNo) {
      final ok = await _confirm('Receipt #${d.recNo} pehle issue ho chuka ho '
          'sakta hai (next no. ${s.nextReceiptNo} hai). Phir bhi isi number '
          'se bhejna hai?');
      if (!ok || !mounted) return;
    }
    setState(() => _sending = true);
    // A typed number: keep it away from auto numbers (a Bulk run going on
    // at the same time) until this send is done.
    final typed = auto ? null : d.recNo;
    if (typed != null) SettingsService.reserve([typed]);
    try {
      if (auto) {
        // Reserve the auto number now so a Bulk send running at the same
        // time can't take the same one.
        try {
          d.recNo = await SettingsService.takeReceiptNo();
        } catch (e) {
          _snack('✗ Receipt no. save nahi hua: $e', err: true);
          return;
        }
      }
      try {
        await EmailService.sendReceipt(s, d);
        _snack('✓ Receipt #${d.recNo} sent to ${d.email}');
        _recNo.clear(); // next auto number (via _refreshRecNo)
        await _refreshRecNo();
      } on NotSentException catch (e) {
        // Certainly not delivered: the reserved number can be reused.
        if (auto) await SettingsService.releaseReceiptNo(d.recNo);
        _snack('✗ Failed: ${EmailService.friendlyError(e)}', err: true);
      } catch (e) {
        // May have been delivered: count #recNo as used so it is never
        // given to anyone else.
        await SettingsService.bumpReceiptNo(d.recNo).catchError((_) {});
        _snack(
            '✗ Pata nahi mail gaya ya nahi (receipt #${d.recNo}) — '
            '${EmailService.friendlyError(e)}. Inbox / Sent check karo.',
            err: true);
      }
    } finally {
      if (typed != null) SettingsService.unreserve([typed]);
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
                validator: (v) => ReceiptData(email: v ?? '').emailValid
                    ? null
                    : 'Valid email',
              ),
            ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _block,
                decoration: const InputDecoration(labelText: 'Block No. *'),
                items: [
                  for (final b in ReceiptData.blocks)
                    DropdownMenuItem(value: b, child: Text(b)),
                ],
                onChanged: (v) => setState(() => _block = v),
                validator: (v) => v == null ? 'Select block' : null,
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
                    ReceiptData(amount: ReceiptData.parseAmount(v ?? ''))
                            .amountValid
                        ? null
                        : 'Whole rupees > 0',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: DropdownButtonFormField<PaymentType>(
                isExpanded: true,
                initialValue: _type,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(
                      value: PaymentType.maintenance,
                      child: Text('Maintenance')),
                  DropdownMenuItem(
                      value: PaymentType.deposit, child: Text('Deposit')),
                  DropdownMenuItem(
                      value: PaymentType.transfer, child: Text('Transfer Fee')),
                  DropdownMenuItem(
                      value: PaymentType.other, child: Text('Other')),
                ],
                onChanged: (v) => setState(() => _type = v!),
              ),
            ),
          ]),
          if (_type == PaymentType.other) ...[
            const SizedBox(height: 12),
            TextFormField(
              controller: _remark,
              maxLength: ReceiptData.maxRemark,
              decoration: const InputDecoration(
                labelText: 'Other details * (receipt mein chhapega)',
                hintText: 'e.g. Parking charges, Late fee',
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
          ],
          const SizedBox(height: 12),
          DropdownButtonFormField<PaymentMode>(
            isExpanded: true,
            initialValue: _mode,
            decoration: const InputDecoration(labelText: 'Payment Mode'),
            items: const [
              DropdownMenuItem(value: PaymentMode.cash, child: Text('Cash')),
              DropdownMenuItem(
                  value: PaymentMode.cheque, child: Text('Cheque')),
              DropdownMenuItem(
                  value: PaymentMode.online,
                  child: Text('Online (UPI / NEFT / IMPS)')),
            ],
            onChanged: (v) => setState(() => _mode = v!),
          ),
          if (_mode != PaymentMode.cash) ...[
            const SizedBox(height: 12),
            Row(children: [
              Expanded(
                child: _mode == PaymentMode.cheque
                    ? TextFormField(
                        key: const ValueKey('chqNo'),
                        controller: _chqNo,
                        keyboardType: TextInputType.number,
                        decoration:
                            const InputDecoration(labelText: 'Cheque No. *'),
                        validator: (v) =>
                            (v == null || v.trim().isEmpty) ? 'Required' : null,
                      )
                    : TextFormField(
                        key: const ValueKey('txnNo'),
                        controller: _txnNo,
                        decoration:
                            const InputDecoration(labelText: 'Transaction No.'),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextFormField(
                  controller: _chqBank,
                  decoration: const InputDecoration(labelText: 'Bank Name'),
                ),
              ),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: _lang,
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
