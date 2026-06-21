/// ASR client abstraction (spec Phase 2) — stubbed for pure-Dart testing.
///
/// The real implementation (mic capture via `record`, multipart upload via
/// `dio` to the Cloudflare Worker, Firebase ID token auth) lives in the
/// Flutter app. Here we define the framework-agnostic contract plus a fake
/// driver so the [RecitationController] can be exercised without mic/network.
library;

/// One ASR transcription result for a captured chunk.
class AsrResult {
  /// Recognized text (raw, NOT normalized — the controller normalizes).
  final String text;

  /// Utterance-level confidence in `[0,1]`.
  final double confidence;

  const AsrResult(this.text, this.confidence);

  /// ASR failure semantics (spec Phase 2): empty/whitespace text OR
  /// `confidence == 0` is NOT an error — it is a silent non-result that must
  /// not reach the matching engine.
  bool get isFailure => text.trim().isEmpty || confidence == 0;

  @override
  String toString() => 'AsrResult("$text", conf=$confidence)';
}

/// Contract the controller consumes. The Flutter app provides a real
/// `record`/`dio`-backed implementation; tests use [FakeAsrService].
abstract class AsrService {
  /// Begin capturing/transcribing. Each result should be delivered to
  /// [onResult]. Implementations handle permissions, chunking, retries.
  Future<void> start(void Function(AsrResult) onResult);

  /// Pause capturing (mic actually stops) without tearing down the session.
  Future<void> pause() async {}

  /// Resume after [pause].
  Future<void> resume() async {}

  /// Flush internal ASR state (e.g. VAD/decoder buffers) WITHOUT pausing the
  /// mic — the automated stuck-recovery (no captured audio is dropped).
  /// Default no-op for fakes/cloud backends with no such state.
  Future<void> flush() async {}

  /// Stop capturing (ends the session).
  Future<void> stop();
}

/// A scripted, deterministic ASR source for tests. Push results manually with
/// [emit], or queue a script and [drainTo] a sink. No timers, no I/O.
class FakeAsrService implements AsrService {
  void Function(AsrResult)? _sink;
  final List<AsrResult> _scripted;

  FakeAsrService([List<AsrResult>? scripted])
      : _scripted = [...?scripted];

  @override
  Future<void> start(void Function(AsrResult) onResult) async {
    _sink = onResult;
  }

  @override
  Future<void> pause() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> flush() async {}

  @override
  Future<void> stop() async {
    _sink = null;
  }

  /// Deliver one canned result to the wired sink.
  void emit(AsrResult r) => _sink?.call(r);

  /// Deliver every queued scripted result in order.
  void drainScript() {
    for (final r in _scripted) {
      _sink?.call(r);
    }
    _scripted.clear();
  }
}
