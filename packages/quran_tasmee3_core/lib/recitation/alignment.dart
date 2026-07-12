/// Word-level alignment for the recitation matching engine (Phase 1, the new
/// FastConformer-CTC pipeline).
///
/// Ports the LOGIC of the model card's `fitting_align` (Needleman-Wunsch with a
/// free prefix gap) and `ctc_forced_align` (Viterbi) to pure Dart, adapted to
/// **word-level** matching. No audio / ONNX / Flutter here — this stays runnable
/// under plain `dart test`.
///
/// Locked decisions honored (CLAUDE.md):
///  - Scoring is alef-insensitive: words are normalized via [normalizeForMatch]
///    for cost ONLY; the original (display) words are never altered.
///  - Context replay is not an error: an extra recited word is an `inserted` op,
///    not a mistake — the classifier upstream decides what to do with it.
///  - `forget` is never produced here; `omitted` is a neutral alignment fact the
///    controller maps to its own classes (e.g. silence-forget / asrLag).
library;

import 'distance.dart';
import 'matching_engine.dart' show ExpectedWord;
import 'normalizer.dart';
import 'recitation_config.dart';

/// One cell in a word alignment.
enum WordAlignOp {
  /// Expected ≈ recognized (levRatio ≤ mode.levThreshold).
  matched,

  /// Expected and recognized are aligned to the same slot but differ.
  substituted,

  /// An expected word with no recognized counterpart, INSIDE the recited span
  /// (a gap in the recitation). Leading/trailing un-recited words are NOT
  /// reported (free prefix/suffix).
  omitted,

  /// A recited word with no expected counterpart (extra word / context replay).
  inserted,
}

/// A single aligned pair. [expectedIndex] is -1 for `inserted`; [recognizedIndex]
/// is -1 for `omitted`.
class AlignedPair {
  final WordAlignOp op;
  final int expectedIndex;
  final int recognizedIndex;

  /// Word match score in `[0,1]` (1 = identical) for matched/substituted; 0 for
  /// omitted/inserted. Derived from `1 - levRatio`.
  final double score;

  const AlignedPair({
    required this.op,
    required this.expectedIndex,
    required this.recognizedIndex,
    required this.score,
  });

  @override
  String toString() =>
      'AlignedPair(${op.name} e=$expectedIndex r=$recognizedIndex '
      's=${score.toStringAsFixed(2)})';
}

/// The result of [fittingAlign].
class WordAlignment {
  /// Ops within the recited span, in expected/recognized order.
  final List<AlignedPair> pairs;

  /// expectedIndex → recognizedIndex for matched AND substituted words.
  final Map<int, int> expectedToRecognized;

  /// First/last expected index that was aligned (matched or substituted), or -1.
  final int firstExpected;
  final int lastExpected;

  /// Number of `matched` ops (exact-enough words).
  final int matchedCount;

  /// Number of recognized words fed in.
  final int recognizedCount;

  const WordAlignment({
    required this.pairs,
    required this.expectedToRecognized,
    required this.firstExpected,
    required this.lastExpected,
    required this.matchedCount,
    required this.recognizedCount,
  });

  /// Fraction of recognized words that landed on an expected slot (matched or
  /// substituted) — a confidence proxy for "this utterance fits here".
  double get coverage {
    if (recognizedCount == 0) return 0;
    final aligned = pairs
        .where((p) =>
            p.op == WordAlignOp.matched || p.op == WordAlignOp.substituted)
        .length;
    return aligned / recognizedCount;
  }
}

/// Default gap cost. Chosen so that:
///  - a real match/slip (levRatio < ~0.6) is aligned (match/substituted), but
///  - two genuinely-different words (levRatio ≥ ~0.6) are NOT force-aligned —
///    at the span edge they become a free skip + an `inserted`, so junk never
///    fabricates a spurious aligned span.
const double _kGapCost = 0.6;

