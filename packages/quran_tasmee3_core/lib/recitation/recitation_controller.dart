/// The recitation orchestrator (spec Phase 3): ties the [matchUtterance]
/// engine, the ASR feed, silence timers, the attempt ladder, and the reveal
/// buttons into a framework-agnostic state machine.
///
/// Deliberately free of Flutter, Firebase, and real timers so it is fully
/// unit-testable. Time is injected via a `now()` clock and silence is driven
/// by explicit [checkSilence] calls — the Flutter `Notifier` wrapper supplies
/// a periodic timer that calls [checkSilence] with the real clock, and a
/// `record`-backed [AsrService] that calls [submitAsr].
library;

import 'asr_service.dart';
import 'matching_engine.dart';
import 'normalizer.dart';
import 'recitation_config.dart';

/// State-machine status (spec Phase 3).
enum RecitationStatus { idle, listening, matching, revealing, error, completed, paused }

/// Severity of a recorded mistake, driven by the attempt ladder.
///  - [transient] : attempt 1 — never persisted (informational only).
///  - [soft]      : attempt 2.
///  - [confirmed] : attempt 3+, or any direct forget (silence / manual reveal).
///  - [flag]      : accepted-but-flagged pronunciation (not a failed attempt).
enum ErrorSeverity { transient, soft, confirmed, flag }

/// Silence timing constants (spec Phase 3, step 2).
const int kSilenceIndicatorMs = 5000;
const int kSilenceForgetMs = 10000;

/// Consecutive ASR failures before an "audio unclear" hint (spec Phase 2).
const int kAsrUnclearThreshold = 3;

/// Consecutive `submitAsr` calls with zero cursor advancement AND zero newly
/// logged error before a `silentStall` diagnostic fires. This is the SILENT
/// non-progress case (e.g. every utterance fully absorbed as context replay) —
/// distinct from the known stuck→re-anchor path, which DOES log forgets/asrLag.
const int kSilentStallThreshold = 5;

/// When the reciter is stuck for `reanchorThreshold × this` non-advancing
/// attempts AND re-anchor can't recover (garbled ASR aligning nowhere), the
/// controller asks the ASR layer to flush — the automated pause/resume recovery.
const int kAsrResetStuckMultiplier = 2;

/// A re-anchor may jump backward at most this many words. The reciter moves
/// forward, so a strong anchor far behind is almost always a repeated phrase
/// the garbled ASR matched — jumping back to it derails the cursor.
const int kMaxBackwardReanchor = 4;

/// A logged mistake, matching the Firestore `errors` document shape (Phase 5):
/// `{ wordId, expectedText, recognizedText, errorType, confidence, attempts,
/// manualReveal, createdAt }`, plus a [severity] for the report layer.
class RecordedError {
  final String wordId;
  final String expectedText;
  final String? recognizedText;
  final ErrorType errorType;
  final double confidence;
  final int attempts;
  final bool manualReveal;
  final ErrorSeverity severity;
  final int createdAt; // epoch ms

  const RecordedError({
    required this.wordId,
    required this.expectedText,
    required this.recognizedText,
    required this.errorType,
    required this.confidence,
    required this.attempts,
    required this.manualReveal,
    required this.severity,
    required this.createdAt,
  });

  @override
  String toString() =>
      'RecordedError(${errorType.wire}/${severity.name} $wordId '
      'attempts=$attempts manual=$manualReveal)';
}

/// Sink for recorded errors. The Flutter app implements a Firestore-backed
/// logger (Phase 5); tests use [InMemorySessionLogger].
abstract class SessionLogger {
  void record(RecordedError e);
}

/// Default in-memory logger — collects everything for assertions/reports.
class InMemorySessionLogger implements SessionLogger {
  final List<RecordedError> errors = [];
  @override
  void record(RecordedError e) => errors.add(e);
}

/// One-shot events emitted for the UI layer (indicators, toasts, completion).
enum RecitationEventType {
  reveal,
  silenceIndicatorShown,
  silenceForget,
  asrUnclear,
  reanchored,
  completed,

  /// Diagnostic: many consecutive utterances made zero progress and logged zero
  /// errors — a silent stall (see [kSilentStallThreshold]). The UI logs this so
  /// the freeze can be captured with hard evidence.
  silentStall,

