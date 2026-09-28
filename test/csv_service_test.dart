import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/models/receipt_data.dart';
import 'package:pavan_residency/services/csv_service.dart';

List<ReceiptData> parse(String csv) =>
    CsvService.parse(Uint8List.fromList(utf8.encode(csv)));

void main() {
  const header = 'receipt_no,block,house_no,name,amount,mode,cheque_no,type,'
      'transaction_number,bank_name,received_date,email,language';

  test('reads every column of the society sheet', () {
    final rows = parse('$header\r\n'
        '1,A,101,Madanlal Khumawat,"7,500",Cheque,,Maintenance,,,2026-09-25,a@x.com,English\r\n'
        '2,A,102,Vinod Prajapati,7500,Online,,Transfer Fee,UTR123,BOI,,b@x.com,Hindi\r\n'
        '3,A,103,Asha Prajapati,7500,,79800,Deposit,,BOI,2026-09-25,c@x.com,Gujarati\r\n');

    expect(rows, hasLength(3));

    final a = rows[0];
    expect(a.recNo, 1);
    expect(a.block, 'A');
    expect(a.house, '101');
    expect(a.name, 'Madanlal Khumawat');
    expect(a.amount, 7500);
    expect(a.mode, PaymentMode.cheque);
    expect(a.type, PaymentType.maintenance);
    expect(a.date, '25-09-2026');
    expect(a.email, 'a@x.com');
    expect(a.lang, 'en');
    expect(a.status, SendStatus.ready);

    final b = rows[1];
    expect(b.mode, PaymentMode.online);
    expect(b.txnNo, 'UTR123');
    expect(b.chqBank, 'BOI');
    expect(b.type, PaymentType.transfer);
    expect(b.lang, 'hi');
    expect(b.date, CsvService.todayStr());

    // Blank mode + cheque no. => cheque.
    final c = rows[2];
    expect(c.mode, PaymentMode.cheque);
    expect(c.chqNo, '79800');
    expect(c.chqBank, 'BOI');
    expect(c.type, PaymentType.deposit);
    expect(c.lang, 'gu');
  });

  test('old column names still work', () {
    final rows = parse(
        'name,email,block,house_no,amount,cheque_no,cheque_bank,language,type,date\n'
        'Ramesh,r@x.com,A,101,1500,123456,SBI,gujarati,maintenance,2026-07-18\n'
        'Suresh,s@x.com,B,202,25000,,,hindi,deposit,\n');
    expect(rows[0].mode, PaymentMode.cheque);
    expect(rows[0].chqBank, 'SBI');
    expect(rows[0].date, '18-07-2026');
    expect(rows[1].mode, PaymentMode.cash);
  });

  test('date column wins over received_date', () {
    final rows = parse('name,email,amount,date,received_date\n'
        'X,x@x.com,10,2026-01-02,2026-03-04\n');
    expect(rows.single.date, '02-01-2026');
  });

  test('values match case-insensitively; block upper-cased', () {
    final rows = parse('block,name,email,amount,mode,type,language\n'
        'a,P,p@x.com,1,CHEQUE,MAINTANCE,GUJARATI\n'
        'b,Q,q@x.com,1,online,transfer FEE,hindi\n'
        'C,R,r@x.com,1,Cash,deposit,eNgLiSh\n');
    expect(rows.map((r) => r.block), ['A', 'B', 'C']);
    expect(rows.map((r) => r.mode),
        [PaymentMode.cheque, PaymentMode.online, PaymentMode.cash]);
    expect(rows.map((r) => r.type),
        [PaymentType.maintenance, PaymentType.transfer, PaymentType.deposit]);
    expect(rows.map((r) => r.lang), ['gu', 'hi', 'en']);
  });

  test('Other details from remarks column or free text in type', () {
    final rows = parse('name,email,amount,type,remarks\n'
        'A,a@x.com,1,Other,Parking charges\n'
        'B,b@x.com,1,Late fee,\n'
        'C,c@x.com,1,OTHER,\n'
        'D,d@x.com,1,Maintenance,ignored for non-other\n');
    expect(rows[0].type, PaymentType.other);
    expect(rows[0].remark, 'Parking charges');
    expect(rows[1].type, PaymentType.other);
    expect(rows[1].remark, 'Late fee');
    expect(rows[2].type, PaymentType.other);
    expect(rows[2].remark, '');
    expect(rows[3].type, PaymentType.maintenance);
    expect(rows[3].remark, '');
  });

  test('parseMode / parseAmount / normDate', () {
    expect(ReceiptData.parseMode('cash', chqNo: '1'), PaymentMode.cash);
    expect(ReceiptData.parseMode('UPI'), PaymentMode.online);
    expect(ReceiptData.parseMode('NEFT'), PaymentMode.online);
    expect(ReceiptData.parseMode('Check'), PaymentMode.cheque);
    expect(ReceiptData.parseMode('', txnNo: 'T1'), PaymentMode.online);
    expect(ReceiptData.parseMode(''), PaymentMode.cash);
    expect(ReceiptData.parseAmount('Rs. 7,500.50'), 7500.5);
    expect(ReceiptData.parseAmount('₹7500'), 7500);
    expect(ReceiptData.parseAmount(''), 0);
    expect(CsvService.normDate('25/9/2026'), '25-09-2026');
    expect(CsvService.normDate('2026/9/5'), '05-09-2026');
    // Excel (US locale) month-first re-save.
    expect(CsvService.normDate('9/25/2026'), '25-09-2026');
    expect(CsvService.normDate('2026-09-25 10:30:00'), '25-09-2026');
    expect(CsvService.normDate('25/09/2026 00:00'), '25-09-2026');
  });
}
