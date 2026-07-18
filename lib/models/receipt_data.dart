enum PaymentType { maintenance, deposit, transfer, other }

enum SendStatus { ready, invalid, sending, sent, error }

class ReceiptData {
  String lang; // 'gu' | 'hi' | 'en'
  String name;
  String email;
  String block;
  String house;
  double amount;
  PaymentType type;
  String chqNo;
  String chqBank;
  int recNo;
  String date; // dd-MM-yyyy
  SendStatus status;
  String error;

  ReceiptData({
    this.lang = 'gu',
    this.name = '',
    this.email = '',
    this.block = '',
    this.house = '',
    this.amount = 0,
    this.type = PaymentType.maintenance,
    this.chqNo = '',
    this.chqBank = '',
    this.recNo = 0,
    this.date = '',
    this.status = SendStatus.ready,
    this.error = '',
  });

  bool get isValid => name.isNotEmpty && email.isNotEmpty && amount > 0;

  /// 'gujarati' / 'hindi' / 'english' / 'gu' / 'hi' / 'en' / native names.
  static String parseLang(String v) {
    final s = v.trim().toLowerCase();
    if (s.startsWith('hi') || s.contains('हि') || s.contains('hindi')) {
      return 'hi';
    }
    if (s.startsWith('en') || s.contains('english')) return 'en';
    return 'gu';
  }

  /// 'maintenance' / 'deposit' / 'transfer' / 'other' or 1/2/3/4 (5 => other).
  static PaymentType parseType(String v) {
    final s = v.trim().toLowerCase();
    if (s == '2' || s.contains('depo')) return PaymentType.deposit;
    if (s == '3' || s.contains('trans')) return PaymentType.transfer;
    if (s == '4' || s == '5' || s.contains('other') || s.contains('anya')) {
      return PaymentType.other;
    }
    return PaymentType.maintenance;
  }
}