  /// The reciter is stuck and re-anchor can't recover; the UI should flush the
  /// ASR (VAD/decoder reset) — automated pause/resume recovery (no mic pause).
  requestAsrReset,
}

class RecitationEvent {
  final RecitationEventType type;
  final int? index; // for reveal events: the scope index revealed
  const RecitationEvent(this.type, [this.index]);

  @override
  String toString() =>
      'RecitationEvent(${type.name}${index != null ? ' @$index' : ''})';
}

/// The controller. Construct with the scope, mode, a clock, and (optionally) a
/// logger and reveal callback, then [start].
class RecitationController {
  final List<ExpectedWord> scope;
  RecitationConfig mode;
  final SessionLogger logger;
  final int Function() now;

  /// Called once per revealed index, in order (UI draws the word in).
  final void Function(int index)? onReveal;

  /// Called for each one-shot UI event.
  final void Function(RecitationEvent event)? onEvent;

  /// After this many consecutive non-advancing (errored) utterances at the same
  /// cursor, a broad re-anchor search runs (spec: dual-mode tracking). 0 = off.
  final int reanchorThreshold;

  /// Minimum fraction of the utterance an anchor run must explain to re-anchor.
  final double reanchorMinFraction;

  /// Minimum consecutive words an anchor run must cover to re-anchor.
  final int reanchorMinWords;

  RecitationController({
    required this.scope,
    required this.mode,
    required this.now,
    SessionLogger? logger,
    this.onReveal,
    this.onEvent,
    int startCursor = 0,
    this.reanchorThreshold = 3,
    this.reanchorMinFraction = 0.6,
    this.reanchorMinWords = 2,
  })  : logger = logger ?? InMemorySessionLogger(),
        _cursor = startCursor;

  // --- mutable state --------------------------------------------------------
  RecitationStatus _status = RecitationStatus.idle;
  int _cursor;
  final List<int> _revealedIndices = [];
  final List<int> _acceptedHistory = [];
  final Map<String, int> _attemptCounts = {};
  int _consecutiveAsrFailures = 0;
  bool _unclearEmitted = false;
  bool _silenceIndicatorVisible = false;
  int _lastProgressAt = 0;
  RecordedError? _lastError;
  int _consecutiveStuck = 0; // non-advancing errored utterances at this cursor
  final List<RecitationEvent> events = [];

  /// Words classified as a SUBSTITUTION (genuine wrong word) at any attempt
  /// level. Used so a later re-anchor doesn't mask a real substitution as
  /// `asrLag` (which would exclude it from scoring). Cleared when the word is
  /// eventually recited/accepted.
  final Set<String> _substitutedWords = {};

  /// Count of errors handed to [logger] this session — lets the silent-stall
  /// detector tell "nothing was logged" apart from "an error was logged",
  /// without coupling to the external logger implementation.
  int _loggedCount = 0;

  /// Consecutive [submitAsr] calls with no advance AND no newly logged error.
  int _silentNoProgress = 0;

  // --- read-only accessors --------------------------------------------------
  RecitationStatus get status => _status;
  int get cursor => _cursor;
  List<int> get revealedIndices => List.unmodifiable(_revealedIndices);
  List<int> get acceptedHistory => List.unmodifiable(_acceptedHistory);
  Map<String, int> get attemptCounts => Map.unmodifiable(_attemptCounts);
  int get consecutiveAsrFailures => _consecutiveAsrFailures;
  int get consecutiveStuck => _consecutiveStuck;
  bool get silenceIndicatorVisible => _silenceIndicatorVisible;
  RecordedError? get lastError => _lastError;

  // --- lifecycle ------------------------------------------------------------

  /// Begin a session: hide handled by the UI; cursor at [startCursor], start
  /// listening, arm the silence clock.
  void start() {
    _status = RecitationStatus.listening;
    _lastProgressAt = now();
    if (_cursor >= scope.length) _complete();
  }

  /// Stop the session (does not finalize a report).
  void stop() {
    if (_status != RecitationStatus.completed) {
      _status = RecitationStatus.paused;
    }
  }

