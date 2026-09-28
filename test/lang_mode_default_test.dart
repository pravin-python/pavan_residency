import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/csv_service.dart';

void main() {
  test('language: blank / unknown => English, else as written', () {
    expect(ReceiptData.parseLang(''), 'en');
    expect(ReceiptData.parseLang('Marathi'), 'en');
    expect(ReceiptData.parseLang('English'), 'en');
    expect(ReceiptData.parseLang('Hindi'), 'hi');
    expect(ReceiptData.parseLang('GUJARATI'), 'gu');
    expect(ReceiptData.parseLang('gu'), 'gu');
    expect(ReceiptData.parseLang('ગુજરાતી'), 'gu');
    expect(ReceiptData.parseLang('हिन्दी'), 'hi');
  });

  test('blank mode with only a bank name is online', () {
    expect(ReceiptData.parseMode('', bank: 'BOI'), PaymentMode.online);
    expect(ReceiptData.parseMode('', bank: 'BOI', chqNo: '23'),
        PaymentMode.cheque);
    expect(ReceiptData.parseMode(''), PaymentMode.cash);
    expect(ReceiptData.parseMode('Cash', bank: 'BOI'), PaymentMode.cash);
  });

  test('society sheet: every column read, template rows skipped', () {
    const csv =
        'receipt_no,block,house_no,Received,name,amount,OW/RENT,mode,cheque_no,type,transaction_number,bank_name,received_date,email,language,remarks\n'
        '1,A,101,"7,500",Madanlal Khumawat,"7,500",OWNER,Cheque,,Maintance,,BOI,2026-09-25,a@x.com,English,\n'
        '2,A,102,"7,500",Vinod Prajapati,"7,500",OWNER,Online,,Transfer fee,,BOI,2026-09-28,b@x.com,Hindi,\n'
        '3,A,103,"7,500",Asha Prajapati,"7,500",OWNER,,79800,Deposit,,BOI,2026-09-25,c@x.com,Gujarati,\n'
        '4,A,104,"7,500",Miteshbhai D Patel,"7,500",OWNER,,,Other,,BOI,2026-09-28,d@x.com,English,Test Pravin\n'
        '5,A,201,"7,500",Girishbhai Patel,"7,500",OWNER,,,,,,,,,\n'
        '21,B,101,,,,,,,,,,,,,\n'
        '22,B,102,,,,,,,,,,,,,\n';
    final rows = CsvService.parse(Uint8List.fromList(utf8.encode(csv)));
    expect(rows, hasLength(5)); // the two B-block template rows are skipped

    expect(rows.map((r) => r.amount), everyElement(7500));
    expect(rows[0].mode, PaymentMode.cheque);
    expect(rows[0].chqBank, 'BOI');
    expect(rows[0].type, PaymentType.maintenance);
    expect(rows[1].mode, PaymentMode.online);
    expect(rows[1].type, PaymentType.transfer);
    expect(rows[1].lang, 'hi');
    expect(rows[2].mode, PaymentMode.cheque);
    expect(rows[2].chqNo, '79800');
    expect(rows[2].type, PaymentType.deposit);
    expect(rows[2].lang, 'gu');
    expect(rows[3].type, PaymentType.other);
    expect(rows[3].remark, 'Test Pravin');
    expect(rows[3].mode, PaymentMode.online); // bank given, no cheque no.
    expect(rows[4].lang, 'en'); // blank language
    expect(rows[4].status, SendStatus.invalid); // no email
    expect(rows.take(4).map((r) => r.status), everyElement(SendStatus.ready));
  });
}
