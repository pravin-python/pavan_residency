import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

Future<bool> saveFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Save $fileName',
    fileName: fileName,
    bytes: bytes,
  );
  if (path == null) return false; // cancelled
  // On Android / iOS the plugin already wrote the bytes through the system
  // "Save as" dialog (Storage Access Framework — no storage permission
  // needed). The returned path is only a display hint (always .../Download/
  // <name>), so writing to it again fails with "Permission denied" on
  // Android 10+. Desktop only returns the chosen path: write it ourselves.
  if (!Platform.isAndroid && !Platform.isIOS) {
    await File(path).writeAsBytes(bytes, flush: true);
  }
  return true;
}
