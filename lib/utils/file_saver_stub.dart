import 'dart:typed_data';

Future<void> saveFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  throw UnsupportedError('File saving is not supported on this platform.');
}
