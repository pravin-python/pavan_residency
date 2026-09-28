import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/sent_log.dart';
import 'package:pavan_residency/services/signature_image.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('signature: big photo is shrunk, garbage is rejected', () async {
    final photo = img.Image(width: 3000, height: 1000);
    img.fill(photo, color: img.ColorRgb8(250, 250, 250));
    final jpg = Uint8List.fromList(img.encodeJpg(photo));
    final sig = await SignatureImage.prepare(jpg);
    expect(sig, isNotNull);
    expect(sig!.mime, 'image/jpeg');
    expect(img.decodeImage(sig.bytes)!.width, SignatureImage.maxWidth);

    final transparent = img.Image(width: 200, height: 80, numChannels: 4);
    final png = await SignatureImage.prepare(
        Uint8List.fromList(img.encodePng(transparent)));
    expect(png!.mime, 'image/png');

    expect(await SignatureImage.prepare(Uint8List.fromList([1, 2, 3])), isNull);
  });

  test('sent log remembers delivered receipts', () async {
    SharedPreferences.setMockInitialValues({});
    final d = ReceiptData(
        name: 'Vinod', email: 'v@x.com', amount: 7500, date: '25-09-2026')
      ..recNo = 812;
    expect(await SentLog.sentNo(d), isNull);
    await SentLog.add(d);
    expect(await SentLog.sentNo(d.copy()..recNo = 0), 812);
    // A different payment of the same person is a different receipt.
    expect(await SentLog.sentNo(d.copy()..amount = 1500), isNull);
  });
}
