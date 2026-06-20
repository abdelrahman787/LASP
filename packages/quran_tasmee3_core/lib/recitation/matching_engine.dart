/// The on-device recitation matching engine (spec Phase 1d).
///
/// Stateless, pure, framework-agnostic. Given the expected words of the
/// current scope (a page, or an ayah range for a review session), the current
/// cursor, and the normalized tokens of one ASR utterance, it decides which
/// words to reveal and classifies the first mistake (if any).
///
/// Locked decisions encoded here:
///  - Rule D is dropped → **longest-correct-prefix**: accept every consecutive
///    correct word in one utterance (across word/ayah boundaries) and stop at
///    the *first* error.
///  - **Context replay** (re-reciting accepted trailing words then continuing)
///    is NOT an error.
///  - `forget` is never produced here — it comes from silence timers / manual
///    reveal in the controller (Phase 3). The engine emits `substitution`,
///    `order`, `addition`, plus `pronunciation` *flags* on accepted words.
library;

import 'distance.dart';
import 'recitation_config.dart';

/// Backend error taxonomy — stored verbatim as these strings in Firestore.
///
/// `asrLag` is NOT a recitation mistake: it marks words the system skipped over
/// when a re-anchor jumped the cursor forward because ASR fell behind the
/// reciter. They were (almost certainly) recited correctly — surfaced for
/// transparency but excluded from scoring / weak-item aggregation.
enum ErrorType { forget, substitution, order, pronunciation, addition, asrLag }

extension ErrorTypeWire on ErrorType {
  /// The exact string persisted to Firestore / matched by the backend enum.
  String get wire => name; // forget|substitution|order|pronunciation|addition|asrLag
}

/// One expected word in the recitation scope. `norm` is the pre-normalized
/// form (via `normalizeForMatch`); the engine only ever compares against it.
class ExpectedWord {
  /// "<surah>:<ayah>:<wordIndex>"
  final String wordId;
  final int surah;
  final int ayah;
  final int wordIndex;

  /// Normalized form used for matching (never displayed).
  final String norm;

  /// Original display text (Uthmani, with diacritics). Optional — used by the
  /// controller for error logging; the engine itself never reads it.
  final String display;

  const ExpectedWord({
    required this.wordId,
    required this.surah,
    required this.ayah,
    required this.wordIndex,
    required this.norm,
    this.display = '',
  });

  @override
  String toString() => 'ExpectedWord($wordId, "$norm")';
}

/// A classified mistake at the point recitation stopped.
class RecitationError {
  final ErrorType type;

  /// Index in `scope` where matching stopped (the expected word not matched).
  final int expectedIndex;

  /// The recognized token that triggered the error (if any).
  final String? recognizedToken;

  /// Utterance-level ASR confidence.
  final double confidence;

  const RecitationError({
    required this.type,
    required this.expectedIndex,
    required this.recognizedToken,
    required this.confidence,
  });

  @override
  String toString() =>
      'RecitationError(${type.wire} @ $expectedIndex, token=$recognizedToken)';
}

/// Result of processing one utterance against the cursor.
class MatchResult {
  /// Expected indices revealed this utterance, in order.
  final List<int> acceptedWordIndices;

  /// Subset of [acceptedWordIndices] that were accepted but flagged as a
  /// pronunciation issue (matched within tolerance, confidence below floor).
  final List<int> pronunciationFlaggedIndices;

  /// Cursor after consuming this utterance.
  final int newCursor;

  /// The first error, or null if the whole utterance was accepted.
  final RecitationError? error;

  /// True if leading tokens were absorbed as a context replay.
  final bool wasContextReplay;

  const MatchResult({
    required this.acceptedWordIndices,
    required this.pronunciationFlaggedIndices,
    required this.newCursor,
    required this.error,
    required this.wasContextReplay,
  });
}

/// How far back (in accepted words) a context replay may reach.
const int kReplayWindow = 6;

/// How far ahead of the cursor an out-of-place token may match to be classified
/// as an `order` error (vs `substitution`). Bounded so a common word recurring
/// far later in a full-page scope isn't misread as a re-ordering.
const int _orderLookAhead = 8;