  /// Pause an active session. The screen must also stop the mic/ASR stream
  /// while paused (the controller additionally ignores any late ASR results).
  void pause() {
    if (_status == RecitationStatus.listening ||
        _status == RecitationStatus.matching) {
      _status = RecitationStatus.paused;
    }
  }

  /// Resume a paused session. Re-arms the silence clock so resuming doesn't
  /// immediately trip a silence-forget.
  void resume() {
    if (_status == RecitationStatus.paused) {
      _status = RecitationStatus.listening;
      _lastProgressAt = now();
      _silenceIndicatorVisible = false;
    }
  }

  // --- ASR ingestion --------------------------------------------------------

  /// Process one ASR result against the cursor (spec Phase 3, step 3).
  void submitAsr(AsrResult r) {
    if (_status == RecitationStatus.idle ||
        _status == RecitationStatus.completed ||
        _status == RecitationStatus.paused) {
      return;
    }
    // Silent-stall detection (diagnostic): a healthy utterance either advances
    // the cursor or logs an error. If many in a row do NEITHER (e.g. every
    // utterance fully absorbed as context replay, or a run of ASR non-results),
    // that's a silent freeze — emit a diagnostic so the UI can capture it.
    final cursorBefore = _cursor;
    final loggedBefore = _loggedCount;
    _processUtterance(r);
    final progressed = _cursor != cursorBefore;
    final logged = _loggedCount != loggedBefore;
    if (!progressed && !logged && _status != RecitationStatus.completed) {
      if (++_silentNoProgress >= kSilentStallThreshold) {
        _emit(RecitationEventType.silentStall, _cursor);
        _silentNoProgress = 0; // re-arm so a persistent stall keeps reporting
      }
    } else {
      _silentNoProgress = 0;
    }
  }

  void _processUtterance(AsrResult r) {
    _status = RecitationStatus.matching;
    // Clear the previous utterance's classification up-front so `lastError`
    // ALWAYS reflects only THIS utterance — including the early-return failure
    // paths below. (Otherwise a stale substitution lingered and, e.g., re-fired
    // the real-time flash on later correct/silent utterances.)
    _lastError = null;

    // ASR failure: empty/whitespace text or confidence 0 → silent non-result.
    if (r.isFailure) {
      _registerAsrFailure();
      _status = RecitationStatus.listening;
      return;
    }

    final tokens = tokenize(normalizeForMatch(r.text));
    if (tokens.isEmpty) {
      _registerAsrFailure();
      _status = RecitationStatus.listening;
      return;
    }

    final result = matchUtterance(
      scope: scope,
      cursor: _cursor,
      recognizedTokens: tokens,
      confidence: r.confidence,
      mode: mode,
      acceptedHistory: _acceptedHistory,
    );

    final advanced = result.acceptedWordIndices.isNotEmpty;

    // Reveal the accepted prefix in sequence.
    if (advanced) {
      _status = RecitationStatus.revealing;
      for (final i in result.acceptedWordIndices) {
        if (!_revealedIndices.contains(i)) _revealedIndices.add(i);
        _acceptedHistory.add(i);
        _substitutedWords.remove(scope[i].wordId); // recited correctly now
        onReveal?.call(i);
        _emit(RecitationEventType.reveal, i);
      }
      _cursor = result.newCursor;
      // Progress made → reset silence + ASR-failure + stuck tracking.
      _lastProgressAt = now();
      _consecutiveAsrFailures = 0;
      _unclearEmitted = false;
      _silenceIndicatorVisible = false;
      _consecutiveStuck = 0;
    }

    // Pronunciation flags: accepted but low-confidence → log as a flag.
    for (final i in result.pronunciationFlaggedIndices) {
      _log(RecordedError(
        wordId: scope[i].wordId,
        expectedText: _expectedText(i),
        recognizedText: null,
        errorType: ErrorType.pronunciation,
        confidence: r.confidence,
        attempts: 0,
        manualReveal: false,
        severity: ErrorSeverity.flag,
        createdAt: now(),
      ));
    }

    // Handle the stopping error (if any).
    if (result.error != null) {
      if (!advanced) {
        // No forward progress at all → count toward a "stuck" state and try a
        // broad re-anchor once the threshold is reached.
        _consecutiveStuck++;
        if (reanchorThreshold > 0 &&
            _consecutiveStuck >= reanchorThreshold &&
            _tryReanchor(tokens, r.confidence)) {
          // Re-anchored: the failed attempts weren't a real error here.
          if (_cursor >= scope.length) {
            _complete();
            return;
          }
          _status = RecitationStatus.listening;
          return;
        }
        // Re-anchor couldn't recover (e.g. the ASR is returning garbled text
        // that aligns nowhere). After a longer run, ask the ASR layer to flush
        // its VAD/decoder state — the automated equivalent of the manual
        // pause/resume the user found un-sticks this. Flush is VAD-only (no mic
        // pause) so it doesn't drop captured audio. Re-arm afterwards.
        if (reanchorThreshold > 0 &&
            _consecutiveStuck >= reanchorThreshold * kAsrResetStuckMultiplier) {
          _emit(RecitationEventType.requestAsrReset, _cursor);
          _consecutiveStuck = 0;
        }
      } else {
        // Partial advance then stop → progress was made; reset stuck.
        _consecutiveStuck = 0;
      }
      _handleError(result.error!, r.confidence);
    }

    // Completion check (scope consumed with no trailing error left to retry).
    if (_cursor >= scope.length &&
        (result.error == null || result.error!.type == ErrorType.addition)) {
      _complete();
      return;
    }

    if (_status != RecitationStatus.completed) {
      _status = RecitationStatus.listening;
    }
  }

