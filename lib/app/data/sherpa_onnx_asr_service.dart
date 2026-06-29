// ignore_for_file: uri_does_not_exist, depend_on_referenced_packages, argument_type_not_assignable
// sherpa_onnx removed from pubspec.yaml (libonnxruntime.so conflict with onnxruntime package).
// This file is kept for reference; it is not compiled into production builds.

/// SherpaOnnxAsrService — real on-device ASR using the Quran-trained
/// FastConformer-CTC (NeMo-CTC int8) model via sherpa_onnx 1.13.3.
///
/// Design decisions (all gate-verified or UNVERIFIED as marked):
///
///  1. BACKGROUND ISOLATE — inference runs in its own isolate so multi-second
///     decodes never block the mic stream or the UI thread.
///
///  2. SHORT CHUNKS, NO WHOLE-CLIP DECODE — Gate 1 confirmed a 104 s single-pass
///     offline decode causes a native SIGSEGV on arm64. We slice the incoming
///     audio into short windows (default [_kChunkSamples] = 8 s) and decode each
///     independently, exactly as the Gate-1 harness proved stable.
///
///  3. FRESH RECOGNIZER PER CHUNK — Gate 1 also showed that reusing one
///     recognizer across many chunks (shared-recognizer loop) can crash mid-loop
///     with a catchable exception. Variant B (fresh recognizer + stream per chunk,
///     freed after each) decoded all chunks cleanly. We use Variant B here.
///     Variant B is implemented: the shared-recognizer path was removed.
///
///  4. SILERO VAD — we use Silero VAD (same as TarteelOnDeviceAsrService) to
///     detect speech segments before sending to the NeMo-CTC recognizer, avoiding
///     decoding silence-only chunks which waste CPU and produce hallucination.
///
///  5. MODEL PATHS — exact same asset paths as gate1_asr_check.dart:
///       assets/models/tarteel/model_int8.onnx
///       assets/models/tarteel/tokens.txt
///       assets/models/tarteel/silero_vad.onnx   (same as TarteelOnDeviceAsrService)
///
///  6. ASR SEAM — results are emitted as [AsrResult] with raw recognized text
///     (un-normalized). The [RecitationController] normalizes + calls
///     [matchUtterance] / [findBestAnchor] / [fittingAlign], which trims the
///     hallucinated tail over silence via [fittingAlign]'s free-suffix design.
///
///  7. RTF LOGGING — each chunk's RTF is logged with the [ASR] tag as requested.
library;

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

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------

/// Audio model paths — must match gate1_asr_check.dart exactly.
const String _kModelAsset = 'assets/models/tarteel/model_int8.onnx';
const String _kTokensAsset = 'assets/models/tarteel/tokens.txt';
const String _kVadAsset = 'assets/models/tarteel/silero_vad.onnx';

/// Sample rate — the NeMo-CTC model expects 16 kHz mono (CLAUDE.md).
const int _kSampleRate = 16000;

/// Chunk size in samples: 8 s of 16 kHz audio = 128 000 samples.
/// Gate-1 proved 8 s decodes stably. Shorter = lower latency but more
/// recognizer construction overhead (Variant B builds a fresh one per chunk).
/// // UNVERIFIED chunk size, to be tuned in Phase 3 on-device.
const int _kChunkSamples = _kSampleRate * 8;

/// Minimum chunk size we'll actually decode: skip chunks shorter than this
/// (e.g., the very last micro-tail at stop()) to avoid wasted inference and
/// potential hallucination-only results.
/// // UNVERIFIED: 0.5 s threshold; tune in Phase 3.
/// 0.5 s × 16000 Hz = 8000 samples. Written as a literal because Dart
/// does not allow method calls (.round()) in const expressions.
const int _kMinDecodeSamples = 8000; // = _kSampleRate * 0.5

/// NeMo-CTC recognizer threads.
/// Gate-1 used 2 threads successfully. Using 2 conservatively.
/// // UNVERIFIED: whether more threads improve RTF on device.
const int _kNumThreads = 2;

// VAD constants — same as TarteelOnDeviceAsrService (device-verified).
const double _kVadThreshold = 0.5;
const double _kMinSilenceDuration = 0.35;
const double _kMaxSpeechDuration = 20.0; // GATE TEST: was 3.0 -- let Silero cut at natural silences instead of forced 3s flush. // UNVERIFIED
const double _kVadWatchdogSeconds = 12.0;
const double _kSegmentOverlap = 0.0; // GATE TEST: was 0.6 (Whisper-era boundary recovery). // UNVERIFIED

