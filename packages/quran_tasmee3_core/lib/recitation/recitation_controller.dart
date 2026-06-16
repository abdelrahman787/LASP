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

  // --- ASR ingestion --------------------------------------------------------

  /// Process one ASR result against the cursor (spec Phase 3, step 3).
  void submitAsr(AsrResult r) {
    if (_status == RecitationStatus.idle ||
        _status == RecitationStatus.completed) {
      return;
    }
    _status = RecitationStatus.matching;

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

    // Clear the previous utterance's classification so `lastError` reflects
    // only THIS utterance (a clean, fully-accepted utterance leaves it null).
    _lastError = null;

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
      logger.record(RecordedError(
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
  /// current cursor, jumps there, reveals the matched run, and logs the skip as
  /// an `order` event (never silent). Returns true if it re-anchored.
  bool _tryReanchor(List<String> tokens, double confidence) {
    final anchor = findBestAnchor(
      scope: scope,
      recognizedTokens: tokens,
      mode: mode,
      minFraction: reanchorMinFraction,
      minWords: reanchorMinWords,
    );
    if (anchor == null || anchor.startIndex == _cursor) return false;

    // Log the jump as an order/skip at the old cursor (not silent).
    logger.record(RecordedError(
      wordId: _cursor < scope.length ? scope[_cursor].wordId : scope.last.wordId,
      expectedText: _cursor < scope.length ? _expectedText(_cursor) : '',
      recognizedText: tokens.isNotEmpty ? tokens.first : null,
      errorType: ErrorType.order,
      confidence: confidence,
      attempts: _consecutiveStuck,
      manualReveal: false,
      severity: ErrorSeverity.confirmed,
      createdAt: now(),
    ));

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
      logger.record(RecordedError(
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

    // substitution / order → attempt ladder, keyed by the stopping word.
    final wordId = scope[err.expectedIndex].wordId;
    final n = (_attemptCounts[wordId] ?? 0) + 1;
    _attemptCounts[wordId] = n;
    _status = RecitationStatus.error;

    if (n == 1) {
      // Attempt 1: transient — record nothing persistent.
      _lastError = RecordedError(
        wordId: wordId,
        expectedText: _expectedText(err.expectedIndex),
        recognizedText: err.recognizedToken,
        errorType: err.type,
        confidence: confidence,
        attempts: 1,
        manualReveal: false,
        severity: ErrorSeverity.transient,
        createdAt: now(),
      );
      return;
    }

    final severity = n == 2 ? ErrorSeverity.soft : ErrorSeverity.confirmed;
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
    logger.record(rec);
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

  void _recordForget(int index, {required bool manualReveal}) {
    logger.record(RecordedError(
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
