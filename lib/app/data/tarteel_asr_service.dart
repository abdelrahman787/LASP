import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../debug.dart';

/// On-device ASR (Tarteel Whisper via Sherpa-ONNX) gated by Silero VAD v5.
///
/// Recognition runs in a PERSISTENT BACKGROUND ISOLATE so a multi-second decode
/// never blocks the mic stream or the UI (the previous main-isolate version
/// stalled the audio pipeline → cascading lag). The isolate owns both the VAD
/// and the recognizer; the main isolate only captures PCM and forwards it.
///
/// VAD defines segment boundaries (no fixed windowing). The recognizer uses
/// multiple threads; the VAD is tuned so natural intra-phrase breaths don't cut
/// words mid-utterance.
class TarteelOnDeviceAsrService implements AsrService {
  static const String _dir = 'assets/models/tarteel';
  static const String _encoderAsset = '$_dir/encoder.onnx';
  static const String _decoderAsset = '$_dir/decoder.onnx';
  static const String _tokensAsset = '$_dir/tokens.txt';
  static const String _vadAsset = '$_dir/silero_vad.onnx';
  static const int _sampleRate = 16000;

  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;
  bool _paused = false;
  bool _initFailed = false;
  // True while draining the final VAD tail at stop(), so those last results are
  // still delivered even though _running has been cleared.
  bool _finalizing = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

  // --- capture audit (proof that nothing spoken is dropped) ------------------
  // Every PCM chunk the mic delivers is counted here BEFORE any conditional, and
  // again when it is actually forwarded to the worker. The worker counts every
  // sample it feeds into the VAD. At session end we log all three so a mismatch
  // (= silent data loss) is directly visible instead of merely assumed.
  //
  // Why the cross-isolate hop cannot silently drop a chunk: a Dart ReceivePort
  // is an UNBOUNDED FIFO — messages are queued on the receiving isolate's event
  // loop and never discarded under backlog. If a decode is still running when
  // new mic chunks arrive, those chunks simply wait their turn in the queue and
  // are processed in order once the worker's microtask returns; none are lost.
  // (Average decode RTF < 1, so the queue drains rather than growing without
  // bound.) The counters below are the empirical check on that guarantee.
  int _micBytes = 0; // total PCM bytes seen from the mic callback
  int _sentBytes = 0; // total PCM bytes forwarded to the worker

  // Worker isolate (kept alive across sessions so the model stays loaded; it
  // stays running via its open ReceivePort, no handle needed).
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  /// Recognizer threads — use several cores (Whisper decode is the bottleneck),
  /// capped to avoid contention with the audio thread.
  static int get _recognizerThreads {
    final n = Platform.numberOfProcessors;
    if (n <= 2) return 2;
    if (n >= 8) return 4;
    return n - 1;
  }

  Future<bool> _ensureWorker() async {
    if (_toWorker != null) return true;
    if (_initFailed) return false;
    try {
      final enc = await _copyAsset(_encoderAsset, 'tarteel-encoder.onnx');
      final dec = await _copyAsset(_decoderAsset, 'tarteel-decoder.onnx');
      final tok = await _copyAsset(_tokensAsset, 'tarteel-tokens.txt');
      final vad = await _copyAsset(_vadAsset, 'silero_vad.onnx');

      _fromWorker = ReceivePort();
      final ready = Completer<bool>();
      _fromWorker!.listen((msg) {
        if (msg is SendPort) {
          _toWorker = msg; // handshake: worker's command port
        } else if (msg is Map) {
          switch (msg['type']) {
            case 'ready':
              if (!ready.isCompleted) ready.complete(true);
              break;
            case 'init_failed':
              _initFailed = true;
              dlog('tarteel worker init failed: ${msg['error']}');
              if (!ready.isCompleted) ready.complete(false);
              break;
            case 'result':
              final text = (msg['text'] as String).trim();
              // audio=segment length, decode=actual inference wall-time (the
              // number that matters when A/B-ing providers/threads/maxSpeech).
              dlog('tarteel result "$text" audio=${msg['dur']}s '
                  '(+${msg['overlap']}s overlap) decode=${msg['ms']}ms');
              if ((_running && !_paused) || _finalizing) {
                _onResult?.call(AsrResult(text, text.isEmpty ? 0 : 0.9));
              }
              break;
            case 'watchdog':
              // The "complete freeze" recovery: VAD wedged, auto-flushed.
              dlog('⚠️ VAD WATCHDOG — no segment for ${msg['secs']}s of audio; '
                  'forced flush+drain to recover (same as pause/resume). '
                  'If you saw recitation freeze with no "tarteel result", this '
                  'is it self-healing.');
              break;
            case 'counts':
              _finalizing = false; // finalize results have all arrived by now
              // Session-end capture audit. micSamples = everything the mic gave
              // us; vadSamples = everything the worker fed into the VAD. They
              // must be equal (the worker accepts every chunk it receives), and
              // sentSamples must equal micSamples (we forward unconditionally
              // while running). Any gap is real, silent data loss.
              final vadSamples = msg['vadSamples'] as int;
              final micSamples = _micBytes ~/ 2;
              final sentSamples = _sentBytes ~/ 2;
              final ok = micSamples == sentSamples && sentSamples == vadSamples;
              dlog('CAPTURE AUDIT ${ok ? 'OK' : 'MISMATCH!!'} — '
                  'mic=$micSamples sent=$sentSamples vad-accepted=$vadSamples '
                  'samples (${(micSamples / _sampleRate).toStringAsFixed(2)}s '
                  'captured). lost=${micSamples - vadSamples} samples');
              break;
          }
        }
      });

      await Isolate.spawn(
        _workerMain,
        _AsrInit(
          toMain: _fromWorker!.sendPort,
          encoder: enc,
          decoder: dec,
          tokens: tok,
          vad: vad,
          numThreads: _recognizerThreads,
        ),
      );
      return ready.future;
    } catch (e) {
      dlog('tarteel ensureWorker failed: $e');
      _initFailed = true;
      return false;
    }
  }

