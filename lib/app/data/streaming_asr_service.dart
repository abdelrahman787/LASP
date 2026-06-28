/// StreamingAsrService — real-time Quran ASR via sherpa_onnx OnlineRecognizer.
///
/// Model: Muno459/fastconformer-quran-streaming (Transducer: encoder/decoder/joiner).
///
/// Key differences vs SherpaOnnxAsrService (offline CTC):
///  1. ONLINE RECOGNIZER — cache-aware encoder feeds audio continuously.
///     No hallucinations on silence: Transducer only emits tokens on speech.
///  2. ENDPOINT DETECTION — sherpa fires when trailing silence threshold met;
///     we emit the utterance and reset the stream without freeing/recreating
///     the recognizer (O(1) reset vs O(model-load) in the offline variant).
///  3. PARTIAL RESULTS — text is emitted incrementally as the model refines;
///     the RecitationController sees each update as an AsrResult.
///  4. VAD STILL RUNS — Silero gates which audio reaches the OnlineStream:
///     speech segments + short trailing silence are fed; long silence gaps are
///     skipped, reducing cache growth and power use between utterances.
///  5. ONE STREAM PER UTTERANCE — stream is reset (not freed) on endpoint;
///     on pause/resume or explicit 'reset', the stream is freed + recreated.
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
// Asset paths — user downloads from Muno459/fastconformer-quran-streaming
// (HuggingFace) and places in assets/models/streaming/ (gitignored except
// .gitkeep). The offline VAD model is reused from assets/models/tarteel/.
// ---------------------------------------------------------------------------
const String _kEncoderAsset = 'assets/models/streaming/encoder.onnx';
const String _kDecoderAsset = 'assets/models/streaming/decoder.onnx';
const String _kJoinerAsset  = 'assets/models/streaming/joiner.onnx';
const String _kTokensAsset  = 'assets/models/streaming/tokens.txt';
const String _kVadAsset     = 'assets/models/tarteel/silero_vad.onnx';

// ---------------------------------------------------------------------------
// Tuning constants (GATE TEST / UNVERIFIED — tune on-device at Gate 2)
// ---------------------------------------------------------------------------
const int _kSampleRate = 16000;
const int _kNumThreads = 2; // UNVERIFIED

// Endpoint detection (sherpa built-in).
// Rule 1: minimum trailing silence after a "long" utterance ends.
// Rule 2: minimum trailing silence after a "short" utterance ends.
// Rule 3: maximum utterance length before endpoint is forced.
const double _kRule1Silence = 2.4;  // GATE TEST: UNVERIFIED
const double _kRule2Silence = 1.2;  // GATE TEST: UNVERIFIED
const double _kRule3Length  = 20.0; // GATE TEST: UNVERIFIED

// Silero VAD — gates audio fed to OnlineStream.
const double _kVadThreshold  = 0.6;  // GATE TEST: UNVERIFIED (was 0.5 offline)
const double _kVadMinSilence = 0.5;  // GATE TEST: UNVERIFIED (was 0.35 offline)
const double _kVadMinSpeech  = 0.25;
const double _kVadMaxSpeech  = 3.0;  // GATE TEST: UNVERIFIED (was 20.0 offline)

/// Silence frames appended after each VAD segment to help the model close
/// open words before the natural pause. ~0.4 s at 16 kHz.
/// Written as literal — Dart const cannot call int() on a double expression.
const int _kTrailingSilenceSamples = 6400; // = 16000 * 0.4

const double _kVadWatchdogSeconds = 12.0;

// ---------------------------------------------------------------------------
// Main-isolate service
// ---------------------------------------------------------------------------

/// Real-time streaming ASR implementing [AsrService] via the FastConformer-
/// Transducer model (Muno459/fastconformer-quran-streaming). Uses sherpa_onnx
/// OnlineRecognizer with built-in endpoint detection and no hallucinations.
class StreamingAsrService implements AsrService {
  final AudioRecorder _recorder = AudioRecorder();
  bool _running    = false;
  bool _paused     = false;
  bool _initFailed = false;
  bool _finalizing = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

  SendPort? _toWorker;
  ReceivePort? _fromWorker;

