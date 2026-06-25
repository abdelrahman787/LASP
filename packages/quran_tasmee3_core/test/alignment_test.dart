import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/alignment.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';

/// Build a scope of ExpectedWords from raw (display) words.
List<ExpectedWord> scopeOf(List<String> words) => [
      for (var i = 0; i < words.length; i++)
        ExpectedWord(
          wordId: '1:1:${i + 1}',
          surah: 1,
          ayah: 1,
          wordIndex: i + 1,
          norm: normalizeForMatch(words[i]),
          display: words[i],
        ),
    ];

void main() {
  const normal = RecitationConfig.normal;

  group('fittingAlign — Needleman-Wunsch with free prefix gap', () {
    test('clean contiguous recitation: every word matched, indices map 1:1', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله', 'رب', 'العالمين'],
        recognized: ['الحمد', 'لله', 'رب', 'العالمين'],
        mode: normal,
      );
      expect(a.pairs.every((p) => p.op == WordAlignOp.matched), isTrue);
      expect(a.expectedToRecognized, {0: 0, 1: 1, 2: 2, 3: 3});
      expect(a.firstExpected, 0);
      expect(a.lastExpected, 3);
      expect(a.matchedCount, 4);
    });

    test('FREE PREFIX: reciting from the middle of the page is not penalised '
        'and leading words are NOT reported as omitted', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله', 'رب', 'العالمين', 'الرحمن', 'الرحيم'],
        recognized: ['رب', 'العالمين'], // started mid-page
        mode: normal,
      );
      // No omitted ops for the skipped leading (0,1) or trailing (4,5).
      expect(a.pairs.where((p) => p.op == WordAlignOp.omitted), isEmpty);
      expect(a.expectedToRecognized, {2: 0, 3: 1});
      expect(a.firstExpected, 2);
      expect(a.lastExpected, 3);
    });

    test('middle omission → the skipped expected word is `omitted`', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله', 'رب', 'العالمين'],
        recognized: ['الحمد', 'لله', 'العالمين'], // skipped رب
        mode: normal,
      );
      final omitted =
          a.pairs.where((p) => p.op == WordAlignOp.omitted).toList();
      expect(omitted.length, 1);
      expect(omitted.single.expectedIndex, 2); // رب
      expect(a.expectedToRecognized, {0: 0, 1: 1, 3: 2});
    });

    test('extra recited word → `inserted` (context replay is not an error)', () {
      final a = fittingAlign(
        expected: ['رب', 'العالمين'],
        recognized: ['رب', 'رب', 'العالمين'], // repeated رب
        mode: normal,
      );
      final inserted =
          a.pairs.where((p) => p.op == WordAlignOp.inserted).toList();
      expect(inserted.length, 1);
      expect(inserted.single.recognizedIndex, isNonNegative);
      expect(a.matchedCount, 2);
    });

    test('wrong word in place → `substituted`, mapped to the right expected', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله', 'رب', 'العالمين'],
        recognized: ['الحمد', 'لله', 'زقمون', 'العالمين'],
        mode: normal,
      );
      final sub = a.pairs.where((p) => p.op == WordAlignOp.substituted).toList();
      expect(sub.length, 1);
      expect(sub.single.expectedIndex, 2); // رب slot
      expect(sub.single.recognizedIndex, 2);
      expect(a.matchedCount, 3);
    });
  });

  group('alef-insensitive matching (imlaei ↔ Uthmani)', () {
    test('ابراهيم (imlaei) matches إبراهيم (Uthmani) — alef hamza unified', () {
      // Different alef forms; normalizeForMatch unifies them, so fittingAlign
      // (which scores on normalized forms) treats them as identical.
      expect(normalizeForMatch('إبراهيم'), normalizeForMatch('ابراهيم'));
      final a = fittingAlign(
        expected: ['قال', 'إبراهيم', 'رب'], // mushaf Uthmani
        recognized: ['قال', 'ابراهيم', 'رب'], // model imlaei
        mode: RecitationConfig.strict, // even strict must match
      );
      expect(a.pairs.every((p) => p.op == WordAlignOp.matched), isTrue,
          reason: 'alef variants must not count as a mistake');
    });
  });

  group('Gate-0 model slips still map to the correct expected word', () {
    test('recognized فويت vs expected فبهت → substituted at the same slot', () {
      final a = fittingAlign(
        expected: ['فبهت', 'الذي', 'كفر'],
        recognized: ['فويت', 'الذي', 'كفر'],
        mode: normal,
      );
      expect(a.pairs.first.op, WordAlignOp.substituted);
      expect(a.pairs.first.expectedIndex, 0);
      expect(a.pairs.first.recognizedIndex, 0);
      expect(a.expectedToRecognized[1], 1);
      expect(a.expectedToRecognized[2], 2);
    });

    test('recognized "لم يتسم" vs expected "لم يتسنه" → يتسنه substituted', () {
      final a = fittingAlign(
        expected: ['لم', 'يتسنه'],
        recognized: ['لم', 'يتسم'],
        mode: normal,
      );
      expect(a.expectedToRecognized[0], 0); // لم matched
      final p1 = a.pairs.firstWhere((p) => p.expectedIndex == 1);
      expect(p1.op, WordAlignOp.substituted);
      expect(p1.recognizedIndex, 1); // mapped to the correct slot, not dropped
    });
  });

  group('scope convenience + nothing-matches', () {
    test('fittingAlignScope aligns recognized tokens to an ExpectedWord scope',
        () {
      final scope = scopeOf(['الحمد', 'لله', 'رب', 'العالمين']);
      final a = fittingAlignScope(
        scope: scope,
        recognized: tokenize(normalizeForMatch('لله رب')),
        mode: normal,
      );
      expect(a.expectedToRecognized, {1: 0, 2: 1});
      expect(a.firstExpected, 1);
      expect(a.lastExpected, 2);
    });

    test('total garbage → no matches, empty span', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله'],
        recognized: ['زقمون', 'فلان'],
        mode: normal,
      );
      expect(a.matchedCount, 0);
      expect(a.firstExpected, -1);
      expect(a.lastExpected, -1);
    });
  });

  group('forced-alignment seam (Phase 2 fills in real CTC Viterbi)', () {
    test('UniformForcedAligner returns one monotonic, non-overlapping span '
        'per word covering the whole audio', () {
      const aligner = UniformForcedAligner();
      final spans = aligner.alignWords(
        words: ['الحمد', 'لله', 'رب'],
        frameTokenIds: List<int>.filled(300, 0), // 300 frames
        secondsPerFrame: 0.01, // 3.0s total
      );
      expect(spans.length, 3);
      expect(spans.first.startSec, 0.0);
      expect(spans.last.endSec, closeTo(3.0, 1e-9));
      for (var i = 1; i < spans.length; i++) {
        expect(spans[i].wordIndex, i);
        expect(spans[i].startSec, greaterThanOrEqualTo(spans[i - 1].endSec));
      }
    });

    test('empty words → no spans', () {
      const aligner = UniformForcedAligner();
      expect(
        aligner.alignWords(
            words: const [], frameTokenIds: const [], secondsPerFrame: 0.01),
        isEmpty,
      );
    });
  });
}
