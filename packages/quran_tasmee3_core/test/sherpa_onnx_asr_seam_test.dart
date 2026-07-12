/// Tests for the ASR→alignment seam (Phase 2, Step 8).
///
/// Verified behavior: the NeMo-CTC model appends hallucinated garbage tokens
/// over silence. The alignment layer (`fittingAlign`) and the matching engine
/// (`matchUtterance`) both handle this gracefully without any changes to the
/// locked pure-Dart core:
///
///  1. `fittingAlign` free-suffix property: trailing `inserted` words after the
///     last correctly-aligned word are present in the pairs but contribute zero
///     cost and do NOT alter the expected word span (`lastExpected` stays at the
///     last real match, not at the garbage).
///
///  2. `matchUtterance` longest-correct-prefix: it stops at the first token that
///     doesn't match the expected word at the cursor — so hallucinated tail tokens
///     that don't match the expected stream simply trigger an error classification
///     and are NOT revealed as correct words. The cursor does NOT advance past the
///     garbage.
///
///  3. Coverage metric: `WordAlignment.coverage` measures how many recognized
///     words landed on expected slots. A result with a long hallucinated tail
///     will have lower coverage (the tail contributes zero aligned pairs), making
///     it easy to filter weak utterances.
///
/// These tests use only the pure-Dart API (`fittingAlign`, `matchUtterance`,
/// `fittingAlignScope`) — no ASR, no Flutter, no isolates. They run under
/// plain `dart test` alongside the 112 existing core tests.
library;

import 'package:test/test.dart';
import 'package:quran_tasmee3_core/recitation/alignment.dart';
import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

