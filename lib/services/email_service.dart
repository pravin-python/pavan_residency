import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:mailer/mailer.dart';
import 'package:mailer/smtp_server.dart';

import '../models/receipt_data.dart';
import 'pdf_service.dart';
import 'receipt_html.dart';
import 'sent_log.dart';
import 'settings_service.dart';

/// The email was certainly NOT delivered (failed while building it, or the
/// server refused before accepting it): its receipt no. can be reused.
class NotSentException implements Exception {
  final Object cause;
  const NotSentException(this.cause);

  @override
  String toString() => '$cause';
}

class EmailService {
  /// A short, actionable message for the common SMTP failures (the raw
  /// exceptions are long and technical).
  static String friendlyError(Object e) {
    if (e is NotSentException) e = e.cause;
    if (e is SmtpClientAuthenticationException) {
      return 'Login fail: username / password galat. Gmail ho to normal '
          'password nahi, 16-letter App Password daalo.';
    }
    if (e is HandshakeException || e is TlsException) {
      return 'SSL error: port 465 ke saath SSL ON, port 587 ke saath SSL OFF '
          'rakho.';
    }
    if (e is SocketException) {
      return 'Connect nahi hua: internet check karo, ya SMTP host / port '
          'galat hai.';
    }
    if (e is TimeoutException) {
      return 'Server ne jawab nahi diya (timeout). Internet / port check karo.';
    }
    if (e is SmtpMessageValidationException || e is ArgumentError) {
      return 'Email address galat hai: $e';
    }
    if (e is MailerException) return 'Mail server error: ${e.message}';
    return '$e';
  }

  /// Wrong SMTP settings / no internet: every further send would fail the
  /// same way (and repeated bad logins can get a Gmail account locked).
  static bool isConfigError(Object e) {
    final c = e is NotSentException ? e.cause : e;
    return c is SmtpClientAuthenticationException ||
        c is SmtpUnsecureException ||
        c is SmtpNoGreetingException ||
        c is HandshakeException ||
        c is TlsException ||
        (c is SocketException && _isConnectFailure(c));
  }

  static bool _isConnectFailure(SocketException e) {
    final m = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    return m.contains('host lookup') ||
        m.contains('refused') ||
        m.contains('unreachable') ||
        m.contains('no address') ||
        m.contains('timed out');
  }

  /// Failures that happen before the server accepts the message.
  static bool _beforeDelivery(Object e) =>
      isConfigError(e) || e is SmtpMessageValidationException;

  /// Sends one receipt email (HTML body + optional PDF attachment
  /// + inline signature) using the SMTP settings stored on the device.
  ///
  /// Throws [NotSentException] when the mail was certainly not delivered;
  /// any other exception means delivery is uncertain (e.g. the connection
  /// dropped after the data was sent), so callers must not reuse the
  /// receipt no. in that case.
  static Future<void> sendReceipt(AppSettings s, ReceiptData d) async {
    final Message message;
    final SmtpServer server;
    try {
      (message, server) = await _build(s, d);
    } catch (e) {
      throw NotSentException(e);
    }
    try {
      await send(message, server);
    } catch (e) {
      if (_beforeDelivery(e)) throw NotSentException(e);
      rethrow;
    }
    // Sent. Book-keeping must never turn a delivered mail into a "failure"
    // (that would release its receipt no. for someone else).
    try {
      await SettingsService.bumpReceiptNo(d.recNo);
      await SentLog.add(d);
    } catch (_) {}
  }

  static Future<(Message, SmtpServer)> _build(
      AppSettings s, ReceiptData d) async {
    if (!s.isConfigured) {
      throw Exception('SMTP settings missing - Settings tab bharo.');
    }

    String cleanedPassword = s.password;
    if (s.host.toLowerCase().contains('gmail') ||
        s.username.toLowerCase().contains('gmail')) {
      cleanedPassword = cleanedPassword.replaceAll(' ', '');
    }

    final server = SmtpServer(
      s.host,
      port: s.port,
      ssl: s.ssl,
      username: s.username,
      password: cleanedPassword,
    );

    final sig = s.signatureBytes;
    final html = buildReceiptHtml(d, inlineSignature: sig != null);

    final message = Message()
      ..from = Address(
          s.senderEmail.isEmpty ? s.username : s.senderEmail, s.senderName)
      ..recipients.addAll(d.emails)
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
      final Uint8List pdf = await PdfService.buildReceiptPdf(d, signature: sig);
      message.attachments.add(
        StreamAttachment(
          Stream.value(pdf.toList()),
          'application/pdf',
          fileName: 'Pavan_Receipt_${d.recNo}.pdf',
        ),
      );
    }

    return (message, server);
  }
}
