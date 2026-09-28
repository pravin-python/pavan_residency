import 'package:flutter_test/flutter_test.dart';
import 'package:pavan_residency/services/amount_words.dart';

void main() {
  group('amountToWords', () {
    test('English', () {
      expect(
          amountToWords(1500, 'en'), 'One Thousand Five Hundred Rupees Only');
      expect(amountToWords(125750, 'en'),
          'One Lakh Twenty Five Thousand Seven Hundred Fifty Rupees Only');
      expect(amountToWords(10000000, 'en'), 'One Crore Rupees Only');
      expect(amountToWords(0, 'en'), 'Zero Rupees Only');
    });

    test('Gujarati', () {
      expect(amountToWords(1500, 'gu'), 'એક હજાર પાંચ સો પૂરા');
      expect(amountToWords(99, 'gu'), 'નવ્વાણું પૂરા');
      expect(amountToWords(705, 'gu'), 'સાત સો પાંચ પૂરા');
    });

    test('Hindi', () {
      expect(amountToWords(1500, 'hi'), 'एक हज़ार पाँच सौ रुपये मात्र');
      expect(
          amountToWords(20579, 'hi'), 'बीस हज़ार पाँच सौ उन्यासी रुपये मात्र');
    });

    test('word tables are complete (index 1..99)', () {
      for (var i = 1; i <= 99; i++) {
        expect(amountToWords(i, 'gu').trim().isNotEmpty, true);
        expect(amountToWords(i, 'hi').trim().isNotEmpty, true);
        expect(amountToWords(i, 'en').trim().isNotEmpty, true);
      }
    });
  });

  group('formatIndian', () {
    test('grouping', () {
      expect(formatIndian(1500), '1,500');
      expect(formatIndian(125750), '1,25,750');
      expect(formatIndian(10000000), '1,00,00,000');
      expect(formatIndian(999), '999');
    });
  });
}