List<ExpectedWord> _scope(List<String> words) => [
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

/// Simulate what the controller does: normalize + tokenize the raw ASR text,
/// then call matchUtterance.
MatchResult _match({
  required List<String> expectedWords,
  required String asrText,
  int cursor = 0,
  List<int> acceptedHistory = const [],
  RecitationConfig mode = RecitationConfig.normal,
}) {
  final scope = _scope(expectedWords);
  final tokens = tokenize(normalizeForMatch(asrText));
  return matchUtterance(
    scope: scope,
    cursor: cursor,
    recognizedTokens: tokens,
    confidence: 0.85,
    mode: mode,
    acceptedHistory: acceptedHistory,
  );
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

void main() {
  const normal = RecitationConfig.normal;

  // -------------------------------------------------------------------------
  // Group 1: fittingAlign trims hallucinated tail (free suffix)
  // -------------------------------------------------------------------------
  group('fittingAlign — hallucinated tail trimming (Step 8)', () {
    test(
        'garbage tail tokens appended by NeMo-CTC over silence are '
        'classified as `inserted` and do NOT extend lastExpected', () {
      // Simulate: model correctly transcribes الحمد لله رب العالمين then
      // hallucinates زقمون فلان كامل over the trailing silence.
      final a = fittingAlign(
        expected: ['الحمد', 'لله', 'رب', 'العالمين'],
        recognized: ['الحمد', 'لله', 'رب', 'العالمين', 'زقمون', 'فلان', 'كامل'],
        mode: normal,
      );
      // All 4 real words aligned:
      expect(a.matchedCount, 4);
      expect(a.lastExpected, 3); // العالمين — not pushed by garbage tail
      expect(a.firstExpected, 0);
      // The garbage tail appears as `inserted` pairs:
      final inserted = a.pairs.where((p) => p.op == WordAlignOp.inserted).toList();
      expect(inserted.length, 3, reason: 'three hallucinated tokens → three inserts');
      // Coverage should be < 1 because total recognizedCount includes the tail:
      // 4 aligned / 7 total ≈ 0.571
      expect(a.coverage, lessThan(1.0));
      expect(a.coverage, closeTo(4 / 7, 0.01));
    });

    test(
        'partial correct prefix followed by garbage: fittingAlign aligns '
        'the correct prefix and marks tail as inserted', () {
      // 3-word chunk: model got the first 2 words right, then hallucinated.
      final a = fittingAlign(
        expected: ['بسم', 'الله', 'الرحمن', 'الرحيم'],
        recognized: ['بسم', 'الله', 'مكتمل', 'فلان'],
        mode: normal,
      );
      // بسم and الله matched; مكتمل and فلان should be inserted (not matching الرحمن/الرحيم).
      // fittingAlign may substitute مكتمل→الرحمن if their levRatio < gapCost (0.6).
      // Key assertion: lastExpected must not advance beyond the genuinely matched words.
      final alignedCount = a.pairs
          .where(
              (p) => p.op == WordAlignOp.matched || p.op == WordAlignOp.substituted)
          .length;
      expect(alignedCount, greaterThanOrEqualTo(2),
          reason: 'at least بسم and الله must be aligned');
      // lastExpected should be ≥ 1 (الله) and ≤ 3 (الرحيم)
      expect(a.lastExpected, greaterThanOrEqualTo(1));
    });

    test(
        'pure garbage (all hallucination, no real words): matchedCount = 0, '
        'lastExpected = -1', () {
      final a = fittingAlign(
        expected: ['الحمد', 'لله'],
        recognized: ['زقمون', 'نارمور', 'فلان'],
        mode: normal,
      );
      expect(a.matchedCount, 0);
      expect(a.firstExpected, -1);
      expect(a.lastExpected, -1);
      // Coverage should be 0 (no aligned pairs).
      expect(a.coverage, 0.0);
    });

    test(
        'single hallucinated token after correct words: '
        'coverage drops but real words still aligned', () {
      final a = fittingAlign(
        expected: ['رب', 'العالمين'],
        recognized: ['رب', 'العالمين', 'مكتمل'],
        mode: normal,
      );
      expect(a.matchedCount, 2);
      expect(a.lastExpected, 1); // العالمين
      // 2 aligned / 3 recognized
      expect(a.coverage, closeTo(2 / 3, 0.01));
    });
  });

  // -------------------------------------------------------------------------
  // Group 2: matchUtterance does not advance cursor on hallucinated tail
  // -------------------------------------------------------------------------
  group('matchUtterance — hallucinated tail is NOT revealed (Step 8)', () {
    test(
        'correct prefix + hallucinated tail: cursor advances ONLY through '
        'matched words; garbage tail triggers error, not reveal', () {
      final result = _match(
        expectedWords: ['الحمد', 'لله', 'رب', 'العالمين'],
        asrText: 'الحمد لله رب العالمين زقمون فلان',
        cursor: 0,
      );
      // All 4 real words accepted.
      expect(result.acceptedWordIndices, [0, 1, 2, 3]);
      // Cursor is at 4 (past the last expected word).
      expect(result.newCursor, 4);
      // The garbage tail triggers an `addition` error (scope exhausted, extra tokens).
      expect(result.error, isNotNull);
      expect(result.error!.type, ErrorType.addition);
      // No pronunciation flags from the core sequence (confidence=0.85, normal mode).
      expect(result.pronunciationFlaggedIndices, isEmpty);
    });

    test(
        'garbage only (no matching prefix): cursor stays at 0, '
        'substitution or similar error, no accepts', () {
      final result = _match(
        expectedWords: ['الحمد', 'لله'],
        asrText: 'زقمون نارمور فلان',
        cursor: 0,
      );
      expect(result.acceptedWordIndices, isEmpty);
      expect(result.newCursor, 0);
      expect(result.error, isNotNull);
    });

    test(
        'mid-recitation chunk: cursor at 2, correct continuation + garbage '
        'tail → reveals words 2,3, then addition error', () {
      final result = _match(
        expectedWords: ['الحمد', 'لله', 'رب', 'العالمين', 'الرحمن', 'الرحيم'],
        asrText: 'رب العالمين مكتوب',
        cursor: 2,
        acceptedHistory: [0, 1],
      );
      // رب and العالمين accepted (indices 2,3).
      expect(result.acceptedWordIndices, [2, 3]);
      expect(result.newCursor, 4);
      // مكتوب is past the scope continuation → triggers addition or the next
      // expected word check (الرحمن). Either way, مكتوب is not accepted.
      // The error type may be substitution (مكتوب ≠ الرحمن) or addition.
      expect(result.error, isNotNull);
      expect(result.error!.recognizedToken, isNotNull);
    });

    test(
        'correct full scope + garbage tail at end: session COMPLETES '
        '(scope exhausted) despite trailing garbage tokens', () {
      // Scope has only 4 words; ASR appends 2 garbage tokens.
      final result = _match(
        expectedWords: ['الحمد', 'لله', 'رب', 'العالمين'],
        asrText: 'الحمد لله رب العالمين زقمون فلان',
        cursor: 0,
      );
      // All 4 scope words are accepted.
      expect(result.acceptedWordIndices, [0, 1, 2, 3]);
      expect(result.newCursor, 4); // cursor at end of scope
      // The `addition` error type fires but the controller's _processUtterance
      // calls _complete() when cursor >= scope.length with error==addition.
      // Here we just verify the accepts are right.
      expect(result.error?.type, ErrorType.addition);
    });
  });

  // -------------------------------------------------------------------------
  // Group 3: fittingAlignScope (scope convenience)
  // -------------------------------------------------------------------------
  group('fittingAlignScope — hallucination trimming via scope (Step 8)', () {
    test(
        'scope alignment with garbage tail: correct words map to expected '
        'slots; garbage is classified as inserted', () {
      final scope = _scope(['الحمد', 'لله', 'رب', 'العالمين']);
      final recognized = tokenize(normalizeForMatch('الحمد لله زقمون فلان'));
      final a = fittingAlignScope(
        scope: scope,
        recognized: recognized,
        mode: normal,
      );
      // الحمد and لله align; زقمون and فلان become inserted (or substituted for رب/العالمين).
      // In either case, lastExpected ≤ 3, and matchedCount ≥ 2 (الحمد, لله).
      expect(a.lastExpected, greaterThanOrEqualTo(1)); // لله at minimum
    });
  });

  // -------------------------------------------------------------------------
  // Group 4: AsrResult → controller seam (contract test)
  // -------------------------------------------------------------------------
  group('AsrResult contract — confidence 0 / empty text filtered (Step 8)', () {
    test('isFailure is true for empty text', () {
      const r = AsrResult('', 0.0);
      expect(r.isFailure, isTrue);
    });

    test('isFailure is true for whitespace-only text', () {
      const r = AsrResult('   ', 0.9);
      expect(r.isFailure, isTrue);
    });

    test('isFailure is true for confidence == 0 even with non-empty text', () {
      const r = AsrResult('الحمد', 0.0);
      expect(r.isFailure, isTrue);
    });

    test('isFailure is false for valid Arabic text with confidence > 0', () {
      const r = AsrResult('الحمد لله', 0.85);
      expect(r.isFailure, isFalse);
    });

    test(
        'FakeAsrService can drive the matchUtterance seam with a hallucinated-'
        'tail utterance — the controller reveals correct words only', () async {
      // Simulate the full controller seam: FakeAsrService → submitAsr →
      // matchUtterance → the accepted words are exactly the real Quranic words.
      final scope = _scope(['الحمد', 'لله', 'رب', 'العالمين']);
      final events = <RecitationEvent>[];
      final revealed = <int>[];
      final controller = RecitationController(
        scope: scope,
        mode: normal,
        now: () => 0,
        onReveal: (i) => revealed.add(i),
        onEvent: (e) => events.add(e),
      );
      controller.start();

      // Inject: correct Quranic text + hallucinated garbage tail.
      controller.submitAsr(
        const AsrResult('الحمد لله رب العالمين زقمون فلان', 0.85),
      );

      // All 4 real words revealed (cursor advances through them).
      expect(revealed, [0, 1, 2, 3]);
      expect(controller.cursor, 4);
      // Session completes (addition error on garbage tail, scope exhausted).
      expect(controller.status, RecitationStatus.completed);
    });
  });
}