  /// Broad re-anchor recovery (spec: dual-mode tracking). Searches the whole
  /// scope for where [tokens] best aligns; if confident and different from the
  /// current cursor, jumps there, reveals the matched run, and — for a forward
  /// jump — records an `asrLag` for every never-revealed word in the skipped
  /// range `[oldCursor, anchor.startIndex)` AND reveals it on the page. Those
  /// words were recited correctly (the ASR merely fell behind), so they fill in
  /// visually like a normal match and surface in the report's تأخر تعرف bucket,
  /// excluded from scoring / weak-item aggregation. Returns true if it
  /// re-anchored.
  bool _tryReanchor(List<String> tokens, double confidence) {
    final anchor = findBestAnchor(
      scope: scope,
      recognizedTokens: tokens,
      mode: mode,
      minFraction: reanchorMinFraction,
      minWords: reanchorMinWords,
    );
    if (anchor == null || anchor.startIndex == _cursor) return false;

    // Reject a far-BACKWARD jump. The reciter moves forward, so a strong anchor
    // behind the cursor is almost always a repeated phrase elsewhere on the page
    // (e.g. "إن الله على كل شيء قدير") that garbled ASR matched — jumping back to
    // it throws the cursor into chaos. Allow a small backward window for genuine
    // restarts; reject anything further behind.
    if (anchor.startIndex < _cursor - kMaxBackwardReanchor) return false;

    final oldCursor = _cursor;

    // Forward jump → everything between the old cursor and the anchor was
    // skipped because ASR fell behind. These were (almost certainly) recited
    // correctly, so classify them as `asrLag`, NOT `forget` — surfaced in the
    // report but excluded from scoring / weak items. Because we now treat them
    // as correctly recited, REVEAL them on the page too (same as a normal
    // match), so the mushaf fills in instead of leaving a wall of gray pills
    // that contradicts the report.
    for (var i = oldCursor; i < anchor.startIndex && i < scope.length; i++) {
      if (_revealedIndices.contains(i)) continue;
      // A word the reciter actively said WRONG (a real substitution, already
      // logged by the ladder) must NOT be downgraded to asrLag — that would
      // exclude a genuine mistake from scoring. Leave its substitution on record
      // and just reveal it. Everything else in the gap is a true ASR-lag skip.
      if (!_substitutedWords.contains(scope[i].wordId)) {
        _recordAsrLag(i);
      }
      _revealedIndices.add(i);
      onReveal?.call(i);
      _emit(RecitationEventType.reveal, i);
    }

    // Reveal the matched run at the anchor and jump the cursor there.
    _status = RecitationStatus.revealing;
    for (var k = 0; k < anchor.matchedCount; k++) {
      final i = anchor.startIndex + k;
      if (!_revealedIndices.contains(i)) _revealedIndices.add(i);
      _acceptedHistory.add(i);
      onReveal?.call(i);
      _emit(RecitationEventType.reveal, i);
    }
    _cursor = anchor.startIndex + anchor.matchedCount;
    _lastProgressAt = now();
    _consecutiveAsrFailures = 0;
    _unclearEmitted = false;
    _silenceIndicatorVisible = false;
    _consecutiveStuck = 0;
    _emit(RecitationEventType.reanchored, anchor.startIndex);
    return true;
  }