  Future<String> _copyAsset(String asset, String name) async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/$name');
    if (!await f.exists() || await f.length() == 0) {
      final data = await rootBundle.load(asset);
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return f.path;
  }

  @override
  Future<void> start(void Function(AsrResult) onResult) async {
    _onResult = onResult;
    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      dlog('mic permission denied');
      onResult(const AsrResult('', 0));
      return;
    }
    if (!await _ensureWorker()) {
      onResult(const AsrResult('', 0));
      return;
    }
    _micBytes = 0;
    _sentBytes = 0;
    _toWorker?.send('reset'); // fresh VAD state for this session
    _toWorker?.send('audit_begin'); // zero the worker's sample counter
    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _paused = false;
      _sub = stream.listen(
        (chunk) {
          // Count EVERYTHING the mic delivers, before any condition, so the
          // audit can detect a chunk that never made it to the worker.
          _micBytes += chunk.length;
          // Forward unconditionally while actively listening. The only skip is
          // while paused — when the mic is itself paused, so no audio is being
          // captured to lose.
          if (_running && !_paused) {
            _sentBytes += chunk.length;
            _toWorker?.send(chunk);
          }
        },
        onError: (Object e) => dlog('stream error: $e'),
        cancelOnError: false,
      );
      dlog('tarteel mic start — pcm16 ${_sampleRate}Hz mono, '
          'recognizerThreads=$_recognizerThreads provider=$_kAsrProvider '
          'decoding=greedy lang=ar (bg isolate)');
    } catch (e) {
      dlog('mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    // Pause the recorder FIRST, then set the flag. Chunks delivered while the
    // pause is in flight are still forwarded (so mic == sent — no capture-audit
    // loss); once pause() resolves the stream stops emitting, and the flag
    // guards any straggler. (Setting the flag first dropped ~in-flight chunks.)
    try {
      if (await _recorder.isRecording()) await _recorder.pause();
    } catch (_) {}
    _paused = true;
    dlog('tarteel paused');
  }

  @override
  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    _toWorker?.send('reset'); // drop audio buffered conceptually before pause
    try {
      await _recorder.resume();
    } catch (_) {}
    dlog('tarteel resumed');
  }

  @override
  Future<void> flush() async {
    // Automated stuck-recovery: reset the worker's VAD/overlap state (the same
    // 'reset' a pause/resume sends) WITHOUT pausing the mic — so no captured
    // audio is dropped. The decode for any buffered segment is discarded; fresh
    // audio starts a clean segment, which clears garbled-transcript stalls.
    if (!_running || _paused) return;
    _toWorker?.send('reset');
    dlog('tarteel flush (stuck recovery — VAD reset, mic kept live)');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _paused = false;
    await _sub?.cancel();
    _sub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    // Decode any speech still buffered in the VAD (e.g. the last words, if stop
    // lands before their trailing silence ends a segment) so nothing spoken is
    // dropped at session end. Messages are FIFO, so all already-sent chunks are
    // accepted before 'finalize' runs.
    _finalizing = true;
    _toWorker?.send('finalize');
    // Ask the worker for its sample count, so the audit reflects the whole
    // session; the 'counts' reply is logged by the _fromWorker listener.
    _toWorker?.send('audit_report');
    _toWorker?.send('reset'); // clear VAD; keep the isolate (model) cached
    dlog('tarteel mic stop');
  }
}

