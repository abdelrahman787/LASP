/// StreamingAsrService — sherpa-onnx OfflineRecognizer (Variant B) + Silero VAD.
///
/// Model: model_int8.onnx  (Gate-1 proven offline NeMo-CTC)
///   Offline (non-streaming) model fed short VAD segments (≤ 8 s).
///   Correct Quran transcription confirmed at Gate-1 (RTF ≈ 0.032–0.053).
///
/// The streaming model (model_streaming_with_encoder.q8.onnx) requires
/// rolling cache tensors and onnxruntime — which conflicts with sherpa_onnx's
/// bundled libonnxruntime.so. Using the offline model + VAD segmentation gives
/// near-real-time response with correct output and no hallucination.
///
/// Pipeline per VAD speech segment (≤ 8 s):
///   VAD segments audio → OfflineRecognizer.decode(stream) → greedy result
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
// Asset paths
// ---------------------------------------------------------------------------
/// Gate-1 proven offline NeMo-CTC model (sherpa metadata already present).
const String _kModelAsset  = 'assets/models/tarteel/model_int8.onnx';
const String _kTokensAsset = 'assets/models/tarteel/tokens.txt';
const String _kVadAsset    = 'assets/models/tarteel/silero_vad.onnx';

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------
const int    _kSampleRate       = 16000;
const int    _kNumThreads       = 2;

/// Minimum decodeable segment (0.2 s). Shorter VAD artifacts are skipped.
const int    _kMinDecodeSamples = 3200;

// Silero VAD
const double _kVadThreshold    = 0.5;
const double _kVadMinSilence   = 0.35;
const double _kVadMinSpeech    = 0.25;
// Offline model handles up to 8 s cleanly (proven at Gate-1).
const double _kVadMaxSpeech    = 8.0;

const double _kWatchdogSeconds = 10.0;

// ---------------------------------------------------------------------------
// Main-isolate service
// ---------------------------------------------------------------------------

class StreamingAsrService implements AsrService {
  final AudioRecorder _recorder = AudioRecorder();
  bool _running    = false;
  bool _paused     = false;
  bool _initFailed = false;
  bool _finalizing = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

  SendPort?    _toWorker;
  ReceivePort? _fromWorker;

