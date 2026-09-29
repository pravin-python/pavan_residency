import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/email_service.dart';
import 'package:pavan_residency/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('take / release receipt numbers: no duplicates, no gaps', () async {
    SharedPreferences.setMockInitialValues({});
    final s = await SettingsService.load();
    s.nextReceiptNo = 100;
    await SettingsService.save(s);

    // Two concurrent sends (Single + Bulk) get different numbers.
    final got = await Future.wait(
        [SettingsService.takeReceiptNo(), SettingsService.takeReceiptNo()]);
    expect(got.toSet(), {100, 101});
    expect(s.nextReceiptNo, 102);

    // Releasing the latest one gives it back ...
    await SettingsService.releaseReceiptNo(101);
    expect(s.nextReceiptNo, 101);
    // ... but an older one is kept (a later number was already issued).
    await SettingsService.releaseReceiptNo(99);
    expect(s.nextReceiptNo, 101);

    // Explicit number after a send moves the counter past it.
    await SettingsService.bumpReceiptNo(150);
    expect(s.nextReceiptNo, 151);
  });

  test('a failed number that cannot be given back is issued next (spare)',
      () async {
    SharedPreferences.setMockInitialValues({});
    final s = await SettingsService.load();
    s
      ..nextReceiptNo = 800
      ..spareNos.clear();
    await SettingsService.save(s);

    // Parallel sends: 800, 801, 802 taken; 801 then fails for sure.
    final a = await SettingsService.takeReceiptNo();
    final b = await SettingsService.takeReceiptNo();
    final c = await SettingsService.takeReceiptNo();
    expect([a, b, c], [800, 801, 802]);
    await SettingsService.releaseReceiptNo(b);
    expect(s.nextReceiptNo, 803);
    expect(s.spareNos, [801]);
    expect(SettingsService.peekReceiptNo(s), 801);

    // It survives an app restart (saved with the settings) ...
    final saved = AppSettings.fromJson(s.toJson());
    expect(saved.spareNos, [801]);

    // ... and is issued before the counter moves on.
    expect(await SettingsService.takeReceiptNo(), 801);
    expect(await SettingsService.takeReceiptNo(), 803);

    // Releasing the last number moves the counter back and swallows spares
    // right below it.
    await SettingsService.releaseReceiptNo(802); // not last: spare
    await SettingsService.releaseReceiptNo(803); // last: counter 803 -> 802
    expect(s.nextReceiptNo, 802);
    expect(s.spareNos, isEmpty);

    // A typed number that is a spare stops being one once it is used.
    await SettingsService.releaseReceiptNo(800); // spare 800
    await SettingsService.bumpReceiptNo(800);
    expect(s.spareNos, isEmpty);
  });

  test('subject shows the amount like the receipt', () {
    final s = AppSettings(subjectTpl: '#{no} {name} Rs.{amount}');
    expect(s.buildSubject(5, 'Ramesh', 125000.0), '#5 Ramesh Rs.1,25,000');
  });

  test('amount rules', () {
    bool ok(double a) => ReceiptData(amount: a).amountValid;
    expect(ok(7500), isTrue);
    expect(ok(0), isFalse);
    expect(ok(-1), isFalse);
    expect(ok(7500.5), isFalse); // paise would print rounded
    expect(ok(1e9), isFalse); // 100 crore+: words table ends at 99 crore
    expect(ok(double.nan), isFalse);
    expect(ok(double.infinity), isFalse);
    expect(ReceiptData.parseAmount('7 500'), 7500);
  });

  test('friendly SMTP errors', () {
    expect(EmailService.friendlyError(Exception('x')), contains('x'));
  });
}
