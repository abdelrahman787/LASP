import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/normalizer.dart';

/// Locks in the normalization rules that matching accuracy depends on.
void main() {
  group('normalizer equivalences', () {
    test('alef maqsura (ى) ≡ ya (ي)', () {
      expect(normalizeForMatch('موسى'), equals(normalizeForMatch('موسي')));
      expect(normalizeForMatch('عَصَاىَ'), equals(normalizeForMatch('عصاي')));
    });

    test('dagger-alef (الرَّحْمَٰنِ) ≡ spelled-out alef (الرحمان)', () {
      expect(normalizeForMatch('الرَّحْمَٰنِ'), equals(normalizeForMatch('الرحمان')));
      expect(normalizeForMatch('مَٰلِك'), equals(normalizeForMatch('مالك')));
    });

    test('ta marbuta (ة) ≡ ha (ه)', () {
      expect(normalizeForMatch('صلاة'), equals(normalizeForMatch('صلاه')));
      expect(normalizeForMatch('رحمة'), equals(normalizeForMatch('رحمه')));
    });

    test('alef variants (أ إ آ ٱ) unify to bare alef', () {
      final bare = normalizeForMatch('ابراهيم');
      expect(normalizeForMatch('أبراهيم'), equals(bare));
      expect(normalizeForMatch('إبراهيم'), equals(bare));
      expect(normalizeForMatch('آبراهيم'), equals(bare)); // madda → single alef
      expect(normalizeForMatch('ٱبراهيم'), equals(bare));
    });

    test('hamza carriers unify (ؤ→و, ئ→ي)', () {
      expect(normalizeForMatch('مؤمن'), equals(normalizeForMatch('مومن')));
      expect(normalizeForMatch('سئل'), equals(normalizeForMatch('سيل')));
    });
  });

  group('normalizer stripping', () {
    test('full diacritic stripping leaves bare letters', () {
      expect(normalizeForMatch('الْحَمْدُ'), equals('الحمد'));
      expect(normalizeForMatch('بِسْمِ'), equals('بسم'));
      // fathatan/dammatan/kasratan + sukun + shadda all removed
      expect(normalizeForMatch('كِتَابٌ'), equals('كتاب'));
    });

    test('tatweel (ـ) removed', () {
      expect(normalizeForMatch('الرحــــمن'), equals('الرحمن'));
    });

    test('punctuation/digits dropped, spaces collapsed, trimmed', () {
      expect(normalizeForMatch('  الحمد،   لله 123 '), equals('الحمد لله'));
    });

    test('tokenize splits on whitespace and drops empties', () {
      expect(tokenize(normalizeForMatch('  الحمد   لله ')),
          equals(['الحمد', 'لله']));
      expect(tokenize(''), isEmpty);
    });
  });
}