  Future<bool> _ensureWorker() async {
    if (_toWorker   != null) return true;
    if (_initFailed)          return false;
    try {
      final model  = await _copyAsset(_kModelAsset,  'streaming_svc_model.onnx');
      final tokens = await _copyAsset(_kTokensAsset, 'streaming_svc_tokens.txt');
      final vad    = await _copyAsset(_kVadAsset,    'streaming_svc_vad.onnx');

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
              dlog('[ASR] streaming worker init_failed: ${msg['error']}');
              if (!ready.isCompleted) ready.complete(false);
            case 'result':
              final text    = (msg['text']    as String).trim();
              final audioSec = msg['audioSec'] as double;
              final inferMs  = msg['inferMs']  as int;
              final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;
              dlog('[ASR] result: "${text.isEmpty ? "(empty)" : text}" '
                  'audio=${audioSec.toStringAsFixed(2)}s '
                  'infer=${inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
              if ((_running && !_paused) || _finalizing) {
                _finalizing = false;
                _onResult?.call(AsrResult(text, text.isEmpty ? 0.0 : 0.85));
              }
            case 'watchdog':
              dlog('[ASR] watchdog — no VAD for ${msg['secs']}s; flushing.');
          }
        }
      });

      await Isolate.spawn(
        _workerMain,
        _WorkerInit(
          toMain:     _fromWorker!.sendPort,
          modelPath:  model,
          tokensPath: tokens,
          vadPath:    vad,
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
    final f   = File('${dir.path}/$fileName');
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
          encoder:     AudioEncoder.pcm16bits,
          sampleRate:  _kSampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _paused  = false;
      _sub = micStream.listen(
        (chunk) { if (_running && !_paused) _toWorker?.send(chunk); },
        onError:      (Object e) => dlog('[ASR] stream error: $e'),
        cancelOnError: false,
      );
      dlog('[ASR] streaming mic started — PCM16 ${_kSampleRate}Hz mono, '
          'NeMo-CTC offline model via sherpa-onnx + Silero VAD, '
          'VAD max=${_kVadMaxSpeech}s, threads=$_kNumThreads');
    } catch (e) {
      dlog('[ASR] mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    try { if (await _recorder.isRecording()) await _recorder.pause(); } catch (_) {}
    _paused = true;
    dlog('[ASR] paused');
  }

  @override
  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    _toWorker?.send('reset');
    try { await _recorder.resume(); } catch (_) {}
    dlog('[ASR] resumed');
  }

  @override
  Future<void> flush() async {
    if (!_running || _paused) return;
    _toWorker?.send('flush');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _paused  = false;
    await _sub?.cancel();
    _sub = null;
    try { if (await _recorder.isRecording()) await _recorder.stop(); } catch (_) {}
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
  final String   modelPath;
  final String   tokensPath;
  final String   vadPath;
  final int      numThreads;
  const _WorkerInit({
    required this.toMain,
    required this.modelPath,
    required this.tokensPath,
    required this.vadPath,
    required this.numThreads,
  });
}

/// PCM16LE bytes → Float32 [-1, 1].
Float32List _toFloat(Uint8List bytes) {
  final n  = bytes.length ~/ 2;
  final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

/// Worker isolate: Silero VAD (sherpa-onnx) + fresh OfflineRecognizer per segment.
///
/// Gate-1 proved on arm64 (Motorola Edge 50) that a SHARED recognizer
/// SIGSEGVs inside SherpaOnnxDecodeOfflineStream after the first segment.
/// Variant B (fresh recognizer + stream per segment, freed after each) is
/// stable and proven.  Model-load cost per segment is ~60–180 ms on this
/// device — acceptable for a natural-pause triggered pipeline.
void _workerMain(_WorkerInit init) {
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  late sherpa.VoiceActivityDetector vad;

  // ---- build a fresh OfflineRecognizer (Variant B — one per segment) --------
  sherpa.OfflineRecognizer _buildRecognizer() => sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          decodingMethod: 'greedy_search',
          feat: const sherpa.FeatureConfig(
            sampleRate: _kSampleRate,
            featureDim: 80,
          ),
          model: sherpa.OfflineModelConfig(
            nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(
              model: init.modelPath,
            ),
            tokens:     init.tokensPath,
            numThreads: init.numThreads,
            modelType:  'nemo_ctc',
            debug:      false,
          ),
        ),
      );

  // ---- initialise bindings + VAD (once) -------------------------------------
  try {
    sherpa.initBindings();

    // Probe: build one recognizer to validate the model loads, then free it.
    _buildRecognizer().free();

    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model:              init.vadPath,
          threshold:          _kVadThreshold,
          minSilenceDuration: _kVadMinSilence,
          minSpeechDuration:  _kVadMinSpeech,
          maxSpeechDuration:  _kVadMaxSpeech,
        ),
        sampleRate: _kSampleRate,
        numThreads: 1,
      ),
      bufferSizeInSeconds: 30,
    );

    init.toMain.send({'type': 'ready'});
  } catch (e) {
    init.toMain.send({'type': 'init_failed', 'error': '$e'});
    return;
  }

  // ---- decode one segment (Variant B: fresh recognizer, freed after) --------
  final sw = Stopwatch();

  void decodeSegment(sherpa.SpeechSegment seg) {
    if (seg.samples.length < _kMinDecodeSamples) return;

    sw.reset(); sw.start();
    final rec    = _buildRecognizer();
    final stream = rec.createStream();
    stream.acceptWaveform(samples: seg.samples, sampleRate: _kSampleRate);
    rec.decode(stream);
    final result = rec.getResult(stream);
    stream.free();
    rec.free();
    sw.stop();

    final text = result.text.trim();
    final audioSec = seg.samples.length / _kSampleRate.toDouble();
    init.toMain.send({
      'type':     'result',
      'text':     text,
      'audioSec': audioSec,
      'inferMs':  sw.elapsedMilliseconds,
    });
  }

  // ---- VAD drain ------------------------------------------------------------
  var samplesSinceSegment = 0;
  final watchdogSamples   = (_kWatchdogSeconds * _kSampleRate).round();

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0;
      decodeSegment(seg);
    }
  }

  // ---- message loop ---------------------------------------------------------
  port.listen((msg) {
    if (msg is Uint8List) {
      final f = _toFloat(msg);
      samplesSinceSegment += f.length;
      vad.acceptWaveform(f);
      drainVad();

      if (samplesSinceSegment >= watchdogSamples) {
        init.toMain.send({
          'type': 'watchdog',
          'secs': (samplesSinceSegment / _kSampleRate).toStringAsFixed(1),
        });
        try { vad.flush(); } catch (_) {}
        drainVad();
        samplesSinceSegment = 0;
      }
    } else if (msg == 'reset') {
      try {
        vad.flush();
        while (!vad.isEmpty()) { vad.pop(); }
      } catch (_) {}
      samplesSinceSegment = 0;
    } else if (msg == 'flush') {
      try { vad.flush(); } catch (_) {}
      drainVad();
    } else if (msg == 'finalize') {
      try { vad.flush(); } catch (_) {}
      drainVad();
    } else if (msg == 'dispose') {
      try { port.close(); } catch (_) {}
    }
  });
}
