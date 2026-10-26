import 'dart:convert';

import 'package:googleapis_auth/googleapis_auth.dart'
    show ServiceAccountCredentials;

/// A problem with the credentials file the user picked. The message is safe
/// to show: it never contains any value from the file.
class CredentialException implements Exception {
  const CredentialException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// A validated Google *service-account* key.
///
/// Only the five fields needed to sign in are kept (the rest of the JSON file
/// is dropped, never stored). The private key is parsed on load, so a
/// truncated or corrupted key is rejected up front instead of failing later
/// on the first request.
class GoogleCredentials {
  GoogleCredentials._({
    required this.clientEmail,
    required this.clientId,
    required this.privateKey,
    required this.projectId,
  });

  final String clientEmail;
  final String clientId;
  final String privateKey;
  final String projectId;

  /// A real key file is ~2.4 KB. Anything far bigger is not one.
  static const maxFileChars = 32 * 1024;

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// Throws [CredentialException] (with a message that is safe to display)
  /// unless [text] is a usable service-account key file.
  static GoogleCredentials parse(String text) {
    final raw = text.trim();
    if (raw.isEmpty) {
      throw const CredentialException('The file is empty.');
    }
    if (raw.length > maxFileChars) {
      throw const CredentialException(
          'This file is too large to be a Google credentials file.');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const CredentialException(
          'This is not a valid JSON file. Choose the key file downloaded '
          'from Google Cloud (a .json file).');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const CredentialException(
          'This JSON file is not a Google credentials file.');
    }
    final map = decoded;

    final type = map['type'];
    if (type != 'service_account') {
      if (map.containsKey('installed') || map.containsKey('web')) {
        throw const CredentialException(
            'This is an OAuth client file, not a service-account key. In '
            'Google Cloud open IAM & Admin > Service Accounts, create a key '
            'of type JSON and choose that file.');
      }
      if (type == 'authorized_user') {
        throw const CredentialException(
            'This file holds personal (gcloud) login credentials, not a '
            'service-account key. Create a JSON key for a service account.');
      }
      throw const CredentialException(
          'This is not a Google service-account key (it has no '
          '"type": "service_account").');
    }

    String field(String name) {
      final v = map[name];
      return v is String ? v.trim() : '';
    }

    final email = field('client_email');
    final clientId = field('client_id');
    final key = field('private_key');
    final project = field('project_id');

    final missing = [
      if (email.isEmpty) 'client_email',
      if (clientId.isEmpty) 'client_id',
      if (key.isEmpty) 'private_key',
    ];
    if (missing.isNotEmpty) {
      throw CredentialException(
          'The key file is incomplete: missing ${missing.join(', ')}. '
          'Download a fresh JSON key.');
    }
    if (!_emailRe.hasMatch(email) || !email.endsWith('.gserviceaccount.com')) {
      throw const CredentialException(
          'client_email is not a service-account address (it should end with '
          '.gserviceaccount.com).');
    }

    final tokenUri = field('token_uri');
    if (tokenUri.isNotEmpty) {
      final u = Uri.tryParse(tokenUri);
      if (u == null ||
          u.scheme != 'https' ||
          !(u.host == 'googleapis.com' || u.host.endsWith('.googleapis.com'))) {
        throw const CredentialException(
            'token_uri does not point to Google. This file was not issued '
            'by Google Cloud.');
      }
    }

    final creds = GoogleCredentials._(
      clientEmail: email,
      clientId: clientId,
      privateKey: key,
      projectId: project,
    );
    try {
      creds.toAuth(); // parses the RSA key
    } catch (_) {
      throw const CredentialException(
          'The private key in this file could not be read. Download a fresh '
          'JSON key and do not edit the file.');
    }
    return creds;
  }

  /// What is kept in secure storage: only what signing in needs.
  String toStorageJson() => jsonEncode({
        'type': 'service_account',
        'client_email': clientEmail,
        'client_id': clientId,
        'private_key': privateKey,
        'project_id': projectId,
      });

  ServiceAccountCredentials toAuth() =>
      ServiceAccountCredentials.fromJson(jsonDecode(toStorageJson()));

  /// Never prints the key.
  @override
  String toString() => 'GoogleCredentials($clientEmail)';
}