  void _registerAsrFailure() {
    _consecutiveAsrFailures++;
    if (_consecutiveAsrFailures >= kAsrUnclearThreshold && !_unclearEmitted) {
      _unclearEmitted = true;
      _emit(RecitationEventType.asrUnclear);
    }
    // Note: silence clock is NOT reset — no accepted progress was made.
  }

  // --- attempt ladder + error classification --------------------------------

  void _handleError(RecitationError err, double confidence) {
    // `addition` is not part of the ladder — record it directly (confirmed).
    if (err.type == ErrorType.addition) {
      _log(RecordedError(
        wordId: err.expectedIndex < scope.length
            ? scope[err.expectedIndex].wordId
            : (scope.isEmpty ? '' : scope.last.wordId),
        expectedText: '',
        recognizedText: err.recognizedToken,
        errorType: ErrorType.addition,
        confidence: confidence,
        attempts: 1,
        manualReveal: false,
        severity: ErrorSeverity.confirmed,
        createdAt: now(),
      ));
      return;
    }

    // If the reciter already SUBSTITUTED this word and is now reciting ahead,
    // the resulting `order` errors at this cursor are just navigation noise —
    // don't let them override the substitution as the word's classification.
    // (The stuck count in submitAsr still drives the eventual re-anchor.)
    if (err.type == ErrorType.order &&
        _substitutedWords.contains(scope[err.expectedIndex].wordId)) {
      _status = RecitationStatus.error;
      return;
    }

    // substitution / order → attempt ladder, keyed by the stopping word.
    final wordId = scope[err.expectedIndex].wordId;
    final n = (_attemptCounts[wordId] ?? 0) + 1;
    _attemptCounts[wordId] = n;
    _status = RecitationStatus.error;

    // A substitution is a genuine wrong word (high signal): remember it so a
    // later re-anchor can't mask it as `asrLag`, and record it from the FIRST
    // occurrence (soft) so a single mistake is never silently dropped from the
    // report. Order errors keep the transient-first ladder — attempt 1 is often
    // a skip-ahead / ASR artifact that the re-anchor path handles instead.
    if (err.type == ErrorType.substitution) {
      _substitutedWords.add(wordId);
    }

    final ErrorSeverity severity;
    if (n >= 3) {
      severity = ErrorSeverity.confirmed;
    } else if (n == 2) {
      severity = ErrorSeverity.soft;
    } else {
      severity = err.type == ErrorType.substitution
          ? ErrorSeverity.soft // log a lone substitution
          : ErrorSeverity.transient; // order attempt 1: informational only
    }

    final rec = RecordedError(
      wordId: wordId,
      expectedText: _expectedText(err.expectedIndex),
      recognizedText: err.recognizedToken,
      errorType: err.type,
      confidence: confidence,
      attempts: n,
      manualReveal: false,
      severity: severity,
      createdAt: now(),
    );
    _lastError = rec;
    if (severity != ErrorSeverity.transient) _log(rec);
  }

  // --- silence timers (spec Phase 3, step 2) --------------------------------

