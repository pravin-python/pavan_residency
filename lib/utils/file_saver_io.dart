import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';

Future<void> saveFile({
  required Uint8List bytes,
  required String fileName,
  required String mimeType,
}) async {
  final path = await FilePicker.platform.saveFile(
    dialogTitle: 'Save Demo CSV',
    fileName: fileName,
    bytes: bytes,
  );
  if (path != null && bytes.isNotEmpty) {
    final file = File(path);
    await file.writeAsBytes(bytes);
  }
}