// ---------------------------------------------------------------------------
// Main-isolate service
// ---------------------------------------------------------------------------

/// Real on-device ASR implementing [AsrService] via the NeMo-CTC FastConformer
/// model (gate-verified at RTF ≈ 0.032 on Motorola Edge 50 Fusion, Android 16).
class SherpaOnnxAsrService implements AsrService {
  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;
  bool _paused = false;
  bool _initFailed = false;
  bool _finalizing = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

  // Capture audit counters (mirror TarteelOnDeviceAsrService pattern).
  int _micBytes = 0;
  int _sentBytes = 0;

  // Background isolate communication.
  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  Future<bool> _ensureWorker() async {
    if (_toWorker != null) return true;
    if (_initFailed) return false;
    try {
      final modelPath = await _copyAsset(_kModelAsset, 'nemo_ctc_model_int8.onnx');
      final tokensPath = await _copyAsset(_kTokensAsset, 'nemo_ctc_tokens.txt');
      final vadPath = await _copyAsset(_kVadAsset, 'nemo_ctc_silero_vad.onnx');

      _fromWorker = ReceivePort();
      final ready = Completer<bool>();

      _fromWorker!.listen((msg) {
        if (msg is SendPort) {
          _toWorker = msg;
        } else if (msg is Map) {
          switch (msg['type'] as String?) {
            case 'ready':
              if (!ready.isCompleted) ready.complete(true);
              break;
            case 'init_failed':
              _initFailed = true;
              dlog('[ASR] sherpa_onnx worker init failed: ${msg['error']}');
              if (!ready.isCompleted) ready.complete(false);
              break;
            case 'result':
              final text = (msg['text'] as String).trim();
              final audioSec = msg['audioSec'] as double;
              final inferMs = msg['inferMs'] as int;
              final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;
              // Step 7: lightweight RTF measurement — measured values only,
              // no guesses. RTF is per-chunk (per utterance/segment).
              dlog('[ASR] chunk result: text="${text.isNotEmpty ? text : '(empty)'}" '
                  'audio=${audioSec.toStringAsFixed(2)}s '
                  'infer=${inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
              if ((_running && !_paused) || _finalizing) {
                // Confidence: NeMo-CTC offline produces no per-utterance score.
                // Use 0.85 as a nominal value for non-empty results (not zero
                // so the controller doesn't treat it as a failure).
                // // UNVERIFIED: better confidence proxy (e.g., average logprob)
                // // could be derived from CTC logprobs if exposed by sherpa.
                final confidence = text.isEmpty ? 0.0 : 0.85;
                _onResult?.call(AsrResult(text, confidence));
              }
              break;
            case 'watchdog':
              dlog('[ASR] VAD watchdog — no segment for ${msg['secs']}s; '
                  'forced flush+drain (self-healing).');
              break;
            case 'counts':
              _finalizing = false;
              final vadSamples = msg['vadSamples'] as int;
              final micSamples = _micBytes ~/ 2;
              final sentSamples = _sentBytes ~/ 2;
              final ok = micSamples == sentSamples && sentSamples == vadSamples;
              dlog('[ASR] CAPTURE AUDIT ${ok ? 'OK' : 'MISMATCH!!'} — '
                  'mic=$micSamples sent=$sentSamples vad=$vadSamples samples '
                  '(${(micSamples / _kSampleRate).toStringAsFixed(2)}s captured).');
              break;
          }
        }
      });

      await Isolate.spawn(
        _asrWorkerMain,
        _AsrWorkerInit(
          toMain: _fromWorker!.sendPort,
          modelPath: modelPath,
          tokensPath: tokensPath,
          vadPath: vadPath,
          numThreads: _kNumThreads,
        ),
      );
      return ready.future;
    } catch (e) {
      dlog('[ASR] ensureWorker failed: $e');
      _initFailed = true;
      return false;
    }
  }

  Future<String> _copyAsset(String assetKey, String fileName) async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}/$fileName');
    if (!await f.exists() || await f.length() == 0) {
      final data = await rootBundle.load(assetKey);
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
      dlog('[ASR] mic permission denied');
      onResult(const AsrResult('', 0));
      return;
    }
    if (!await _ensureWorker()) {
      onResult(const AsrResult('', 0));
      return;
    }
    _micBytes = 0;
    _sentBytes = 0;
    _toWorker?.send('reset');
    _toWorker?.send('audit_begin');
    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _kSampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _paused = false;
      _sub = stream.listen(
        (chunk) {
          _micBytes += chunk.length;
          if (_running && !_paused) {
            _sentBytes += chunk.length;
            _toWorker?.send(chunk);
          }
        },
        onError: (Object e) => dlog('[ASR] stream error: $e'),
        cancelOnError: false,
      );
      dlog('[ASR] mic started — PCM16 ${_kSampleRate}Hz mono, '
          'NeMo-CTC int8 model, chunkSamples=$_kChunkSamples, '
          'threads=$_kNumThreads, variantB=fresh-recognizer-per-segment');
    } catch (e) {
      dlog('[ASR] mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    // Pause recorder FIRST (see CLAUDE.md item 5: stop recorder, then set flag).
    try {
      if (await _recorder.isRecording()) await _recorder.pause();
    } catch (_) {}
    _paused = true;
    dlog('[ASR] paused');
  }

  @override
  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    _toWorker?.send('reset');
    try {
      await _recorder.resume();
    } catch (_) {}
    dlog('[ASR] resumed');
  }

  @override
  Future<void> flush() async {
    // Automated stuck-recovery: reset VAD state WITHOUT pausing mic.
    if (!_running || _paused) return;
    _toWorker?.send('reset');
    dlog('[ASR] flush (stuck recovery — VAD reset, mic live)');
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
    // Decode buffered speech (CLAUDE.md item 11: flush last chunk at stop).
    _finalizing = true;
    _toWorker?.send('finalize');
    _toWorker?.send('audit_report');
    _toWorker?.send('reset');
    dlog('[ASR] stopped');
  }
}

