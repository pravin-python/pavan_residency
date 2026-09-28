/// Amount to words - Indian numbering system (crore/lakh) in gu / hi / en.
library;

const List<String> _en1 = [
  '',
  'One',
  'Two',
  'Three',
  'Four',
  'Five',
  'Six',
  'Seven',
  'Eight',
  'Nine',
  'Ten',
  'Eleven',
  'Twelve',
  'Thirteen',
  'Fourteen',
  'Fifteen',
  'Sixteen',
  'Seventeen',
  'Eighteen',
  'Nineteen'
];
const List<String> _en10 = [
  '',
  '',
  'Twenty',
  'Thirty',
  'Forty',
  'Fifty',
  'Sixty',
  'Seventy',
  'Eighty',
  'Ninety'
];

// index == number (1..99); index 0 unused.
final List<String> _gu99 = ''
        ' એક બે ત્રણ ચાર પાંચ છ સાત આઠ નવ દસ'
        ' અગિયાર બાર તેર ચૌદ પંદર સોળ સત્તર અઢાર ઓગણીસ વીસ'
        ' એકવીસ બાવીસ ત્રેવીસ ચોવીસ પચીસ છવ્વીસ સત્તાવીસ અઠ્ઠાવીસ ઓગણત્રીસ ત્રીસ'
        ' એકત્રીસ બત્રીસ તેત્રીસ ચોત્રીસ પાંત્રીસ છત્રીસ સાડત્રીસ આડત્રીસ ઓગણચાલીસ ચાલીસ'
        ' એકતાલીસ બેતાલીસ તેતાલીસ ચુમાલીસ પિસ્તાલીસ છેતાલીસ સુડતાલીસ અડતાલીસ ઓગણપચાસ પચાસ'
        ' એકાવન બાવન ત્રેપન ચોપન પંચાવન છપ્પન સત્તાવન અઠ્ઠાવન ઓગણસાઠ સાઠ'
        ' એકસઠ બાસઠ ત્રેસઠ ચોસઠ પાંસઠ છાસઠ સડસઠ અડસઠ ઓગણોતેર સિત્તેર'
        ' એકોતેર બોતેર તોતેર ચુમોતેર પંચોતેર છોતેર સિત્યોતેર ઇઠ્યોતેર ઓગણાએંસી એંસી'
        ' એક્યાસી બ્યાસી ત્યાસી ચોર્યાસી પંચાસી છ્યાસી સિત્યાસી ઈઠ્યાસી નેવ્યાસી નેવું'
        ' એકાણું બાણું ત્રાણું ચોરાણું પંચાણું છન્નું સત્તાણું અઠ્ઠાણું નવ્વાણું'
    .split(' ');

final List<String> _hi99 = ''
        ' एक दो तीन चार पाँच छह सात आठ नौ दस'
        ' ग्यारह बारह तेरह चौदह पंद्रह सोलह सत्रह अठारह उन्नीस बीस'
        ' इक्कीस बाईस तेईस चौबीस पच्चीस छब्बीस सत्ताईस अट्ठाईस उनतीस तीस'
        ' इकतीस बत्तीस तैंतीस चौंतीस पैंतीस छत्तीस सैंतीस अड़तीस उनतालीस चालीस'
        ' इकतालीस बयालीस तैंतालीस चवालीस पैंतालीस छियालीस सैंतालीस अड़तालीस उनचास पचास'
        ' इक्यावन बावन तिरपन चौवन पचपन छप्पन सत्तावन अट्ठावन उनसठ साठ'
        ' इकसठ बासठ तिरसठ चौंसठ पैंसठ छियासठ सड़सठ अड़सठ उनहत्तर सत्तर'
        ' इकहत्तर बहत्तर तिहत्तर चौहत्तर पचहत्तर छिहत्तर सतहत्तर अठहत्तर उन्यासी अस्सी'
        ' इक्यासी बयासी तिरासी चौरासी पचासी छियासी सत्तासी अट्ठासी नवासी नब्बे'
        ' इक्यानवे बानवे तिरानवे चौरानवे पचानवे छियानवे सत्तानवे अट्ठानवे निन्यानवे'
    .split(' ');

const Map<String, List<String>> _units = {
  'en': ['Crore', 'Lakh', 'Thousand', 'Hundred'],
  'gu': ['કરોડ', 'લાખ', 'હજાર', 'સો'],
  'hi': ['करोड़', 'लाख', 'हज़ार', 'सौ'],
};
const Map<String, String> _suffix = {
  'en': ' Rupees Only',
  'gu': ' પૂરા',
  'hi': ' रुपये मात्र',
};
const Map<String, String> _zero = {'en': 'Zero', 'gu': 'શૂન્ય', 'hi': 'शून्य'};

String _two(int n, String lang) {
  if (n == 0) return '';
  if (lang == 'en') {
    if (n < 20) return _en1[n];
    return _en10[n ~/ 10] + (n % 10 != 0 ? ' ${_en1[n % 10]}' : '');
  }
  return lang == 'gu' ? _gu99[n] : _hi99[n];
}

/// e.g. amountToWords(125750, 'en') =>
/// 'One Lakh Twenty Five Thousand Seven Hundred Fifty Rupees Only'
String amountToWords(num amount, String lang) {
  int n = amount.round();
  if (n == 0) return _zero[lang]! + _suffix[lang]!;
  final u = _units[lang]!;
  final parts = <String>[];
  final crore = n ~/ 10000000;
  n %= 10000000;
  final lakh = n ~/ 100000;
  n %= 100000;
  final thou = n ~/ 1000;
  n %= 1000;
  final hund = n ~/ 100;
  n %= 100;
  if (crore > 0) parts.add('${_two(crore, lang)} ${u[0]}');
  if (lakh > 0) parts.add('${_two(lakh, lang)} ${u[1]}');
  if (thou > 0) parts.add('${_two(thou, lang)} ${u[2]}');
  if (hund > 0) parts.add('${_two(hund, lang)} ${u[3]}');
  if (n > 0) parts.add(_two(n, lang));
  return parts.join(' ') + _suffix[lang]!;
}

/// 125750 -> '1,25,750' (Indian digit grouping)
String formatIndian(num amount) {
  final s = amount.round().toString();
  if (s.length <= 3) return s;
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final groups = <String>[];
  while (rest.length > 2) {
    groups.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) groups.insert(0, rest);
  return '${groups.join(',')},$last3';
}
