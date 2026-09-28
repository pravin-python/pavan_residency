enum PaymentType { maintenance, deposit, transfer, other }

enum PaymentMode { cash, cheque, online }

enum SendStatus { ready, invalid, sending, sent, error }

class ReceiptData {
  /// Society blocks offered in the Single form's Block dropdown.
  static const blocks = ['A', 'B', 'C'];

  /// Max length of the "Other" details text (keeps the PDF row on one line).
  static const maxRemark = 60;

  String lang; // 'gu' | 'hi' | 'en'
  String name;
  String email;
  String block;
  String house;
  double amount;
  PaymentType type;
  String remark; // details printed on the "Other" row
  PaymentMode mode;
  String chqNo;
  String chqBank; // bank name (cheque or online)
  String txnNo; // online transaction / UTR number
  int recNo;
  String date; // dd-MM-yyyy
  SendStatus status;
  String error;

  /// Bulk: already emailed from this phone earlier (see SentLog).
  bool sentBefore = false;

  /// The CSV had no date, so [date] is the day it was loaded (today).
  bool dateDefaulted = false;

  ReceiptData({
    this.lang = 'gu',
    this.name = '',
    this.email = '',
    this.block = '',
    this.house = '',
    this.amount = 0,
    this.type = PaymentType.maintenance,
    this.remark = '',
    this.mode = PaymentMode.cash,
    this.chqNo = '',
    this.chqBank = '',
    this.txnNo = '',
    this.recNo = 0,
    this.date = '',
    this.status = SendStatus.ready,
    this.error = '',
  });

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');

  /// One or more recipients: 'a@x.com' or 'a@x.com, b@y.com' / ';' / space.
  List<String> get emails =>
      email.split(RegExp(r'[,;\s]+')).where((e) => e.isNotEmpty).toList();

  bool get emailValid =>
      emails.isNotEmpty && emails.every((e) => _emailRe.hasMatch(e));

  /// Whole rupees, > 0 and below 100 crore (the words / Indian grouping
  /// code works in whole rupees, so paise would print rounded).
  bool get amountValid =>
      amount.isFinite &&
      amount > 0 &&
      amount < 1e9 &&
      amount == amount.roundToDouble();

  bool get isValid => name.isNotEmpty && emailValid && amountValid;

  /// Why [isValid] is false (shown in the Bulk list).
  String get invalidReason => [
        if (name.isEmpty) 'name',
        if (!emailValid) 'email',
        if (!amountValid) 'amount',
      ].join(', ');

  ReceiptData copy() => ReceiptData(
        lang: lang,
        name: name,
        email: email,
        block: block,
        house: house,
        amount: amount,
        type: type,
        remark: remark,
        mode: mode,
        chqNo: chqNo,
        chqBank: chqBank,
        txnNo: txnNo,
        recNo: recNo,
        date: date,
        status: status,
        error: error,
      )
        ..sentBefore = sentBefore
        ..dateDefaulted = dateDefaulted;

  /// Case-insensitive: 'Cash' / 'Cheque' / 'Check' / 'Online' / 'UPI' /
  /// 'NEFT' / 'GPay' / 'PhonePe' ... (Gujarati / Hindi words too).
  /// Blank mode is inferred: cheque no. => cheque, transaction no. or a bank
  /// name => online, otherwise cash. An unrecognised mode (e.g. 'Wallet') is not cash:
  /// cheque if a cheque no. is given, else online.
  static PaymentMode parseMode(String v,
      {String chqNo = '', String txnNo = '', String bank = ''}) {
    final s = v.trim().toLowerCase();
    final hasChq = chqNo.trim().isNotEmpty;
    if (s.isEmpty) {
      if (hasChq) return PaymentMode.cheque;
      // A transaction no. or just a bank name (no cheque no.) = paid into
      // the bank, not cash.
      if (txnNo.trim().isNotEmpty || bank.trim().isNotEmpty) {
        return PaymentMode.online;
      }
      return PaymentMode.cash;
    }
    bool any(List<String> keys) => keys.any(s.contains);
    if (any(const ['cash', 'rokad', 'nakad', 'naqad', 'રોકડ', 'नक'])) {
      return PaymentMode.cash;
    }
    if (s == 'dd' ||
        any(const [
          'cheque',
          'check',
          'chq',
          'chk',
          'demand draft',
          'ચેક',
          'चेक'
        ])) {
      return PaymentMode.cheque;
    }
    if (any(const [
      'online',
      'on line',
      'upi',
      'neft',
      'rtgs',
      'imps',
      'net',
      'bank',
      'transfer',
      'gpay',
      'google pay',
      'phonepe',
      'phone pe',
      'paytm',
      'bhim',
      'card',
      'wallet',
      'ઓનલાઈન',
      'ઓનલાઇન',
      'ऑनलाइन',
      'ऑनलाईन',
      'ओनलाइन',
    ])) {
      return PaymentMode.online;
    }
    return hasChq ? PaymentMode.cheque : PaymentMode.online;
  }

