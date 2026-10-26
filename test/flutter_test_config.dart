import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Picked up automatically by `flutter test` for every test file.
///
/// The real flutter_secure_storage talks to the platform (Android Keystore on
/// a phone, file I/O on the Windows host running the tests), which cannot
/// complete inside widget tests. Every test gets the package's in-memory
/// platform instead, so the real SecureCredentialStore code still runs.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  FlutterSecureStorage.setMockInitialValues({});
  await testMain();
}
