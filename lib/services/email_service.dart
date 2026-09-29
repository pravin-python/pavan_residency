import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
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

/// The sender address (Settings > Sender Email, or the username when that is
/// blank) is not an email address. Checked before connecting, because
/// mailer's persistent connection does not validate it.
class InvalidSenderException implements Exception {
  final String address;
  const InvalidSenderException(this.address);

  @override
  String toString() => 'Invalid sender email: $address';
}

class EmailService {
  /// Tests only: allows the SMTP login over a plain (non-TLS) connection, so
  /// a fake SMTP server on 127.0.0.1 can be used. Never set in the app.
  @visibleForTesting
  static bool allowInsecureForTesting = false;

  /// Upper limit for one send. mailer has no timeout while the data (PDF) is
  /// uploaded, so a stalled network could otherwise hang a send for many
  /// minutes.
  static const sendTimeout = Duration(seconds: 120);

  /// A short, actionable message for the common SMTP failures (the raw
  /// exceptions are long and technical). Always ends with a full stop.
  static String friendlyError(Object e) => _end(_friendly(e));

  static String _end(String s) {
    final t = s.trim();
    return RegExp(r'[.!?]$').hasMatch(t) ? t : '$t.';
  }

  static String _friendly(Object e) {
    if (e is NotSentException) e = e.cause;
    if (e is InvalidSenderException) {
      return 'Invalid sender email (Settings > Sender Email / Username): '
          '"${e.address}"';
    }
    if (e is SmtpClientAuthenticationException) {
      return 'Login failed: wrong username or password. For Gmail, use a '
          '16-letter App Password, not your normal password.';
    }
    if (e is HandshakeException || e is TlsException) {
      return 'SSL error: use port 465 with SSL on, or port 587 with SSL off.';
    }
    if (e is SocketException) {
      return _isConnectFailure(e)
          ? 'Could not connect. Check the internet connection and the SMTP '
              'host / port.'
          : 'The connection to the mail server was lost. Check the internet '
              'connection.';
    }
    if (e is TimeoutException) {
      return 'The mail server did not respond in time. Check the internet '
          'connection and the port.';
    }
    if (e is SmtpMessageValidationException) {
      final probs = e.problems.map((p) => p.msg).join('; ');
      return _isSenderProblem(e)
          ? 'Invalid sender email (Settings > Sender Email / Username): '
              '$probs'
          : 'Invalid recipient email address: $probs';
    }
    if (e is ArgumentError) {
      return 'Invalid recipient email address: ${e.message}';
    }
    if (_serverRefused(e)) {
      final reply = (e as MailerException)
          .message
          .split('\nResponse from server: ')
          .last
          .trim()
          .replaceAll(RegExp(r'^<\s*', multiLine: true), '');
      if (_quotaOrBlocked(e)) {
        return 'The mail server is not accepting emails right now (daily '
            'limit reached or account blocked). Try again later. Server '
            'reply: $reply';
      }
      return 'The mail server refused the email. Server reply: $reply';
    }
    if (e is MailerException) return 'Mail server error: ${e.message}';
    return '$e'.replaceFirst(RegExp(r'^Exception: '), '');
  }

  /// The server answered with an explicit 4xx / 5xx reply (greeting, MAIL,
  /// RCPT or after the data): the mail was NOT accepted.
  static bool _serverRefused(Object e) =>
      e is SmtpClientCommunicationException &&
      e.message.contains('\nResponse from server: ');

  /// 421 (service not available) / x.7.x (policy, auth) / 5.4.5 (Gmail daily
  /// sending limit): every next mail would be refused too.
  static bool _quotaOrBlocked(Object e) =>
      _serverRefused(e) &&
      RegExp(r'< (421\b|\d{3} [45]\.7\.\d+|\d{3} [45]\.4\.5)')
          .hasMatch((e as MailerException).message);

  /// A 421 in reply to MAIL FROM: the server is closing this connection
  /// (idle timeout, mails-per-connection limit) before the mail started —
  /// nothing was sent and a new connection would work.
  static bool _closedAtMailFrom(Object e) =>
      _serverRefused(e) &&
      (e as MailerException).message.startsWith('After sending MAIL FROM') &&
      e.message.contains('< 421');

  /// The sender (From / envelope) address itself is invalid: a Settings
  /// problem, not the resident's. (mailer also uses FROM_ADDRESS for bad
  /// recipients, so the message is checked too.)
  static bool _isSenderProblem(SmtpMessageValidationException e) =>
      e.problems.any((p) =>
          p.code == 'ENV_FROM' ||
          (p.code == 'FROM_ADDRESS' && p.msg.startsWith('The from address')));

