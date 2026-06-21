import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/distance.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';

/// Build a scope from a list of already-normalized words. Assigns sequential
/// wordIndex within ayah 1 of surah 1 for convenience (the engine only cares
/// about `norm` + position).
List<ExpectedWord> scopeFromWords(List<String> words, {int surah = 1, int ayah = 1}) {
  return [
    for (var i = 0; i < words.length; i++)
      ExpectedWord(
        wordId: '$surah:$ayah:${i + 1}',
        surah: surah,
        ayah: ayah,
        wordIndex: i + 1,
        norm: words[i],
      ),
  ];
}

void main() {
  group('normalizer', () {
    test('diacritics removed: أَلْحَمْدُ == الحمد', () {
      expect(normalizeForMatch('أَلْحَمْدُ'), equals(normalizeForMatch('الحمد')));
    });

    test('alef maksura + diacritics: عَصَاىَ == عصاي', () {
      expect(normalizeForMatch('عَصَاىَ'), equals(normalizeForMatch('عصاي')));
    });

    test('tatweel removed', () {
      expect(normalizeForMatch('الـــحمد'), equals('الحمد'));
    });

    test('dagger alef (U+0670) maps to a full alef so مَٰلِك matches مالك', () {
      expect(normalizeForMatch('مَٰلِكِ'), equals('مالك'));
      expect(normalizeForMatch('مَٰلِكِ'), equals(normalizeForMatch('مالك')));
      // Surah 1:4 "مالك يوم الدين" must be an exact match in normal mode.
      final scope = scopeFromWords(
        ['مَٰلِكِ', 'يَوْمِ', 'ٱلدِّينِ'].map(normalizeForMatch).toList(),
      );
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: tokenize(normalizeForMatch('مالك يوم الدين')),
        confidence: 0.87,
        mode: RecitationConfig.normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0, 1, 2]));
      expect(r.error, isNull);
    });

    test('alef variants unify', () {
      expect(normalizeForMatch('أنا'), equals(normalizeForMatch('انا')));
      expect(normalizeForMatch('إنا'), equals(normalizeForMatch('انا')));
      expect(normalizeForMatch('آمن'), equals(normalizeForMatch('امن')));
      expect(normalizeForMatch('ٱلله'), equals(normalizeForMatch('الله')));
    });

    test('ta marbuta → ha; hamza carriers unify', () {
      expect(normalizeForMatch('صلاة'), equals(normalizeForMatch('صلاه')));
      expect(normalizeForMatch('مؤمن'), equals(normalizeForMatch('مومن')));
      expect(normalizeForMatch('ئر'), equals(normalizeForMatch('ير')));
    });

    test('punctuation/digits stripped, spaces collapsed, trimmed', () {
      expect(normalizeForMatch('  الحمد،   لله 123 '), equals('الحمد لله'));
    });

    test('tokenize drops empties', () {
      expect(tokenize('الحمد لله'), equals(['الحمد', 'لله']));
      expect(tokenize(''), isEmpty);
    });
  });

  group('distance', () {
    test('levenshtein basics', () {
      expect(levenshtein('', ''), 0);
      expect(levenshtein('abc', 'abc'), 0);
      expect(levenshtein('abc', 'abd'), 1);
      expect(levenshtein('kitten', 'sitting'), 3);
    });

    test('levRatio both empty is 0', () {
      expect(levRatio('', ''), 0.0);
    });

    test('levRatio scales by max length', () {
      expect(levRatio('abcd', 'abce'), closeTo(0.25, 1e-9));
    });
  });

  // Helper that normalizes a recited string into tokens the way the controller
  // would before calling the engine.
  List<String> recite(String s) => tokenize(normalizeForMatch(s));

  group('matchUtterance', () {
    final normal = RecitationConfig.normal;

    test('exact single word accepted, cursor advances by 1', () {
      final scope = scopeFromWords([normalizeForMatch('الحمد')]);
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('الحمد'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0]));
      expect(r.newCursor, 1);
      expect(r.error, isNull);
      expect(r.wasContextReplay, isFalse);
    });

    test('multi-word one breath: all four accepted, no error', () {
      final scope = scopeFromWords(
        ['الحمد', 'لله', 'رب', 'العالمين'].map(normalizeForMatch).toList(),
      );
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('الحمد لله رب العالمين'),
        confidence: 0.95,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0, 1, 2, 3]));
      expect(r.newCursor, 4);
      expect(r.error, isNull);
    });

    test('substitution: عصاي vs عصاتي beyond threshold, no later match', () {
      final scope = scopeFromWords([normalizeForMatch('عصاي')]);
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('عصاتي'),
        confidence: 0.9,
        mode: RecitationConfig.strict, // tight threshold so it cannot match
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, isEmpty);
      expect(r.error, isNotNull);
      expect(r.error!.type, ErrorType.substitution);
      expect(r.error!.expectedIndex, 0);
    });

    test('one wrong word mid-utterance → prefix accepted, substitution flagged',
        () {
      // Otherwise-normal flow: "بسم الله <wrong> الرحيم". The first two words
      // accept, then a clearly-wrong word in place of الرحمن must be classified
      // as a substitution — not silently absorbed/dropped.
      final scope = scopeFromWords(
        ['بسم', 'الله', 'الرحمن', 'الرحيم'].map(normalizeForMatch).toList(),
      );
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('بسم الله زقمون الرحيم'),
        confidence: 0.95,
        mode: RecitationConfig.normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0, 1]), reason: 'prefix accepted');
      expect(r.error, isNotNull);
      expect(r.error!.type, ErrorType.substitution);
      expect(r.error!.expectedIndex, 2, reason: 'stopped at the wrong word');
    });

    test('pronunciation: within threshold but low confidence in strict → '
        'accepted + flagged, not rejected', () {
      // A short madd/tajweed variant that stays within strict levThreshold.
      // الرحمن vs الرحمان differ by one inserted alef → ratio = 1/7 ≈ 0.143,
      // which is > strict (0.10). Use a 1-char diff over a longer word so the
      // ratio is under 0.10... instead use normal-ish: pick a word where a
      // single-char tajweed diff is within strict threshold.
      final word = normalizeForMatch('العالمين'); // 8 letters
      // recite with a single diacritic-only change (normalizes identical) but
      // force low confidence:
      final scope = scopeFromWords([word]);
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('العالمين'),
        confidence: 0.50, // below strict confFloor 0.85
        mode: RecitationConfig.strict,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0]), reason: 'still revealed');
      expect(r.error, isNull, reason: 'low confidence never rejects');
      expect(r.pronunciationFlaggedIndices, equals([0]),
          reason: 'flagged as pronunciation');
    });

    test('order error: reciting a word that appears later in scope', () {
      final scope = scopeFromWords(
        ['رب', 'العالمين', 'الرحمن'].map(normalizeForMatch).toList(),
      );
      // At cursor 0 (expected رب) the student says العالمين (which is scope[1]).
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('العالمين'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, isEmpty);
      expect(r.error, isNotNull);
      expect(r.error!.type, ErrorType.order);
      expect(r.error!.expectedIndex, 0);
    });

    test('order look-ahead is bounded: a match far beyond the window is a '
        'substitution, not an order error', () {
      // Distinct filler words (no digits — those are stripped by the
      // normalizer), with the spoken target only at index 20 (far ahead).
      String filler(int i) => 'سن${String.fromCharCode(0x0628 + i)}';
      final words = [
        for (var i = 0; i < 20; i++) filler(i),
        'نستعين', // index 20, beyond the 8-word window
      ].map(normalizeForMatch).toList();
      final scope = scopeFromWords(words);
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('نستعين'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r.error, isNotNull);
      expect(r.error!.type, ErrorType.substitution,
          reason: 'beyond the look-ahead window → substitution');

      // A match INSIDE the window (index 5) is still an order error.
      final r2 = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: [normalizeForMatch(filler(5))],
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r2.error!.type, ErrorType.order);
    });

    test('context replay: leading accepted words absorbed, continuation '
        'accepted, no error', () {
      // scope: قال فمن ربكما يا موسى
      final scope = scopeFromWords(
        ['قال', 'فمن', 'ربكما', 'يا', 'موسى'].map(normalizeForMatch).toList(),
      );
      // Already accepted first three (indices 0,1,2); cursor at 3.
      final r = matchUtterance(
        scope: scope,
        cursor: 3,
        recognizedTokens: recite('قال فمن ربكما يا موسى'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [0, 1, 2],
      );
      expect(r.wasContextReplay, isTrue);
      expect(r.acceptedWordIndices, equals([3, 4]));
      expect(r.newCursor, 5);
      expect(r.error, isNull);
    });

    test('partial context replay: only trailing accepted word repeated', () {
      final scope = scopeFromWords(
        ['قال', 'فمن', 'ربكما', 'يا', 'موسى'].map(normalizeForMatch).toList(),
      );
      // Repeat only the last accepted word ربكما, then continue.
      final r = matchUtterance(
        scope: scope,
        cursor: 3,
        recognizedTokens: recite('ربكما يا موسى'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [0, 1, 2],
      );
      expect(r.wasContextReplay, isTrue);
      expect(r.acceptedWordIndices, equals([3, 4]));
      expect(r.error, isNull);
    });

    test('addition: trailing out-of-scope words after scope exhausted', () {
      final scope = scopeFromWords(['الحمد', 'لله'].map(normalizeForMatch).toList());
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('الحمد لله زيادة'),
        confidence: 0.9,
        mode: normal,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0, 1]));
      expect(r.newCursor, 2);
      expect(r.error, isNotNull);
      expect(r.error!.type, ErrorType.addition);
    });

    test('prefix accepted then stop at first error', () {
      final scope = scopeFromWords(
        ['الحمد', 'لله', 'رب', 'العالمين'].map(normalizeForMatch).toList(),
      );
      // Correct first two, then a clear substitution that matches nothing ahead.
      final r = matchUtterance(
        scope: scope,
        cursor: 0,
        recognizedTokens: recite('الحمد لله زقمون'),
        confidence: 0.9,
        mode: RecitationConfig.strict,
        acceptedHistory: const [],
      );
      expect(r.acceptedWordIndices, equals([0, 1]));
      expect(r.newCursor, 2);
      expect(r.error!.type, ErrorType.substitution);
      expect(r.error!.expectedIndex, 2);
    });
  });

  group('findBestAnchor', () {
    final normal = RecitationConfig.normal;
    final scope = scopeFromWords(
      ['الحمد', 'لله', 'رب', 'العالمين', 'الرحمن', 'الرحيم']
          .map(normalizeForMatch)
          .toList(),
    );

    test('finds a matching segment ahead of the cursor', () {
      final a = findBestAnchor(
        scope: scope,
        recognizedTokens: recite('رب العالمين'),
        mode: normal,
      );
      expect(a, isNotNull);
      expect(a!.startIndex, 2);
      expect(a.matchedCount, 2);
      expect(a.fraction, closeTo(1.0, 1e-9));
    });

    test('returns null when below minWords/minFraction', () {
      // Single common word only → not enough to confidently re-anchor.
      final a = findBestAnchor(
        scope: scope,
        recognizedTokens: recite('رب زقمون فلان'),
        mode: normal,
      );
      expect(a, isNull);
    });

    test('returns null when nothing matches', () {
      final a = findBestAnchor(
        scope: scope,
        recognizedTokens: recite('زقمون فلان'),
        mode: normal,
      );
      expect(a, isNull);
    });
  });
}