  /// Evaluate the silence timers against the current clock. Call periodically
  /// while listening. Stage 1 (≥5s) shows the indicator; stage 2 (≥10s)
  /// registers a direct `forget` for the current word WITHOUT advancing the
  /// cursor, then re-arms.
  void checkSilence() {
    if (_status != RecitationStatus.listening) return;
    final elapsed = now() - _lastProgressAt;

    if (elapsed >= kSilenceForgetMs) {
      if (_cursor < scope.length) {
        _recordForget(_cursor, manualReveal: false);
        _emit(RecitationEventType.silenceForget);
      }
      _silenceIndicatorVisible = false;
      _lastProgressAt = now(); // re-arm: next forget needs another full window
    } else if (elapsed >= kSilenceIndicatorMs) {
      if (!_silenceIndicatorVisible) {
        _silenceIndicatorVisible = true;
        _emit(RecitationEventType.silenceIndicatorShown);
      }
    }
  }

  // --- manual reveal buttons (spec Phase 3, steps 5 & 6) --------------------

  /// Reveal exactly the one word at the cursor as a direct `forget` (bypasses
  /// the ladder), advance by one, keep listening. Not a memorization success.
  void revealNextWord() {
    if (_status == RecitationStatus.completed || _cursor >= scope.length) return;
    final i = _cursor;
    if (!_revealedIndices.contains(i)) _revealedIndices.add(i);
    _recordForget(i, manualReveal: true);
    onReveal?.call(i);
    _emit(RecitationEventType.reveal, i);
    _cursor = i + 1;
    _lastProgressAt = now();
    _silenceIndicatorVisible = false;
    if (_cursor >= scope.length) {
      _complete();
    } else {
      _status = RecitationStatus.listening;
    }
  }

  /// Reveal all not-yet-revealed words of the current ayah as direct forgets,
  /// move the cursor to the first word of the next ayah, keep listening.
  void revealFullAyah() {
    if (_status == RecitationStatus.completed || _cursor >= scope.length) return;
    final surah = scope[_cursor].surah;
    final ayah = scope[_cursor].ayah;
    var i = _cursor;
    while (i < scope.length &&
        scope[i].surah == surah &&
        scope[i].ayah == ayah) {
      if (!_revealedIndices.contains(i)) {
        _revealedIndices.add(i);
        _recordForget(i, manualReveal: true);
        onReveal?.call(i);
        _emit(RecitationEventType.reveal, i);
      }
      i++;
    }
    _cursor = i; // first word of the next ayah (or end of scope)
    _lastProgressAt = now();
    _silenceIndicatorVisible = false;
    if (_cursor >= scope.length) {
      _complete();
    } else {
      _status = RecitationStatus.listening;
    }
  }

  /// Single funnel for every persisted error — keeps [_loggedCount] accurate so
  /// the silent-stall detector knows whether THIS utterance logged anything.
  void _log(RecordedError e) {
    _loggedCount++;
    logger.record(e);
  }

  void _recordForget(int index, {required bool manualReveal}) {
    _log(RecordedError(
      wordId: scope[index].wordId,
      expectedText: _expectedText(index),
      recognizedText: null,
      errorType: ErrorType.forget,
      confidence: 0.0,
      attempts: 0,
      manualReveal: manualReveal,
      severity: ErrorSeverity.confirmed,
      createdAt: now(),
    ));
  }

  /// Record an `asrLag` for a word the re-anchor jumped over. NOT a memorization
  /// mistake: the reciter (almost certainly) said it correctly and the ASR
  /// simply fell behind, so the report surfaces it in its own bucket but the
  /// scoring / weak-item aggregation ignores it. Kept structurally parallel to
  /// [_recordForget] (severity `confirmed` so the dedup/report layer treats it
  /// as a final, non-transient classification for the word).
  void _recordAsrLag(int index) {
    _log(RecordedError(
      wordId: scope[index].wordId,
      expectedText: _expectedText(index),
      recognizedText: null,
      errorType: ErrorType.asrLag,
      confidence: 0.0,
      attempts: 0,
      manualReveal: false,
      severity: ErrorSeverity.confirmed,
      createdAt: now(),
    ));
  }

  void _complete() {
    _status = RecitationStatus.completed;
    _silenceIndicatorVisible = false;
    _emit(RecitationEventType.completed);
  }

  String _expectedText(int i) =>
      scope[i].display.isNotEmpty ? scope[i].display : scope[i].wordId;

  void _emit(RecitationEventType type, [int? index]) {
    final e = RecitationEvent(type, index);
    events.add(e);
    onEvent?.call(e);
  }
}