  /// Wrong SMTP settings / no internet / daily limit: every further send
  /// would fail the same way (and repeated bad logins can get a Gmail
  /// account locked).
  static bool isConfigError(Object e) {
    final c = e is NotSentException ? e.cause : e;
    return c is InvalidSenderException ||
        c is SmtpClientAuthenticationException ||
        c is SmtpUnsecureException ||
        c is SmtpNoGreetingException ||
        c is HandshakeException ||
        c is TlsException ||
        (c is SocketException && _isConnectFailure(c)) ||
        (c is SmtpMessageValidationException && _isSenderProblem(c)) ||
        _quotaOrBlocked(c);
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
      isConfigError(e) ||
      e is SmtpMessageValidationException ||
      _serverRefused(e);

  /// Sends one receipt email (HTML body + optional PDF attachment
  /// + inline signature) using the SMTP settings stored on the device.
  ///
  /// Throws [NotSentException] when the mail was certainly not delivered;
  /// any other exception means delivery is uncertain (e.g. the connection
  /// dropped after the data was sent), so callers must not reuse the
  /// receipt no. in that case.
  static Future<void> sendReceipt(AppSettings s, ReceiptData d) => _deliver(
      s, d, (message, server) => send(message, server).timeout(sendTimeout));

  /// Builds the mail, hands it to [transport], classifies failures and does
  /// the book-keeping after a successful send.
  static Future<void> _deliver(AppSettings s, ReceiptData d,
      Future<void> Function(Message, SmtpServer) transport) async {
    final Message message;
    final SmtpServer server;
    try {
      (message, server) = await _build(s, d);
    } catch (e) {
      throw NotSentException(e);
    }
    try {
      await transport(message, server);
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
      throw Exception(
          'SMTP settings are missing. Fill them in on the Settings tab first.');
    }
    final from = s.senderEmail.isEmpty ? s.username : s.senderEmail;
    if (!ReceiptData(email: from).emailValid) {
      throw InvalidSenderException(from);
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
      allowInsecure: allowInsecureForTesting,
      username: s.username,
      password: cleanedPassword,
    );

    final sig = s.signatureBytes;
    final html = buildReceiptHtml(d, inlineSignature: sig != null);

    final message = Message()
      ..from = Address(from, s.senderName)
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

/// One logged-in SMTP connection that sends many receipts one after another
/// (Bulk). Logging in once per connection instead of once per mail is much
/// faster and avoids repeated logins, which Gmail may treat as suspicious.
/// Several sessions can run side by side. After any error the connection is
/// dropped and the next mail opens a fresh one.
class SmtpSession {
  SmtpSession(this.settings);

  final AppSettings settings;
  PersistentConnection? _conn;
  int _onConn = 0; // mails sent on the current connection
  DateTime _lastUse = DateTime.now();

  /// Mails this session delivered in total.
  int delivered = 0;

  /// A connection idle longer than this is reopened first: servers close
  /// idle connections, and a mail on a silently closed one would end as
  /// "not sure whether it was delivered".
  static const maxIdle = Duration(seconds: 30);

  /// Same contract as [EmailService.sendReceipt].
  Future<void> sendReceipt(ReceiptData d) =>
      EmailService._deliver(settings, d, (message, server) async {
        if (_conn != null && DateTime.now().difference(_lastUse) > maxIdle) {
          await close();
        }
        for (var retried = false;; retried = true) {
          final reused = _conn != null && _onConn > 0;
          _conn ??= PersistentConnection(server);
          try {
            await _conn!.send(message).timeout(EmailService.sendTimeout);
            _onConn++;
            delivered++;
            _lastUse = DateTime.now();
            return;
          } catch (e) {
            await close(); // the connection may be broken: reconnect
            // The server closed a used connection before this mail started
            // (421 at MAIL FROM): nothing was sent, try once on a new one.
            if (reused && !retried && EmailService._closedAtMailFrom(e)) {
              continue;
            }
            rethrow;
          }
        }
      });

  Future<void> close() async {
    final c = _conn;
    _conn = null;
    _onConn = 0;
    if (c == null) return;
    try {
      await c.close().timeout(const Duration(seconds: 5));
    } catch (_) {
      // Already broken: nothing to close.
    }
  }
}