  /// '7,500' / '₹ 7500' / 'Rs. 7,500.00' => 7500.
  /// '-500' / '(500)' => negative, so the row is flagged invalid.
  /// '7500,00' (comma as decimal point, Excel in some locales) => 7500;
  /// '7500/-' => 7500.
  static double parseAmount(String v) {
    var s = v.replaceAll(RegExp(r'\s'), '').replaceFirst(RegExp(r'/-$'), '');
    // A single comma followed by 1–2 final digits is a decimal comma; a
    // thousands comma (Indian or Western) always has 3 digits after the last.
    s = RegExp(r'^[^,]*,\d{1,2}$').hasMatch(s)
        ? s.replaceFirst(',', '.')
        : s.replaceAll(',', '');
    final m = RegExp(r'\d+(\.\d+)?').firstMatch(s);
    if (m == null) return 0;
    final n = double.parse(m.group(0)!);
    final neg = s.substring(0, m.start).contains('-') || s.startsWith('(');
    return neg ? -n : n;
  }

  /// 'gujarati' / 'hindi' / 'english' / 'gu' / 'hi' / 'en' / native names.
  /// Blank or not recognised => English.
  static String parseLang(String v) {
    final s = v.trim().toLowerCase();
    if (s.startsWith('hi') || s.contains('हि') || s.contains('hindi')) {
      return 'hi';
    }
    if (s.startsWith('gu') || s.contains('guj') || s.contains('ગુજ')) {
      return 'gu';
    }
    return 'en';
  }

  /// 'Other', 'Others', 'Other - Parking', 'Anya: ...' (+ Gujarati / Hindi).
  static final _otherPrefix = RegExp(
      r'^(?:others?|anya|અન્ય|अन्य)(?![a-z])[\s:\-–—/.,()]*',
      caseSensitive: false);

  /// Case-insensitive: 'Maintenance' / 'Maintance' / 'Deposit' /
  /// 'Transfer fee' / 'Other' or 1/2/3/4 (5 => other). Blank => maintenance.
  /// Any other text (e.g. 'Parking charges') => other; see [otherText].
  static PaymentType parseType(String v) {
    final s = v.trim().toLowerCase();
    if (s.isEmpty || s == '1') return PaymentType.maintenance;
    if (s == '2') return PaymentType.deposit;
    if (s == '3') return PaymentType.transfer;
    if (s == '4' || s == '5' || _otherPrefix.hasMatch(s)) {
      return PaymentType.other;
    }
    bool any(List<String> keys) => keys.any(s.contains);
    // Word stems, so 'Depot' / 'Transport' / 'Transformer' are not
    // mistaken for Deposit / Transfer.
    if (any(const ['deposi', 'ડિપોઝ', 'डिपॉ', 'डिपोज'])) {
      return PaymentType.deposit;
    }
    if (any(
        const ['transfer', 'trnsfr', 'ટ્રાન્સફર', 'ट्रांसफर', 'ट्रान्सफर'])) {
      return PaymentType.transfer;
    }
    if (any(const [
      'maint', 'mant', 'mente', 'mentain', 'maitn', 'maiten', 'મેન્ટે', //
      'મેઈન્ટ', 'મેઇન્ટ', 'मेंटे', 'मेन्टे', 'मैंटे', 'मेंटन',
    ])) {
      return PaymentType.maintenance;
    }
    return PaymentType.other;
  }

  /// The "Other" details written in the type column itself:
  /// 'Parking charges' => 'Parking charges', 'Other - Parking' => 'Parking',
  /// plain 'Other' / '4' => ''. Non-other types give ''.
  static String otherText(String v) {
    final t = v.trim();
    if (parseType(t) != PaymentType.other || t == '4' || t == '5') return '';
    var rest = t.replaceFirst(_otherPrefix, '').trim();
    // 'Other (Parking)' => 'Parking'
    if (rest.endsWith(')') && !rest.contains('(')) {
      rest = rest.substring(0, rest.length - 1).trim();
    }
    return rest;
  }
}