// --- background worker -------------------------------------------------------

class _AsrInit {
  final SendPort toMain;
  final String encoder;
  final String decoder;
  final String tokens;
  final String vad;
  final int numThreads;
  const _AsrInit({
    required this.toMain,
    required this.encoder,
    required this.decoder,
    required this.tokens,
    required this.vad,
    required this.numThreads,
  });
}

/// Runs in its own isolate: owns the Silero VAD + Whisper recognizer, consumes
/// PCM chunks, emits transcription results. Never touches the UI thread.
///
/// A/B tuning knobs (rebuild to change):
///  - _kAsrProvider: ONNX Runtime execution provider.
///      'cpu'     — baseline.
///      'nnapi'   — route to GPU/NPU/DSP (Android); may partially fall back to
///                  CPU for unsupported ops (watch logcat).
///      'xnnpack' — CPU-optimized int8 kernels; no NNAPI fallback risk.
///  - _kMaxSpeechDuration: hard cap on a VAD segment (bounds worst-case decode
///      latency, since Whisper decode time scales with audio/token length).
///  - _kMinSilenceDuration: pause length needed to END a segment (higher avoids
///      mid-word cuts on breathing pauses).
const String _kAsrProvider = 'cpu'; // 'cpu' | 'nnapi' | 'xnnpack'
// LATENCY is dominated by segment length: a result only arrives at the END of a
// VAD segment, so a long segment means the reciter is already lines ahead by the
// time the word is matched (→ false substitutions / red flash / broken flow).
// Keep segments SHORT so recognition is near-real-time. 2.0s + ~0.8s decode ≈
// ~2.5s worst-case latency (vs ~7–8s at 5s). The 0.6s overlap bridges words cut
// at the boundary, and the matcher tolerates short-context noise.
const double _kMaxSpeechDuration = 2.0; // was 5.0 — cut recognition latency
const double _kMinSilenceDuration = 0.35; // end on shorter pauses too (was 0.45)
const double _kVadThreshold = 0.5;

/// Watchdog: if this many seconds of audio arrive without the VAD ever ending a
/// segment, assume it's wedged and force a flush+drain — the same recovery that
/// pause/resume performs (which the field report confirmed un-sticks the
/// "no results at all" freeze). Must sit well above [_kMaxSpeechDuration] (5s
/// force-cut) AND above normal between-ayah pauses, or it false-fires on every
/// reading pause and flushes mid-flow (on-device logs showed 7s firing during
/// normal silence). 12s only trips on a genuine indefinite stall.
const double _kVadWatchdogSeconds = 12.0;

/// Seconds of audio carried from the END of one VAD segment into the START of
/// the next before recognition. A word clipped at a segment boundary (natural
/// silence OR a `maxSpeechDuration` force-cut) then appears whole in at least
/// one of the two adjacent recognizer calls instead of being split across both.
/// The duplicated overlap text is harmless: the matching engine treats a
/// re-recited trailing word as a context replay, not an error.
const double _kSegmentOverlap = 0.6;

