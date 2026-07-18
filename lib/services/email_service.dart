import 'dart:typed_data';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import '../models/receipt_data.dart';
import 'pdf_service.dart';
import 'receipt_html.dart';
import 'settings_service.dart';

class EmailService {
  /// Sends one receipt email (HTML body + optional PDF attachment
  /// + inline signature) using the SMTP settings stored on the device.
  ///
  /// Throws with a readable message on failure.
  static Future<void> sendReceipt(AppSettings s, ReceiptData d) async {
    if (!s.isConfigured) {
      throw Exception('SMTP settings missing - Settings tab bharo.');
    }

    final server = SmtpServer(
      s.host,
      port: s.port,
      ssl: s.ssl,
      username: s.username,
      password: s.password,
    );

    final sig = s.signatureBytes;
    final html = buildReceiptHtml(d, inlineSignature: sig != null);

    final message = Message()
      ..from = Address(
          s.senderEmail.isEmpty ? s.username : s.senderEmail, s.senderName)
      ..recipients.add(d.email)
      ..subject = s.buildSubject(d.recNo, d.name, d.amount)
      ..html = html;

    if (sig != null) {
      final ext = s.signatureMime.contains('png') ? 'png' : 'jpg';
      message.attachments.add(
        StreamAttachment(
          Stream.value(sig.toList()),
          s.signatureMime,
          fileName: 'signature.$ext',
        )
          ..location = Location.inline
          ..cid = '<sig>',
      );
    }

    if (s.attachPdf) {
      final Uint8List pdf =
          await PdfService.buildReceiptPdf(d, signature: sig);
      message.attachments.add(
        StreamAttachment(
          Stream.value(pdf.toList()),
          'application/pdf',
          fileName: 'Pavan_Receipt_${d.recNo}.pdf',
        ),
      );
    }

    final report = await send(message, server);
    if (report.toString().isEmpty) {
      throw Exception('Send failed');
    }
    await SettingsService.bumpReceiptNo(d.recNo);
  }
}
