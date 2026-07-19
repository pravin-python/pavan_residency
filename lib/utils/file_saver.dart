import 'dart:typed_data';
import 'file_saver_stub.dart'
    if (dart.library.html) 'file_saver_web.dart'
    if (dart.library.io) 'file_saver_io.dart';

abstract class FileSaver {
  static Future<void> save({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
  }) async {
    await saveFile(bytes: bytes, fileName: fileName, mimeType: mimeType);
  }
}
