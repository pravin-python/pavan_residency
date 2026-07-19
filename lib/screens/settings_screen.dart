import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/settings_service.dart';

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
        _ssl = s.ssl;
        _attachPdf = s.attachPdf;
      });
    });
  }

  Future<void> _pickSignature() async {
    final res = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png'],
      withData: true,
    );
    final f = res?.files.single;
    if (f?.bytes == null) return;
    final ext = (f!.extension ?? 'png').toLowerCase();
    setState(() {
      _s!.signatureB64 = base64Encode(f.bytes!);
      _s!.signatureMime = ext == 'png' ? 'image/png' : 'image/jpeg';
    });
  }

  Future<void> _save() async {
    final s = _s ?? AppSettings();
    s.host = _host.text.trim();
    s.port = int.tryParse(_port.text) ?? 465;
    s.ssl = _ssl;
    s.username = _user.text.trim();
    
    String cleanedPassword = _pass.text;
    // Auto-clean Gmail App Passwords (which are 16 letters, generated as 4 blocks of 4 separated by spaces)
    if (s.host.toLowerCase().contains('gmail') || s.username.toLowerCase().contains('gmail')) {
      cleanedPassword = cleanedPassword.replaceAll(' ', '');
    }
    s.password = cleanedPassword;

    s.senderName = _senderName.text.trim();
    s.senderEmail = _senderEmail.text.trim();
    s.subjectTpl = _subject.text.trim().isEmpty
        ? 'Pavan Residency Receipt #{no}'
        : _subject.text.trim();
    s.attachPdf = _attachPdf;
    s.nextReceiptNo = int.tryParse(_nextNo.text) ?? 1;
    await SettingsService.save(s);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Settings saved ✓'), backgroundColor: Colors.green));
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
              subtitle: Text(_ssl ? 'Port 465' : 'STARTTLS 587',
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
                'Gmail: 2-Step Verification on karke App Password banao',
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
                  decoration:
                      const InputDecoration(labelText: 'Sender Name'))),
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
                helperText: '{no} = receipt no, {name}, {amount}')),
        const SizedBox(height: 12),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('PDF attachment bhi bhejo'),
          value: _attachPdf,
          onChanged: (v) => setState(() => _attachPdf = v),
        ),
        TextField(
            controller: _nextNo,
            keyboardType: TextInputType.number,
            decoration:
                const InputDecoration(labelText: 'Next Receipt No.')),
        const Divider(height: 30),
        const Text('Signature Image (jpg / jpeg / png)',
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
              onPressed: () => setState(() => _s!.signatureB64 = ''),
              child: const Text('Remove'),
            ),
        ]),
        const SizedBox(height: 20),
        FilledButton.icon(
          icon: const Icon(Icons.save),
          label: const Text('Save Settings'),
          onPressed: _save,
        ),
        const SizedBox(height: 30),
      ],
    );
  }
}
