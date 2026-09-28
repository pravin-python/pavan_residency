import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/csv_service.dart';

List<ReceiptData> parse(String csv) =>
    CsvService.parse(Uint8List.fromList(utf8.encode(csv)));

void main() {
  test('payment mode keywords', () {
    const online = PaymentMode.online;
    for (final v in [
      'GPay', 'Google Pay', 'PhonePe', 'Paytm', 'UPI', 'NEFT', 'Card',
      'ઓનલાઈન', 'ऑनलाइन', 'Wallet', // unknown but not cash
    ]) {
      expect(ReceiptData.parseMode(v), online, reason: v);
    }
    for (final v in ['Cheque', 'CHECK', 'chq', 'DD', 'ચેક', 'चेक']) {
      expect(ReceiptData.parseMode(v), PaymentMode.cheque, reason: v);
    }
    for (final v in ['Cash', 'રોકડ', 'नक़द']) {
      expect(ReceiptData.parseMode(v), PaymentMode.cash, reason: v);
    }
    expect(ReceiptData.parseMode('Society office', chqNo: '12'),
        PaymentMode.cheque);
  });

  test('type: word stems, other prefix and details', () {
    expect(ReceiptData.parseType('Transport'), PaymentType.other);
    expect(ReceiptData.parseType('Transformer charges'), PaymentType.other);
    expect(ReceiptData.parseType('Depot'), PaymentType.other);
    expect(ReceiptData.parseType('Maintenance Deposit'), PaymentType.deposit);
    expect(ReceiptData.parseType('Transfer fee'), PaymentType.transfer);
    expect(ReceiptData.parseType('Other maintenance'), PaymentType.other);

    expect(ReceiptData.otherText('Other - Parking charges'), 'Parking charges');
    expect(ReceiptData.otherText('Others: Ganesh festival'), 'Ganesh festival');
    expect(ReceiptData.otherText('Other (Parking)'), 'Parking');
    expect(ReceiptData.otherText('अन्य - पार्किंग'), 'पार्किंग');
    expect(ReceiptData.otherText('Brother parking'), 'Brother parking');
    expect(ReceiptData.otherText('Transport'), 'Transport');
    expect(ReceiptData.otherText('Other'), '');
    expect(ReceiptData.otherText('4'), '');
  });

  test('amounts: negative is invalid', () {
    expect(ReceiptData.parseAmount('-500'), -500);
    expect(ReceiptData.parseAmount('(500)'), -500);
    expect(ReceiptData.parseAmount('Rs.-500'), -500);
    expect(ReceiptData(name: 'a', email: 'a@x.com', amount: -500).isValid,
        isFalse);
  });

  test('emails: multiple recipients and validation', () {
    final d = ReceiptData(name: 'a', amount: 1, email: 'a@x.com; b@y.in');
    expect(d.emails, ['a@x.com', 'b@y.in']);
    expect(d.isValid, isTrue);
    expect(ReceiptData(name: 'a', amount: 1, email: 'a@x').isValid, isFalse);
    expect(
        ReceiptData(name: 'a', amount: 1, email: 'abc').invalidReason, 'email');
  });

  test('CSV: alias columns, remarks join, month-first file', () {
    final rows = parse(
        'name,email,amount,cheque_bank,bank_name,type,remarks,received_date\n'
        'A,a@x.com,1,,BOI,Parking charges,Sep,9/5/2026\n'
        'B,b@x.com,1,SBI,,Other,,9/25/2026\n');
    expect(rows[0].chqBank, 'BOI');
    expect(rows[1].chqBank, 'SBI');
    expect(rows[0].remark, 'Parking charges – Sep');
    expect(rows[1].remark, '');
    // One file => one order: both are month-first.
    expect(rows[0].date, '05-09-2026');
    expect(rows[1].date, '25-09-2026');

    // Day-first file stays day-first.
    final dm = parse('name,email,amount,received_date\n'
        'A,a@x.com,1,9/5/2026\n'
        'B,b@x.com,1,25/9/2026\n');
    expect(dm.map((r) => r.date), ['09-05-2026', '25-09-2026']);
  });

  test('CSV: UTF-8 BOM, UTF-16 and ; / tab delimiters', () {
    const csv = 'name,email,amount\nRamesh,r@x.com,"1,500"\n';
    final bom = CsvService.parse(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode(csv)]));
    expect(bom.single.name, 'Ramesh');
    expect(bom.single.amount, 1500);

    final units = 'name\temail\tamount\nરમેશ\tr@x.com\t1500\n'.codeUnits;
    final le = <int>[0xFF, 0xFE];
    for (final u in units) {
      le
        ..add(u & 0xFF)
        ..add(u >> 8);
    }
    final utf16 = CsvService.parse(Uint8List.fromList(le));
    expect(utf16.single.name, 'રમેશ');
    expect(utf16.single.amount, 1500);

    final semi = parse('name;email;amount\nA;a@x.com;700\n');
    expect(semi.single.amount, 700);
    expect(semi.single.status, SendStatus.ready);
  });
}
