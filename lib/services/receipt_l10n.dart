import '../models/receipt_data.dart';

/// Receipt labels in Gujarati / Hindi / English (matches the printed
/// receipt book of Pavan Residency).
class ReceiptL10n {
  final String society, reg, addr, title, recNo, date, name, block, flat;
  final String chq, bank, cash, pay, received, words, total, note, sign;
  final List<String> col; // [No., Particulars, Amount]
  final List<String> nums; // row numbers
  final Map<PaymentType, String> rows;
  final String fontFamily; // Flutter font family for previews

  const ReceiptL10n({
    required this.society,
    required this.reg,
    required this.addr,
    required this.title,
    required this.recNo,
    required this.date,
    required this.name,
    required this.block,
    required this.flat,
    required this.chq,
    required this.bank,
    required this.cash,
    required this.pay,
    required this.received,
    required this.words,
    required this.total,
    required this.note,
    required this.sign,
    required this.col,
    required this.nums,
    required this.rows,
    required this.fontFamily,
  });

  static const gu = ReceiptL10n(
    society: 'પાવન રેસીડેન્સી (ભાડજ) કો.ઓ.હા.સો.લી.',
    reg: 'રજી. નં. જીએચએચ-૯૪૨૭  તા. ૨૭-૨-૨૦૧૩',
    addr: 'પાવન રેસીડેન્સી, નિર્મળચોક પાસે, ભાડજ ગામ, અમદાવાદ.',
    title: 'પહોંચ',
    recNo: 'પહોંચ નં.',
    date: 'તારીખ',
    name: 'શ્રીમાન / શ્રીમતી',
    block: 'બ્લોક નં.',
    flat: 'રહેઠાણ / શેડ નં.',
    chq: 'ચેક નં.',
    bank: 'બેંક',
    cash: 'રોકડ',
    pay: 'ચુકવણી',
    received: 'તરફથી નીચેની વિગતે રકમ મળી છે:',
    words: 'અંકે રૂપિયા',
    total: 'ટોટલ',
    note: 'તા.ક. : ચેકથી ચુકવણીના કિસ્સામાં ચેક ક્લિયર થયા બાદ જ પહોંચ માન્ય ગણાશે.',
    sign: 'વસૂલ કરનારની સહી',
    col: ['ક્રમ', 'વિગત', 'રકમ (રૂ.)'],
    nums: ['૧)', '૨)', '૩)', '૪)'],
    rows: {
      PaymentType.maintenance: 'મેન્ટેનન્સ',
      PaymentType.deposit: 'મેન્ટેનન્સ પેટે ડિપોઝિટ',
      PaymentType.transfer: 'ટ્રાન્સફર ફી',
      PaymentType.other: 'અન્ય',
    },
    fontFamily: 'NotoSansGujarati',
  );

  static const hi = ReceiptL10n(
    society: 'पावन रेसीडेन्सी (भाडज) को.ऑ.हा.सो.लि.',
    reg: 'रजि. नं. जीएचएच-9427  दि. 27-2-2013',
    addr: 'पावन रेसीडेन्सी, निर्मलचोक के पास, भाडज गाँव, अहमदाबाद.',
    title: 'रसीद',
    recNo: 'रसीद नं.',
    date: 'दिनांक',
    name: 'श्रीमान / श्रीमती',
    block: 'ब्लॉक नं.',
    flat: 'निवास / शेड नं.',
    chq: 'चेक नं.',
    bank: 'बैंक',
    cash: 'नक़द',
    pay: 'भुगतान',
    received: 'की ओर से नीचे दिए विवरण अनुसार राशि प्राप्त हुई है:',
    words: 'अंकों में रुपये',
    total: 'कुल',
    note: 'नोट : चेक द्वारा भुगतान की स्थिति में चेक क्लियर होने के बाद ही रसीद मान्य होगी.',
    sign: 'वसूलकर्ता के हस्ताक्षर',
    col: ['क्रम', 'विवरण', 'राशि (रु.)'],
    nums: ['1)', '2)', '3)', '4)'],
    rows: {
      PaymentType.maintenance: 'मेंटेनेंस',
      PaymentType.deposit: 'मेंटेनेंस हेतु डिपॉज़िट',
      PaymentType.transfer: 'ट्रांसफर फीस',
      PaymentType.other: 'अन्य',
    },
    fontFamily: 'NotoSansDevanagari',
  );

  static const en = ReceiptL10n(
    society: 'PAVAN RESIDENCY (BHADAJ) CO.OP.HSG.SOC.LTD.',
    reg: 'Reg. No. GHH-9427  Dt. 27-2-2013',
    addr: 'Pavan Residency, Near Nirmal Chowk, Bhadaj Village, Ahmedabad.',
    title: 'RECEIPT',
    recNo: 'Receipt No.',
    date: 'Date',
    name: 'Mr. / Mrs.',
    block: 'Block No.',
    flat: 'Residence / Shed No.',
    chq: 'Cheque No.',
    bank: 'Bank',
    cash: 'Cash',
    pay: 'Payment',
    received: '— received with thanks the amount as per details below:',
    words: 'Rupees in words',
    total: 'Total',
    note: 'P.S. : In case of payment by cheque, receipt is valid only after cheque realisation.',
    sign: 'Signature of Collector',
    col: ['No.', 'Particulars', 'Amount (Rs.)'],
    nums: ['1)', '2)', '3)', '4)'],
    rows: {
      PaymentType.maintenance: 'Maintenance',
      PaymentType.deposit: 'Deposit towards Maintenance',
      PaymentType.transfer: 'Transfer Fee',
      PaymentType.other: 'Other',
    },
    fontFamily: 'NotoSans',
  );

  static ReceiptL10n of(String lang) {
    switch (lang) {
      case 'hi':
        return hi;
      case 'en':
        return en;
      default:
        return gu;
    }
  }
}
