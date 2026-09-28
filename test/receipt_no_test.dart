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