/// Needleman-Wunsch alignment of [recognized] words onto [expected] words with a
/// FREE PREFIX (and suffix) gap: the recitation may begin (and end) anywhere in
/// the page at no penalty, so un-recited leading/trailing expected words are not
/// charged and not reported. Pure & stateless.
///
/// Words are normalized internally for scoring (alef-insensitive); the input
/// lists (which may be display text) are never modified.
WordAlignment fittingAlign({
  required List<String> expected,
  required List<String> recognized,
  required RecitationConfig mode,
  double gapCost = _kGapCost,
}) {
  final e = expected.length;
  final r = recognized.length;

  final ne = [for (final w in expected) normalizeForMatch(w)];
  final nr = [for (final w in recognized) normalizeForMatch(w)];

  double cost(int i, int j) => levRatio(ne[i], nr[j]); // 0 (same) … 1 (diff)

  // dp[i][j] = min cost aligning expected[0..i) with recognized[0..j).
  //  - dp[i][0] = 0       : skipping a leading expected prefix is FREE.
  //  - dp[0][j] = j*gap   : leading recited words with nothing to match = inserts.
  final dp = List.generate(e + 1, (_) => List<double>.filled(r + 1, 0),
      growable: false);
  // backpointer: 0 diag (align), 1 up (omit expected), 2 left (insert recited).
  final bt = List.generate(e + 1, (_) => List<int>.filled(r + 1, 0),
      growable: false);

  for (var j = 1; j <= r; j++) {
    dp[0][j] = j * gapCost;
    bt[0][j] = 2;
  }
  // dp[i][0] already 0 (free leading skip); bt unused there.

  for (var i = 1; i <= e; i++) {
    for (var j = 1; j <= r; j++) {
      final diag = dp[i - 1][j - 1] + cost(i - 1, j - 1);
      final up = dp[i - 1][j] + gapCost; // omit expected i-1
      final left = dp[i][j - 1] + gapCost; // insert recognized j-1
      // Prefer diag on ties (keeps slips as substitutions), then up, then left.
      var best = diag;
      var dir = 0;
      if (up < best) {
        best = up;
        dir = 1;
      }
      if (left < best) {
        best = left;
        dir = 2;
      }
      dp[i][j] = best;
      bt[i][j] = dir;
    }
  }

  // Free SUFFIX: consume all recognized (column r); trailing expected are free,
  // so pick the row i* with the lowest dp[i*][r].
  var iStar = 0;
  var bestEnd = dp[0][r];
  for (var i = 1; i <= e; i++) {
    // `<=` so ties favour the LARGER end row: consuming a real trailing match
    // (e.g. ...رب omitted, العالمين matched) is preferred over leaving that
    // recognized word as an `inserted` while free-skipping the expected word.
    if (dp[i][r] <= bestEnd) {
      bestEnd = dp[i][r];
      iStar = i;
    }
  }

  // Traceback from (iStar, r). Stop at column 0 (remaining leading expected are
  // free-skipped — no ops).
  final rev = <AlignedPair>[];
  var i = iStar;
  var j = r;
  while (j > 0) {
    final dir = bt[i][j];
    if (dir == 0) {
      final c = cost(i - 1, j - 1);
      rev.add(AlignedPair(
        op: c <= mode.levThreshold
            ? WordAlignOp.matched
            : WordAlignOp.substituted,
        expectedIndex: i - 1,
        recognizedIndex: j - 1,
        score: 1.0 - c,
      ));
      i--;
      j--;
    } else if (dir == 1) {
      rev.add(AlignedPair(
        op: WordAlignOp.omitted,
        expectedIndex: i - 1,
        recognizedIndex: -1,
        score: 0,
      ));
      i--;
    } else {
      rev.add(AlignedPair(
        op: WordAlignOp.inserted,
        expectedIndex: -1,
        recognizedIndex: j - 1,
        score: 0,
      ));
      j--;
    }
  }

  final pairs = rev.reversed.toList(growable: false);

  // Trim leading/trailing `omitted` ops: a gap is only meaningful BETWEEN
  // aligned words; before the first / after the last aligned word it's just an
  // un-recited prefix/suffix (free), not a forget.
  var lo = 0;
  var hi = pairs.length;
  bool isAligned(AlignedPair p) =>
      p.op == WordAlignOp.matched || p.op == WordAlignOp.substituted;
  // (leading inserts/omits trimmed only if omitted; leading inserts are real)
  while (lo < hi &&
      pairs[lo].op == WordAlignOp.omitted) {
    lo++;
  }
  while (hi > lo && pairs[hi - 1].op == WordAlignOp.omitted) {
    hi--;
  }
  final trimmed = pairs.sublist(lo, hi);

  final map = <int, int>{};
  var first = -1, last = -1, matched = 0;
  for (final p in trimmed) {
    if (isAligned(p)) {
      map[p.expectedIndex] = p.recognizedIndex;
      if (first < 0) first = p.expectedIndex;
      last = p.expectedIndex;
      if (p.op == WordAlignOp.matched) matched++;
    }
  }

  return WordAlignment(
    pairs: trimmed,
    expectedToRecognized: map,
    firstExpected: first,
    lastExpected: last,
    matchedCount: matched,
    recognizedCount: r,
  );
}