  Future<bool> _ensureWorker() async {
    if (_toWorker != null) return true;
    if (_initFailed) return false;
    try {
      final encoder = await _copyAsset(_kEncoderAsset, 'streaming_encoder.onnx');
      final decoder = await _copyAsset(_kDecoderAsset, 'streaming_decoder.onnx');
      final joiner  = await _copyAsset(_kJoinerAsset,  'streaming_joiner.onnx');
      final tokens  = await _copyAsset(_kTokensAsset,  'streaming_tokens.txt');
      final vad     = await _copyAsset(_kVadAsset,     'streaming_silero_vad.onnx');

      _fromWorker = ReceivePort();
      final ready = Completer<bool>();

      _fromWorker!.listen((msg) {
        if (msg is SendPort) {
          _toWorker = msg;
        } else if (msg is Map) {
          switch (msg['type'] as String?) {
            case 'ready':
              if (!ready.isCompleted) ready.complete(true);
            case 'init_failed':
              _initFailed = true;
              dlog('[ASR] streaming worker init failed: ${msg['error']}');
              if (!ready.isCompleted) ready.complete(false);
            case 'partial':
              if (_running && !_paused) {
                final text = (msg['text'] as String).trim();
                if (text.isNotEmpty) {
                  // Confidence 0.85 nominal — UNVERIFIED, same as offline service.
                  _onResult?.call(AsrResult(text, 0.85));
                }
              }
            case 'result':
              final text     = (msg['text']     as String).trim();
              final audioSec = msg['audioSec']  as double;
              final inferMs  = msg['inferMs']   as int;
              final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;
              dlog('[ASR] endpoint: "${text.isEmpty ? '(empty)' : text}" '
                  'audio=${audioSec.toStringAsFixed(2)}s '
                  'infer=${inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
              if ((_running && !_paused) || _finalizing) {
                _finalizing = false;
                _onResult?.call(AsrResult(text, text.isEmpty ? 0.0 : 0.85));
              }
            case 'watchdog':
              dlog('[ASR] watchdog — no VAD segment for ${msg['secs']}s; '
                  'forced flush (self-healing).');
          }
        }
      });

      await Isolate.spawn(
        _workerMain,
        _WorkerInit(
          toMain:      _fromWorker!.sendPort,
          encoderPath: encoder,
          decoderPath: decoder,
          joinerPath:  joiner,
          tokensPath:  tokens,
          vadPath:     vad,
          numThreads:  _kNumThreads,
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
    _toWorker?.send('reset');
    try {
      final micStream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _kSampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _paused  = false;
      _sub = micStream.listen(
        (chunk) {
          if (_running && !_paused) _toWorker?.send(chunk);
        },
        onError: (Object e) => dlog('[ASR] stream error: $e'),
        cancelOnError: false,
      );
      dlog('[ASR] streaming mic started — PCM16 ${_kSampleRate}Hz mono, '
          'FastConformer-Transducer, threads=$_kNumThreads, '
          'endpointRule1=${_kRule1Silence}s rule2=${_kRule2Silence}s');
    } catch (e) {
      dlog('[ASR] mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    // Stop recorder FIRST (CLAUDE.md item 5), then set flag.
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
    if (!_running || _paused) return;
    _toWorker?.send('flush');
    dlog('[ASR] flush (stuck recovery — VAD force-flush, stream live)');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _paused  = false;
    await _sub?.cancel();
    _sub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    // Flush last buffered speech so final words are not lost (CLAUDE.md #11).
    _finalizing = true;
    _toWorker?.send('finalize');
    dlog('[ASR] stopped');
  }
}

// ---------------------------------------------------------------------------
// Background isolate
// ---------------------------------------------------------------------------

class _WorkerInit {
  final SendPort toMain;
  final String encoderPath;
  final String decoderPath;
  final String joinerPath;
  final String tokensPath;
  final String vadPath;
  final int numThreads;
  const _WorkerInit({
    required this.toMain,
    required this.encoderPath,
    required this.decoderPath,
    required this.joinerPath,
    required this.tokensPath,
    required this.vadPath,
    required this.numThreads,
  });
}

/// Worker isolate: owns OnlineRecognizer + OnlineStream + Silero VAD.
///
/// Audio pipeline:
///   mic chunk → VAD → speech segment (+ trailing silence) → OnlineStream
///             → decode loop → partial result
///             → endpoint check → final result + stream reset
///
/// Message protocol:
///   main→worker  Uint8List   — PCM16LE mic chunk
///   main→worker  'reset'     — reset VAD + stream (pause/resume or new session)
///   main→worker  'flush'     — force VAD flush (stuck recovery)
///   main→worker  'finalize'  — flush, signal inputFinished, emit final result
///   main→worker  'dispose'   — release native resources
///
///   worker→main  SendPort                               — handshake
///   worker→main  {type:'ready'}
///   worker→main  {type:'init_failed', error:String}
///   worker→main  {type:'partial', text:String}
///   worker→main  {type:'result', text, audioSec, inferMs}
///   worker→main  {type:'watchdog', secs:String}
void _workerMain(_WorkerInit init) {
  const sampleRate = _kSampleRate;
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  late sherpa.OnlineRecognizer recognizer;
  late sherpa.OnlineStream stream;
  late sherpa.VoiceActivityDetector vad;

  try {
    sherpa.initBindings();

    // Load the streaming Transducer. The recognizer is created once and kept
    // for the entire session — no per-utterance reload (unlike offline Variant B).
    recognizer = sherpa.OnlineRecognizer(
      sherpa.OnlineRecognizerConfig(
        model: sherpa.OnlineModelConfig(
          transducer: sherpa.OnlineTransducerModelConfig(
            encoder: init.encoderPath,
            decoder: init.decoderPath,
            joiner:  init.joinerPath,
          ),
          tokens: init.tokensPath,
          numThreads: init.numThreads,
          debug: false,
        ),
        feat: const sherpa.FeatureConfig(
          sampleRate: sampleRate,
          featureDim: 80,
        ),
        decodingMethod: 'greedy_search',
        maxActivePaths: 4,
        enableEndpoint: true,
        rule1MinTrailingSilence: _kRule1Silence,
        rule2MinTrailingSilence: _kRule2Silence,
        rule3MinUtteranceLength: _kRule3Length,
      ),
    );

    // One stream per utterance; reset (not free+create) on endpoint.
    stream = recognizer.createStream();

    // Silero VAD — same model used by the offline service.
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: init.vadPath,
          threshold: _kVadThreshold,
          minSilenceDuration: _kVadMinSilence,
          minSpeechDuration: _kVadMinSpeech,
          maxSpeechDuration: _kVadMaxSpeech,
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

  // Convert PCM16LE bytes → Float32 [-1, 1].
  Float32List toFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  final sw = Stopwatch();
  var utteranceAudioSamples = 0;
  var utteranceInferMs      = 0;
  var samplesSinceSegment   = 0;
  final watchdogSamples     = (_kVadWatchdogSeconds * sampleRate).round();
  final trailingSilence     = Float32List(_kTrailingSilenceSamples); // zeros

  // Feed [samples] into OnlineStream, run the decode loop, emit partial text,
  // and check for endpoint. [countAudio] is false for synthetic silence frames.
  void feedAndDecode(Float32List samples, {bool countAudio = true}) {
    if (samples.isEmpty) return;
    sw.reset();
    sw.start();
    stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
    while (recognizer.isReady(stream)) {
      recognizer.decode(stream);
    }
    sw.stop();
    utteranceInferMs += sw.elapsedMilliseconds;
    if (countAudio) utteranceAudioSamples += samples.length;

    // Emit incremental text.
    final partial = recognizer.getResult(stream).text.trim();
    if (partial.isNotEmpty) {
      init.toMain.send({'type': 'partial', 'text': partial});
    }

    // Endpoint fired → emit utterance result, reset stream in-place.
    if (recognizer.isEndpoint(stream)) {
      final text     = recognizer.getResult(stream).text.trim();
      final audioSec = utteranceAudioSamples / sampleRate;
      init.toMain.send({
        'type':     'result',
        'text':     text,
        'audioSec': audioSec,
        'inferMs':  utteranceInferMs,
      });
      recognizer.reset(stream); // keeps stream object, clears internal state
      utteranceAudioSamples = 0;
      utteranceInferMs      = 0;
    }
  }

  // Drain all complete VAD segments. Each segment gets ~0.4 s of silence
  // appended so the model can close open words at the natural pause boundary.
  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0;
      if (seg.samples.length < (0.1 * sampleRate)) continue; // skip VAD artifacts
      feedAndDecode(seg.samples);
      feedAndDecode(trailingSilence, countAudio: false);
    }
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      final f = toFloat(msg);
      samplesSinceSegment += f.length;
      vad.acceptWaveform(f);
      drainVad();

      // VAD watchdog: recover from a wedged state (no segment for too long).
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
      }
    } else if (msg == 'reset') {
      // Full stream reset — used on pause/resume or session restart.
      try {
        vad.flush();
        while (!vad.isEmpty()) {
          vad.pop();
        }
      } catch (_) {}
      stream.free();
      stream = recognizer.createStream();
      utteranceAudioSamples = 0;
      utteranceInferMs      = 0;
      samplesSinceSegment   = 0;
    } else if (msg == 'flush') {
      // Stuck recovery: force-flush VAD without resetting the stream.
      try {
        vad.flush();
      } catch (_) {}
      drainVad();
    } else if (msg == 'finalize') {
      // End of session: flush VAD, feed last segment, signal end-of-input,
      // then emit whatever text the model has accumulated (CLAUDE.md #11).
      try {
        vad.flush();
      } catch (_) {}
      drainVad();
      stream.inputFinished();
      while (recognizer.isReady(stream)) {
        recognizer.decode(stream);
      }
      final text     = recognizer.getResult(stream).text.trim();
      final audioSec = utteranceAudioSamples / sampleRate;
      if (text.isNotEmpty) {
        init.toMain.send({
          'type':     'result',
          'text':     text,
          'audioSec': audioSec,
          'inferMs':  utteranceInferMs,
        });
      }
      // Prepare for a potential restart without reloading the recognizer.
      stream.free();
      stream = recognizer.createStream();
      utteranceAudioSamples = 0;
      utteranceInferMs      = 0;
    } else if (msg == 'dispose') {
      try {
        stream.free();
        recognizer.free();
        port.close();
      } catch (_) {}
    }
  });
}