void _workerMain(_AsrInit init) {
  const sampleRate = 16000;
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  sherpa.OfflineRecognizer recognizer;
  sherpa.VoiceActivityDetector vad;
  try {
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        // #3: greedy is faster than modified_beam_search (the engine tolerates
        // a little ASR noise). It's already the default; set explicitly to lock.
        decodingMethod: 'greedy_search',
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: init.encoder,
            decoder: init.decoder,
            // #1: fixed language skips Whisper's auto language-detection pass.
            language: 'ar',
            task: 'transcribe',
          ),
          tokens: init.tokens,
          numThreads: init.numThreads, // multi-core decode
          provider: _kAsrProvider, // #2: 'cpu' baseline / 'nnapi' to offload
          modelType: 'whisper',
          debug: false,
        ),
      ),
    );
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: init.vad,
          threshold: _kVadThreshold,
          // Require a longer pause to END a segment so intra-phrase breaths
          // don't cut words mid-utterance ("وَلَا يَ").
          minSilenceDuration: _kMinSilenceDuration,
          minSpeechDuration: 0.25,
          // Hard cap on segment length → bounds worst-case decode latency.
          maxSpeechDuration: _kMaxSpeechDuration,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
      ),
      bufferSizeInSeconds: 30,
    );
    init.toMain.send({'type': 'ready'});
  } catch (e) {
    init.toMain.send({'type': 'init_failed', 'error': '$e'});
    return;
  }

  Float32List toFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  // Capture audit: every sample fed into the VAD this session.
  var vadSamples = 0;
  // Watchdog: samples received since the VAD last ended a segment.
  var samplesSinceSegment = 0;
  final watchdogSamples = (_kVadWatchdogSeconds * sampleRate).round();
  // Manual segment cap (sherpa ignores maxSpeechDuration) — force-cut after this
  // much continuous detected speech so results stay near-real-time.
  final maxSegmentSamples = (_kMaxSpeechDuration * sampleRate).round();
  // Boundary overlap: tail of the previously-decoded segment.
  final overlapLen = (_kSegmentOverlap * sampleRate).round();
  Float32List? prevTail;

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0; // a segment ended → the VAD is alive

      // A manual flush mid-speech can emit an empty/near-empty segment — skip it
      // (decoding it is wasted work and yields a junk partial result).
      if (seg.samples.length < (0.2 * sampleRate)) {
        continue;
      }

      // Prepend the previous segment's tail so a word split at the boundary is
      // intact here too. `decoded` is what we hand the recognizer; `seg.samples`
      // is the raw VAD segment (used for the new tail and the timing log).
      Float32List decoded;
      if (prevTail != null && prevTail!.isNotEmpty) {
        decoded = Float32List(prevTail!.length + seg.samples.length);
        decoded.setRange(0, prevTail!.length, prevTail!);
        decoded.setRange(prevTail!.length, decoded.length, seg.samples);
      } else {
        decoded = seg.samples;
      }

      // Save this segment's tail (from the raw segment) for the next call.
      final segN = seg.samples.length;
      if (overlapLen > 0 && segN > 0) {
        final tailLen = segN < overlapLen ? segN : overlapLen;
        prevTail = Float32List.fromList(
            seg.samples.sublist(segN - tailLen, segN));
      }

      var text = '';
      // Wall-time of the full inference (encode+decode) for this segment. Note:
      // the high-level recognizer.decode() runs encode+decode together, so the
      // C-API here can't split them — this is total inference time, which is the
      // metric that matters for the A/B comparison.
      final sw = Stopwatch()..start();
      try {
        final s = recognizer.createStream();
        s.acceptWaveform(samples: decoded, sampleRate: sampleRate);
        recognizer.decode(s);
        text = recognizer.getResult(s).text;
        s.free();
      } catch (_) {
        text = '';
      }
      sw.stop();
      init.toMain.send({
        'type': 'result',
        'text': text,
        'dur': (seg.samples.length / sampleRate).toStringAsFixed(2),
        'overlap': (((decoded.length - seg.samples.length)) / sampleRate)
            .toStringAsFixed(2),
        'ms': sw.elapsedMilliseconds,
      });
    }
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      final f = toFloat(msg);
      vadSamples += f.length; // count BEFORE accepting — proof of processing
      samplesSinceSegment += f.length;
      vad.acceptWaveform(f);
      drainVad();
      // Manual maxSpeechDuration enforcement: sherpa's Silero VAD IGNORES the
      // configured maxSpeechDuration (segments ran 4–6s on device), so during
      // continuous speech we force-cut the in-progress segment ourselves once
      // it reaches the cap. This is THE latency fix — a result then arrives
      // ~every 2s instead of only when the reciter finally pauses. The 0.6s
      // overlap bridges the word at the forced cut.
      if (samplesSinceSegment >= maxSegmentSamples && vad.isDetected()) {
        try {
          vad.flush();
        } catch (_) {}
        drainVad();
      }
      // Watchdog: audio kept flowing but no segment ended for too long → the VAD
      // is likely wedged. Recover like pause/resume does (flush + drain).
      if (samplesSinceSegment >= watchdogSamples) {
        init.toMain.send({
          'type': 'watchdog',
          'secs': (samplesSinceSegment / sampleRate).toStringAsFixed(1),
        });
        try {
          vad.flush();
        } catch (_) {}
        drainVad();
        samplesSinceSegment = 0;
        prevTail = null; // start clean after a forced recovery
      }
    } else if (msg == 'reset') {
      try {
        vad.flush();
        while (!vad.isEmpty()) {
          vad.pop();
        }
      } catch (_) {}
      prevTail = null; // don't bleed overlap across a flush/new session
      samplesSinceSegment = 0;
    } else if (msg == 'finalize') {
      // End of session: force any buffered speech into a final segment and
      // decode it so the last words are never lost.
      try {
        vad.flush();
      } catch (_) {}
      drainVad();
    } else if (msg == 'audit_begin') {
      vadSamples = 0;
    } else if (msg == 'audit_report') {
      init.toMain.send({'type': 'counts', 'vadSamples': vadSamples});
    } else if (msg == 'dispose') {
      port.close();
    }
  });
}