/// Convenience: align recognized tokens against an [ExpectedWord] scope using
/// the scope's pre-normalized forms.
WordAlignment fittingAlignScope({
  required List<ExpectedWord> scope,
  required List<String> recognized,
  required RecitationConfig mode,
  double gapCost = _kGapCost,
}) {
  return fittingAlign(
    expected: [for (final w in scope) w.norm],
    recognized: recognized,
    mode: mode,
    gapCost: gapCost,
  );
}

// ---------------------------------------------------------------------------
// Forced-alignment seam (token → word time spans; the CTC Viterbi step).
//
// Phase 2 will supply a real implementation over the model's per-frame CTC
// output. This contract lives in pure Dart so the report/engine can consume
// per-word timing without ever importing audio/ONNX. Only the contract + an
// in-memory fake are provided now (CLAUDE.md: do NOT implement audio logic yet).
// ---------------------------------------------------------------------------

/// The audio time span of one recited word.
class WordSpan {
  final int wordIndex;
  final double startSec;
  final double endSec;
  const WordSpan({
    required this.wordIndex,
    required this.startSec,
    required this.endSec,
  });

  @override
  String toString() =>
      'WordSpan($wordIndex [${startSec.toStringAsFixed(2)}–'
      '${endSec.toStringAsFixed(2)}]s)';
}

/// Maps recited [words] to their audio time spans — the CTC forced-alignment
/// (Viterbi) step. [frameTokenIds] is the per-frame CTC argmax path (10 ms hop
/// per CLAUDE.md); [secondsPerFrame] converts frames → seconds.
abstract class ForcedAligner {
  List<WordSpan> alignWords({
    required List<String> words,
    required List<int> frameTokenIds,
    required double secondsPerFrame,
  });
}

/// Deterministic in-memory fake for tests/Phase-1: distributes the total audio
/// duration across words proportional to (normalized) word length, producing
/// monotonic, non-overlapping spans covering [0, totalDuration]. NOT a real
/// forced alignment — Phase 2 replaces this with a CTC Viterbi over real frames.
class UniformForcedAligner implements ForcedAligner {
  const UniformForcedAligner();

  @override
  List<WordSpan> alignWords({
    required List<String> words,
    required List<int> frameTokenIds,
    required double secondsPerFrame,
  }) {
    if (words.isEmpty) return const [];
    final total = frameTokenIds.length * secondsPerFrame;
    final weights = [
      for (final w in words)
        (normalizeForMatch(w).runes.length).clamp(1, 1 << 30).toDouble()
    ];
    final sum = weights.fold<double>(0, (a, b) => a + b);
    final spans = <WordSpan>[];
    var t = 0.0;
    for (var i = 0; i < words.length; i++) {
      final dur = total * (weights[i] / sum);
      final end = (i == words.length - 1) ? total : t + dur;
      spans.add(WordSpan(wordIndex: i, startSec: t, endSec: end));
      t = end;
    }
    return spans;
  }
}
