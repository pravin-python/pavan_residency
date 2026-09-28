import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// A signature image ready to store and embed (PDF + email).
class SignatureImage {
  final Uint8List bytes;
  final String mime; // image/png | image/jpeg

  const SignatureImage(this.bytes, this.mime);

  /// Max width in pixels. The receipt prints the signature ~30pt tall, so a
  /// phone-camera photo (4000px, several MB) would only bloat every email,
  /// PDF and the saved settings.
  static const maxWidth = 800;

  /// Decodes [raw] (jpg / png), fixes camera rotation, shrinks it to
  /// [maxWidth] and re-encodes (PNG if it has transparency, else JPEG).
  /// Returns null when [raw] is not a readable image. Runs off the UI thread.
  static Future<SignatureImage?> prepare(Uint8List raw) =>
      Isolate.run(() => _prepare(raw));

  static SignatureImage? _prepare(Uint8List raw) {
    img.Image? decoded;
    try {
      decoded = img.decodeImage(raw);
    } catch (_) {
      decoded = null; // corrupt / truncated / not an image: the decoder throws
    }
    if (decoded == null) return null;
    var im = img.bakeOrientation(decoded);
    if (im.width > maxWidth) im = img.copyResize(im, width: maxWidth);
    return im.hasAlpha
        ? SignatureImage(img.encodePng(im), 'image/png')
        : SignatureImage(img.encodeJpg(im, quality: 88), 'image/jpeg');
  }
}
