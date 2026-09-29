import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../services/settings_service.dart';
import '../services/signature_image.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _senderName = TextEditingController();
  final _senderEmail = TextEditingController();
  final _subject = TextEditingController();
  final _nextNo = TextEditingController();

  bool _ssl = true;
  bool _attachPdf = true;
  bool _hidePass = true;
  AppSettings? _s;

  /// Next receipt no. last shown in the field. Save only changes the counter
  /// when the user edited the field — otherwise sends made since this screen
  /// loaded would be rolled back and numbers reused.
  int? _shownNextNo;

  @override
  void initState() {
    super.initState();
    SettingsService.load().then((s) {
      if (!mounted) return;
      setState(() {
        _s = s;
        _host.text = s.host;
        _port.text = '${s.port}';
        _user.text = s.username;
        _pass.text = s.password;
        _senderName.text = s.senderName;
        _senderEmail.text = s.senderEmail;
        _subject.text = s.subjectTpl;
        _nextNo.text = '${s.nextReceiptNo}';
        _shownNextNo = s.nextReceiptNo;
        _ssl = s.ssl;
        _attachPdf = s.attachPdf;
      });
    });
    SettingsService.changes.addListener(_syncNextNo);
  }

  @override
  void dispose() {
    SettingsService.changes.removeListener(_syncNextNo);
    for (final c in [
      _host,
      _port,
      _user,
      _pass,
      _senderName,
      _senderEmail,
      _subject,
      _nextNo,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Receipts sent from the other tabs move the counter: show the live value
  /// unless the user is editing the field.
  void _syncNextNo() {
    final s = _s;
    if (s == null || !mounted) return;
    if (_nextNo.text.trim() == '$_shownNextNo' &&
        s.nextReceiptNo != _shownNextNo) {
      setState(() {
        _shownNextNo = s.nextReceiptNo;
        _nextNo.text = '${s.nextReceiptNo}';
      });
    }
  }

  Future<void> _pickSignature() async {
    final s = _s;
    if (s == null) return; // settings still loading
    final FilePickerResult? res;
    try {
      res = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png'],
        withData: true,
      );
    } catch (e) {
      _snack('Could not open the file picker: $e', err: true);
      return;
    }
    final raw = res?.files.single.bytes;
    if (raw == null) return; // cancelled
    final sig = await SignatureImage.prepare(raw);
    if (!mounted) return;
    if (sig == null) {
      _snack('This image could not be read. Choose a JPG or PNG file.',
          err: true);
      return;
    }
    setState(() {
      s.signatureB64 = base64Encode(sig.bytes);
      s.signatureMime = sig.mime;
    });
    // Persist right away so the preview/sent receipts and the next app
    // start agree with what is shown here.
    await SettingsService.save(s);
    _snack('✓ Signature saved');
  }

  Future<void> _removeSignature() async {
    final s = _s;
    if (s == null) return;
    setState(() => s.signatureB64 = '');
    await SettingsService.save(s);
  }

  void _snack(String msg, {bool err = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: err ? Colors.red.shade800 : Colors.green,
    ));
  }

  Future<void> _save() async {
    // Never a fresh AppSettings(): that would wipe the live counter.
    final s = _s ?? await SettingsService.load();
    final typedNo = int.tryParse(_nextNo.text.trim());
    final changedNo = typedNo != null && typedNo > 0 && typedNo != _shownNextNo;
    // Until confirmed once (new install / reinstall — backups are off) the
    // counter is only the default: make the user check it.
    if (!mounted) return;
    if (!s.counterConfirmed) {
      final no = changedNo ? typedNo : s.nextReceiptNo;
      final ok = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('Check the Next Receipt No.'),
              content: Text('The next receipt will be #$no.\n\n'
                  'This must be one more than the last receipt number used '
                  '(on the old phone or in the receipt book), otherwise '
                  'numbers will repeat. Is this correct?'),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('No, change it')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Yes, it is correct')),
              ],
            ),
          ) ??
          false;
      if (!ok || !mounted) return;
    }
    s.host = _host.text.trim();
    s.port = int.tryParse(_port.text) ?? 465;
    s.ssl = _ssl;
    s.username = _user.text.trim();

    String cleanedPassword = _pass.text;
    // Auto-clean Gmail App Passwords (which are 16 letters, generated as 4 blocks of 4 separated by spaces)
    if (s.host.toLowerCase().contains('gmail') ||
        s.username.toLowerCase().contains('gmail')) {
      cleanedPassword = cleanedPassword.replaceAll(' ', '');
    }
    s.password = cleanedPassword;

    s.senderName = _senderName.text.trim();
    s.senderEmail = _senderEmail.text.trim();
    s.subjectTpl = _subject.text.trim().isEmpty
        ? 'Pavan Residency Receipt #{no}'
        : _subject.text.trim();
    s.attachPdf = _attachPdf;
    if (changedNo) {
      s.nextReceiptNo = typedNo; // deliberately changed by the user
      // Spares at or above the new counter would be issued twice.
      s.spareNos.removeWhere((n) => n >= typedNo);
    }
    s.counterConfirmed = true;
    await SettingsService.save(s);
    _shownNextNo = s.nextReceiptNo;
    _nextNo.text = '${s.nextReceiptNo}';
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('✓ Settings saved'), backgroundColor: Colors.green));
  }

  @override
  Widget build(BuildContext context) {
    final sig = _s?.signatureBytes;
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        const Text('SMTP Settings',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 10),
        TextField(
            controller: _host,
            decoration: const InputDecoration(
                labelText: 'SMTP Host *', hintText: 'smtp.gmail.com')),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: TextField(
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                    labelText: 'Port', hintText: '465 (SSL) / 587')),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('SSL', style: TextStyle(fontSize: 13)),
              subtitle: Text(_ssl ? 'Port 465' : 'Port 587 (STARTTLS)',
                  style: const TextStyle(fontSize: 11)),
              value: _ssl,
              onChanged: (v) => setState(() {
                _ssl = v;
                _port.text = v ? '465' : '587';
              }),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        TextField(
            controller: _user,
            decoration: const InputDecoration(
                labelText: 'Username / Email *',
                hintText: 'yourname@gmail.com')),
        const SizedBox(height: 12),
        TextField(
          controller: _pass,
          obscureText: _hidePass,
          decoration: InputDecoration(
            labelText: 'Password / App Password *',
            helperText:
                'Gmail: turn on 2-Step Verification, then create an App Password',
            suffixIcon: IconButton(
              icon: Icon(_hidePass ? Icons.visibility : Icons.visibility_off),
              onPressed: () => setState(() => _hidePass = !_hidePass),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
              child: TextField(
                  controller: _senderName,
                  decoration: const InputDecoration(labelText: 'Sender Name'))),
          const SizedBox(width: 10),
          Expanded(
              child: TextField(
                  controller: _senderEmail,
                  decoration: const InputDecoration(
                      labelText: 'Sender Email (blank = username)'))),
        ]),
        const Divider(height: 30),
        const Text('Email & Receipt',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 10),
        TextField(
            controller: _subject,
            decoration: const InputDecoration(
                labelText: 'Subject Template',
                helperText:
                    '{no} = receipt no., {name} = name, {amount} = amount')),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Attach the receipt as a PDF'),
          value: _attachPdf,
          onChanged: (v) => setState(() => _attachPdf = v),
        ),
        TextField(
            controller: _nextNo,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
                labelText: 'Next Receipt No.',
                helperText:
                    'Number of the next receipt. Goes up by 1 after each send.')),
        const Divider(height: 30),
        const Text('Signature Image (JPG / PNG)',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        const SizedBox(height: 10),
        if (sig != null)
          Container(
            height: 70,
            alignment: Alignment.centerLeft,
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade400),
                borderRadius: BorderRadius.circular(8)),
            child: Image.memory(sig, fit: BoxFit.contain),
          ),
        Row(children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.image),
            label: Text(sig == null ? 'Upload Signature' : 'Change'),
            onPressed: _pickSignature,
          ),
          const SizedBox(width: 10),
          if (sig != null)
            TextButton(
              onPressed: _removeSignature,
              child: const Text('Remove'),
            ),
        ]),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.save),
          label: const Text('Save Settings'),
          onPressed: _save,
        ),
        const SizedBox(height: 16),
        // Shows which build is installed (e.g. after updating the APK).
        FutureBuilder<PackageInfo>(
          future: PackageInfo.fromPlatform(),
          builder: (_, snap) => Text(
            snap.hasData
                ? 'App version ${snap.data!.version} '
                    '(build ${snap.data!.buildNumber})'
                : '',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}
