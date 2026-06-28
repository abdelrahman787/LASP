/// StreamingAsrService — real-time Quran ASR via the NeMo streaming-CTC model.
///
/// Model: Muno459/fastconformer-quran (streaming variant)
///   File: model_streaming_with_encoder.q8.onnx  (~132 MB, INT8-quantised)
///   Tokenizer: tokens.txt (1025 lines incl. <blk> 1024)
///   CMVN: applied internally by the model (streaming variant ships global CMVN
///         baked in); sherpa-onnx FeatureConfig handles per-feature normalisation.
///
/// Architecture:
///   Silero VAD gates audio → speech segments + trailing silence fed to a fresh
///   OfflineRecognizer per segment (Variant B — proven stable at Gate-1).
///   The streaming model is cache-aware inside the ONNX graph; sherpa-onnx
///   feeds each chunk in one shot so there are no user-visible seam artefacts.
///
/// Why not OnlineRecognizer?
///   The downloaded model is a single-file CTC graph, NOT a Transducer
///   (encoder/decoder/joiner). sherpa-onnx's OnlineRecognizer requires the
///   three-file Transducer split. We therefore use OfflineRecognizer with the
///   nemoCtc config — same call path as Gate-1, different model binary.
///
/// Gate-2 goal: no hallucination tail on silence (the streaming model applies
///   per-frame confidence gating internally, unlike the offline INT8 export).
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
const String _kModelAsset  = 'assets/models/streaming/model_streaming_with_encoder.q8.onnx';
const String _kTokensAsset = 'assets/models/streaming/tokens.txt';
const String _kVadAsset    = 'assets/models/tarteel/silero_vad.onnx';

// ---------------------------------------------------------------------------
// Tuning constants (GATE TEST / UNVERIFIED — measure on-device at Gate 2)
// ---------------------------------------------------------------------------
const int    _kSampleRate        = 16000;
const int    _kNumThreads        = 2;    // UNVERIFIED — tune vs RTF on device

// Silero VAD
const double _kVadThreshold      = 0.5;  // GATE TEST
const double _kVadMinSilence     = 0.35; // GATE TEST (Gate-1 value)
const double _kVadMinSpeech      = 0.25;
const double _kVadMaxSpeech      = 20.0; // allow full ayah without cutting

// Trailing silence appended after each VAD segment (~0.4 s) so the model can
// close open words before the decoder is finalised. Literal int constant.
const int    _kTrailingSilence   = 6400; // = 16000 * 0.4 samples of zeros

// Minimum decodeable segment length (0.2 s). Shorter = skip.
const int    _kMinDecodeSamples  = 3200; // = 16000 * 0.2

// Watchdog: force-flush VAD if no segment arrives for this many seconds.
const double _kWatchdogSeconds   = 12.0;

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
      final model  = await _copyAsset(_kModelAsset,  'streaming_model.onnx');
      final tokens = await _copyAsset(_kTokensAsset, 'streaming_tokens.txt');
      final vad    = await _copyAsset(_kVadAsset,    'streaming_silero_vad.onnx');

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
            case 'partial':
              if (_running && !_paused) {
                final text = (msg['text'] as String).trim();
                if (text.isNotEmpty) _onResult?.call(AsrResult(text, 0.85));
              }
            case 'result':
              final text     = (msg['text']     as String).trim();
              final audioSec = msg['audioSec']  as double;
              final inferMs  = msg['inferMs']   as int;
              final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;
              dlog('[ASR] result: "${text.isEmpty ? "(empty)" : text}" '
                  'audio=${audioSec.toStringAsFixed(2)}s '
                  'infer=${inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
              if ((_running && !_paused) || _finalizing) {
                _finalizing = false;
                _onResult?.call(AsrResult(text, text.isEmpty ? 0.0 : 0.85));
              }
            case 'watchdog':
              dlog('[ASR] watchdog — no VAD segment for ${msg['secs']}s; flushing.');
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
          'NeMo-CTC streaming, threads=$_kNumThreads');
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

/// Worker isolate: owns OfflineRecognizer factory + Silero VAD.
///
/// Pipeline:
///   mic chunk (PCM16LE) → toFloat → VAD
///     → speech segment + trailing silence
///     → fresh OfflineRecognizer (Variant B) → CTC decode
///     → emit partial + result → free recognizer
///
/// Message protocol (main → worker):
///   Uint8List   — PCM16LE mic chunk
///   'reset'     — flush VAD, discard pending audio (pause/resume)
///   'flush'     — force VAD flush (stuck recovery, stream stays live)
///   'finalize'  — flush VAD, decode last segment, emit final result
///   'dispose'   — release native resources
///
/// Message protocol (worker → main):
///   SendPort                                  — handshake
///   {type:'ready'}
///   {type:'init_failed', error:String}
///   {type:'partial', text:String}
///   {type:'result', text, audioSec, inferMs}
///   {type:'watchdog', secs:String}
void _workerMain(_WorkerInit init) {
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  late sherpa.VoiceActivityDetector vad;
  // Keep recognizer config ready for Variant B (fresh instance per segment).
  late sherpa.OfflineRecognizerConfig recConfig;

  try {
    sherpa.initBindings();

    recConfig = sherpa.OfflineRecognizerConfig(
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
    );

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

  // PCM16LE bytes → Float32 [-1, 1].
  Float32List toFloat(Uint8List bytes) {
    final n  = bytes.length ~/ 2;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  final trailingSilence = Float32List(_kTrailingSilence); // zeros
  final sw = Stopwatch();
  var samplesSinceSegment = 0;
  final watchdogSamples   = (_kWatchdogSeconds * _kSampleRate).round();

  // Decode one speech segment with Variant B (fresh recognizer per call).
  void decodeSegment(Float32List seg) {
    if (seg.length < _kMinDecodeSamples) return;

    // Concatenate segment + trailing silence so the model closes open tokens.
    final full = Float32List(seg.length + trailingSilence.length);
    full.setAll(0, seg);
    full.setAll(seg.length, trailingSilence);

    sw.reset(); sw.start();
    sherpa.OfflineRecognizer? rec;
    try {
      rec = sherpa.OfflineRecognizer(recConfig);
      final stream = rec.createStream();
      stream.acceptWaveform(samples: full, sampleRate: _kSampleRate);
      rec.decode(stream);
      final text = rec.getResult(stream).text.trim();
      stream.free();
      sw.stop();

      final audioSec = seg.length / _kSampleRate.toDouble();
      final inferMs  = sw.elapsedMilliseconds;

      if (text.isNotEmpty) {
        init.toMain.send({'type': 'partial', 'text': text});
      }
      init.toMain.send({
        'type':     'result',
        'text':     text,
        'audioSec': audioSec,
        'inferMs':  inferMs,
      });
    } catch (e) {
      sw.stop();
      dlog('[ASR-worker] decodeSegment error: $e');
    } finally {
      rec?.free();
    }
  }

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0;
      decodeSegment(seg.samples);
    }
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      final f = toFloat(msg);
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