/// Pure entry point: process ONE recognized utterance against the cursor.
///
/// [recognizedTokens] must already be normalized (caller runs the normalizer
/// + tokenizer). [acceptedHistory] is the list of scope indices accepted so
/// far this session, used only for context-replay anchoring.
MatchResult matchUtterance({
  required List<ExpectedWord> scope,
  required int cursor,
  required List<String> recognizedTokens,
  required double confidence,
  required RecitationConfig mode,
  required List<int> acceptedHistory,
}) {
  final accepted = <int>[];
  final pronFlags = <int>[];

  // Defensive: nothing to match.
  if (recognizedTokens.isEmpty || cursor >= scope.length) {
    return MatchResult(
      acceptedWordIndices: accepted,
      pronunciationFlaggedIndices: pronFlags,
      newCursor: cursor,
      error: null,
      wasContextReplay: false,
    );
  }

  bool sameWord(String token, String norm) =>
      levRatio(token, norm) <= mode.levThreshold;

  // --- Step 1: context-replay absorption -----------------------------------
  // Build the recently-accepted suffix (last up-to-kReplayWindow words), in
  // order. A replay is a leading run of tokens reproducing a contiguous
  // *suffix* of that accepted tail (ending at the last accepted word), so the
  // continuation flows naturally into `cursor`.
  var tokenStart = 0;
  var wasReplay = false;

  if (acceptedHistory.isNotEmpty) {
    final tailCount =
        acceptedHistory.length < kReplayWindow ? acceptedHistory.length : kReplayWindow;
    final tailIndices =
        acceptedHistory.sublist(acceptedHistory.length - tailCount);
    final tailWords =
        tailIndices.map((i) => scope[i].norm).toList(growable: false);

    // Try the longest suffix of the accepted tail first (startK = 0 → whole
    // tail). The matched run must end at the last accepted word, i.e. consume
    // tailWords[startK..end] against recognizedTokens[0..L-1].
    for (var startK = 0; startK < tailWords.length; startK++) {
      final runLen = tailWords.length - startK;
      if (runLen > recognizedTokens.length) continue;
      var ok = true;
      for (var t = 0; t < runLen; t++) {
        if (!sameWord(recognizedTokens[t], tailWords[startK + t])) {
          ok = false;
          break;
        }
      }
      if (ok) {
        tokenStart = runLen;
        wasReplay = true;
        break; // longest run wins
      }
    }
  }

  // --- Step 2: longest-correct-prefix forward match -------------------------
  var c = cursor;
  var t = tokenStart;
  RecitationError? error;

  while (t < recognizedTokens.length && c < scope.length) {
    final token = recognizedTokens[t];
    if (sameWord(token, scope[c].norm)) {
      accepted.add(c);
      if (confidence < mode.confFloor) {
        pronFlags.add(c); // accepted-but-flagged pronunciation
      }
      c++;
      t++;
      continue;
    }

    // --- Step 3: classify the stopping token ---
    // Does it match a word *ahead* of the cursor, within a bounded window? →
    // order error. The window prevents a common word that merely happens to
    // recur far later on a full-page scope from being misclassified as `order`
    // when it's really a `substitution`.
    var matchesAhead = false;
    final lookAheadLimit = (c + 1 + _orderLookAhead).clamp(0, scope.length);
    for (var j = c + 1; j < lookAheadLimit; j++) {
      if (sameWord(token, scope[j].norm)) {
        matchesAhead = true;
        break;
      }
    }
    error = RecitationError(
      type: matchesAhead ? ErrorType.order : ErrorType.substitution,
      expectedIndex: c,
      recognizedToken: token,
      confidence: confidence,
    );
    break;
  }

  // Scope exhausted but the user kept talking with out-of-scope words →
  // trailing tokens are an `addition`. (Only when no earlier error stopped us.)
  if (error == null && c >= scope.length && t < recognizedTokens.length) {
    error = RecitationError(
      type: ErrorType.addition,
      expectedIndex: c,
      recognizedToken: recognizedTokens[t],
      confidence: confidence,
    );
  }

  return MatchResult(
    acceptedWordIndices: accepted,
    pronunciationFlaggedIndices: pronFlags,
    newCursor: c,
    error: error,
    wasContextReplay: wasReplay,
  );
}

/// Result of a broad re-anchor search across the whole scope.
class AnchorMatch {
  /// Scope index where the utterance best aligns (anchor on the first token).
  final int startIndex;

  /// Number of consecutive recognized tokens matched from [startIndex].
  final int matchedCount;

  /// `matchedCount / recognizedTokens.length` — how much of the utterance the
  /// anchored run explains.
  final double fraction;

  const AnchorMatch({
    required this.startIndex,
    required this.matchedCount,
    required this.fraction,
  });

  @override
  String toString() =>
      'AnchorMatch(start=$startIndex, matched=$matchedCount, '
      'frac=${fraction.toStringAsFixed(2)})';
}

/// Broad recovery search (re-anchor). Unlike [matchUtterance] — which only
/// looks forward from the cursor — this scans the **entire scope** for the
/// position where [recognizedTokens] best aligns, so a "stuck" cursor can jump
/// to where the reciter actually is.
///
/// Anchors on the first recognized token, counts the consecutive matched run,
/// and returns the best candidate only if it covers at least [minWords] words
/// AND [minFraction] of the utterance. Returns null otherwise (no confident
/// re-anchor). Pure; the controller decides when to call it.
AnchorMatch? findBestAnchor({
  required List<ExpectedWord> scope,
  required List<String> recognizedTokens,
  required RecitationConfig mode,
  double minFraction = 0.6,
  int minWords = 2,
}) {
  if (recognizedTokens.isEmpty || scope.isEmpty) return null;
  bool same(String token, String norm) =>
      levRatio(token, norm) <= mode.levThreshold;

  var bestStart = -1;
  var bestCount = 0;
  for (var j = 0; j < scope.length; j++) {
    if (!same(recognizedTokens[0], scope[j].norm)) continue;
    var t = 0;
    var c = j;
    var matched = 0;
    while (t < recognizedTokens.length &&
        c < scope.length &&
        same(recognizedTokens[t], scope[c].norm)) {
      matched++;
      t++;
      c++;
    }
    if (matched > bestCount) {
      bestCount = matched;
      bestStart = j;
    }
  }

  if (bestStart < 0) return null;
  final fraction = bestCount / recognizedTokens.length;
  if (bestCount < minWords || fraction < minFraction) return null;
  return AnchorMatch(
    startIndex: bestStart,
    matchedCount: bestCount,
    fraction: fraction,
  );
}