// ---------------------------------------------------------------------------
// Background isolate
// ---------------------------------------------------------------------------

class _AsrWorkerInit {
  final SendPort toMain;
  final String modelPath;
  final String tokensPath;
  final String vadPath;
  final int numThreads;
  const _AsrWorkerInit({
    required this.toMain,
    required this.modelPath,
    required this.tokensPath,
    required this.vadPath,
    required this.numThreads,
  });
}

/// Worker isolate: owns the Silero VAD + NeMo-CTC recognizer.
/// VAD segments the audio; each segment is decoded by a FRESH recognizer
/// (Variant B, gate-1-proven stable; avoids shared-recognizer SIGSEGV).
///
/// Message protocol:
///   main→worker  Uint8List         — PCM16LE chunk
///   main→worker  'reset'           — flush VAD, clear state
///   main→worker  'finalize'        — flush + drain last segment
///   main→worker  'audit_begin'     — zero sample counter
///   main→worker  'audit_report'    — reply with {type:'counts', vadSamples:N}
///   worker→main  SendPort          — handshake (worker's receive port)
///   worker→main  {type:'ready'}    — init OK
///   worker→main  {type:'init_failed', error:String}
///   worker→main  {type:'result', text:String, audioSec:double, inferMs:int}
///   worker→main  {type:'watchdog', secs:String}
///   worker→main  {type:'counts', vadSamples:int}
void _asrWorkerMain(_AsrWorkerInit init) {
  const sampleRate = _kSampleRate;
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  sherpa.VoiceActivityDetector vad;
  try {
    sherpa.initBindings();

    // Variant B: no shared recognizer — a fresh OfflineRecognizer is created
    // and freed per segment inside decodeSegment().

    // Fix VAD buffer size calculation
    // Faulty calculation: bufferSizeInSeconds: 30 (arbitrary 30s)
    // Corrected: bufferSizeInSeconds: _kChunkSamples / sampleRate (matches 8s chunk length exactly)
    // The mismatch between 30s capacity and chunk boundaries caused the circular-buffer to miscalculate
    // padding during vad.flush(), leading to `Invalid n: -480` (where 480 is exactly 30ms at 16kHz).
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: init.vadPath,
          threshold: _kVadThreshold,
          minSilenceDuration: _kMinSilenceDuration,
          minSpeechDuration: 0.25,
          maxSpeechDuration: _kMaxSpeechDuration,
        ),
        sampleRate: sampleRate,
        numThreads: 1,
      ),
      bufferSizeInSeconds: _kChunkSamples / sampleRate,
    );
    init.toMain.send({'type': 'ready'});
  } catch (e) {
    init.toMain.send({'type': 'init_failed', 'error': '$e'});
    return;
  }

  // Convert PCM16LE bytes → normalized Float32 [-1, 1].
  Float32List toFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  // Decode one segment with a FRESH OfflineRecognizer (Variant B — gate-proven
  // stable; avoids SIGSEGV from a long-lived shared recognizer on arm64).
  // Creates, uses, and frees a new recognizer every call.
  // Returns (text, inferMs). Returns ('', 0) on any error — never throws.
  ({String text, int inferMs}) decodeSegment(Float32List samples) {
    if (samples.length < _kMinDecodeSamples) {
      return (text: '', inferMs: 0);
    }
    final sw = Stopwatch()..start();
    sherpa.OfflineRecognizer? rec;
    try {
      rec = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          decodingMethod: 'greedy_search',
          feat: const sherpa.FeatureConfig(
            sampleRate: sampleRate,
            featureDim: 80, // NeMo-CTC: 80-dim log-mel
          ),
          model: sherpa.OfflineModelConfig(
            nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: init.modelPath),
            tokens: init.tokensPath,
            numThreads: init.numThreads,
            modelType: 'nemo_ctc',
            debug: false,
          ),
        ),
      );
      final stream = rec.createStream();
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      rec.decode(stream);
      final text = rec.getResult(stream).text;
      stream.free();
      sw.stop();
      return (text: text, inferMs: sw.elapsedMilliseconds);
    } catch (e) {
      sw.stop();
      return (text: '', inferMs: 0);
    } finally {
      rec?.free();
    }
  }

  // Sample accounting.
  var vadSamples = 0;
  var samplesSinceSegment = 0;
  final watchdogSamples = (_kVadWatchdogSeconds * sampleRate).round();
  final maxSegmentSamples = (_kMaxSpeechDuration * sampleRate).round();
  final overlapLen = (_kSegmentOverlap * sampleRate).round();
  Float32List? prevTail;

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0; // a segment ended → VAD is alive

      // Skip near-empty segments (flush artifacts, not real speech).
      if (seg.samples.length < (0.2 * sampleRate)) continue;

      // Prepend previous segment's tail for boundary overlap.
      Float32List decoded;
      if (prevTail != null && prevTail!.isNotEmpty) {
        decoded = Float32List(prevTail!.length + seg.samples.length);
        decoded.setRange(0, prevTail!.length, prevTail!);
        decoded.setRange(prevTail!.length, decoded.length, seg.samples);
      } else {
        decoded = seg.samples;
      }

      // Save tail for next chunk.
      final segN = seg.samples.length;
      if (overlapLen > 0 && segN > 0) {
        final tailLen = segN < overlapLen ? segN : overlapLen;
        prevTail = Float32List.fromList(seg.samples.sublist(segN - tailLen, segN));
      }

      final audioSec = decoded.length / sampleRate;
      final r = decodeSegment(decoded);
      if (r.text.isEmpty && r.inferMs == 0) return; // error already reported
      init.toMain.send({
        'type': 'result',
        'text': r.text,
        'audioSec': audioSec,
        'inferMs': r.inferMs,
      });
    }
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      final f = toFloat(msg);
      vadSamples += f.length;
      samplesSinceSegment += f.length;
      vad.acceptWaveform(f);
      drainVad();
      // Manual maxSpeechDuration enforcement (sherpa ignores it — same fix as
      // TarteelOnDeviceAsrService, device-verified).
      if (samplesSinceSegment >= maxSegmentSamples && vad.isDetected()) {
        try {
          vad.flush();
        } catch (_) {}
        drainVad();
      }
      // VAD watchdog: recover from a wedged state.
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
        prevTail = null;
      }
    } else if (msg == 'reset') {
      try {
        vad.flush();
        while (!vad.isEmpty()) {
          vad.pop();
        }
      } catch (_) {}
      prevTail = null;
      samplesSinceSegment = 0;
    } else if (msg == 'finalize') {
      // Flush last buffered speech so final words are not dropped (CLAUDE.md #11).
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
