import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'google_credentials.dart';

/// Where the service-account key lives between app starts.
abstract class CredentialStore {
  /// The saved key, or null when none is configured. Throws
  /// [CredentialException] when something is saved but cannot be read.
  Future<GoogleCredentials?> read();
  Future<void> write(GoogleCredentials credentials);
  Future<void> delete();
}

/// Android Keystore-backed storage (flutter_secure_storage): the key is
/// encrypted with a hardware-backed master key and is NOT kept in
/// SharedPreferences. App backups are disabled in the manifest, so the
/// ciphertext is not copied to Google Drive or a new phone either.
class SecureCredentialStore implements CredentialStore {
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  static const _key = 'pavan_google_service_account_v1';
  final FlutterSecureStorage _storage;

  @override
  Future<GoogleCredentials?> read() async {
    final String? raw;
    try {
      raw = await _storage.read(key: _key);
    } catch (_) {
      throw const CredentialException(
          'The saved Google credentials could not be read from secure '
          'storage. Upload the JSON file again.');
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      return GoogleCredentials.parse(raw);
    } on CredentialException {
      throw const CredentialException(
          'The saved Google credentials are damaged. Upload the JSON file '
          'again.');
    }
  }

  @override
  Future<void> write(GoogleCredentials credentials) async {
    try {
      await _storage.write(key: _key, value: credentials.toStorageJson());
    } catch (_) {
      throw const CredentialException(
          'The credentials could not be saved to secure storage on this '
          'device.');
    }
  }

  @override
  Future<void> delete() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {
      throw const CredentialException(
          'The credentials could not be removed from secure storage.');
    }
  }
}

/// For tests (nothing touches the platform).
class MemoryCredentialStore implements CredentialStore {
  MemoryCredentialStore([this._value]);
  GoogleCredentials? _value;

  @override
  Future<GoogleCredentials?> read() async => _value;

  @override
  Future<void> write(GoogleCredentials credentials) async =>
      _value = credentials;

  @override
  Future<void> delete() async => _value = null;
}
