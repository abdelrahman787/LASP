/// StreamingAsrService — true chunk-by-chunk streaming CTC via onnxruntime.
///
/// Model: model_streaming_with_encoder.q8.onnx (Muno459/fastconformer-quran)
///   Required inputs per chunk:
///     audio_signal        float32  [1, 80, T_in]  — mel features (CMVN-normalized)
///     length              int64    [1]             — number of mel frames
///     cache_last_channel  float32  [1, 17, 70, 512]
///     cache_last_time     float32  [1, 17, 512, 8]
///     cache_last_channel_len  int64  [1]
///   Outputs:
///     logprobs            float32  [1, T_out, 1025]  — CTC log-probs
///     encoder_output      float32  [1, 512, T_out]   (ignored)
///     encoded_lengths     int64    [1]                (ignored)
///     cache_last_channel_next  float32  [1, 17, 70, 512]
///     cache_last_time_next     float32  [1, 17, 512, 8]
///     cache_last_channel_next_len  int64  [1]
///
/// Pipeline (per VAD speech segment):
///   segment audio → split into 3200-sample (200ms) chunks
///     → per chunk: mel features + CMVN → onnxruntime (with cache) → logprobs
///   → accumulate logprobs → CTC greedy decode → emit result
///   → reset cache for next segment
///
/// Silero VAD (from sherpa-onnx) segments audio into speech regions.
/// onnxruntime handles inference; sherpa-onnx is used ONLY for VAD.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../debug.dart';
import 'cmvn_data.dart';
import 'ctc_decoder.dart';
import 'mel_features.dart';

// ---------------------------------------------------------------------------
// Asset paths
// ---------------------------------------------------------------------------
/// Original streaming model — has required cache inputs (used with onnxruntime).
const String _kModelAsset  = 'assets/models/streaming/model_streaming_with_encoder.q8.onnx';
const String _kTokensAsset = 'assets/models/streaming/tokens.txt';
const String _kVadAsset    = 'assets/models/tarteel/silero_vad.onnx';

// ---------------------------------------------------------------------------
// Tuning constants
// ---------------------------------------------------------------------------
const int    _kSampleRate       = 16000;
const int    _kNumThreads       = 2;

/// Chunk size fed to the model per inference step (200ms = 2560 samples =
/// 16 mel frames → 4 CTC output frames with subsampling_factor=4).
const int    _kChunkSamples     = 3200; // 200ms

/// Minimum decodeable segment (0.2 s). Shorter VAD artifacts are skipped.
const int    _kMinDecodeSamples = 3200;

/// Trailing silence appended after each VAD segment so the model closes
/// open tokens before final decode. ~0.4 s.
const int    _kTrailingSilence  = 6400;

// Silero VAD
const double _kVadThreshold     = 0.5;
const double _kVadMinSilence    = 0.35;
const double _kVadMinSpeech     = 0.25;
const double _kVadMaxSpeech     = 8.0;  // max segment length fed to model

const double _kWatchdogSeconds  = 12.0;

// Cache tensor shapes (verified from model inspection 2026-06-28).
const List<int> _kCacheChannelShape = [1, 17, 70, 512]; // float32
const List<int> _kCacheTimeShape    = [1, 17, 512, 8];  // float32
const List<int> _kCacheLenShape     = [1];               // int64

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
      final model  = await _copyAsset(_kModelAsset,  'streaming_ctc_model.onnx');
      final tokens = await _copyAsset(_kTokensAsset, 'streaming_ctc_tokens.txt');
      final vad    = await _copyAsset(_kVadAsset,    'streaming_ctc_vad.onnx');

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
          'NeMo-CTC streaming+cache via onnxruntime, threads=$_kNumThreads');
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

/// Worker isolate: owns OrtSession (onnxruntime) + Silero VAD (sherpa-onnx).
///
/// Pipeline per VAD speech segment:
///   segment → 200ms chunks → mel+CMVN → OrtSession (with rolling cache)
///   → accumulate logprobs → greedy CTC decode → emit result → reset cache
void _workerMain(_WorkerInit init) {
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  late OrtSession session;
  late sherpa.VoiceActivityDetector vad;
  late CtcGreedyDecoder ctcDecoder;
  final melExtractor = MelExtractor();

  // ---- initialise OrtSession ------------------------------------------------
  try {
    OrtEnv.instance.init();
    final opts = OrtSessionOptions()
      ..setIntraOpNumThreads(init.numThreads)
      ..setInterOpNumThreads(1);
    session = OrtSession.fromFile(File(init.modelPath), opts);

    // Load tokens.txt for CTC decoder.
    final tokensContent = File(init.tokensPath).readAsStringSync();
    ctcDecoder = CtcGreedyDecoder.fromTokensTxt(tokensContent);

    // Silero VAD (sherpa-onnx) for speech segmentation only.
    sherpa.initBindings();
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

  // ---- cache state (reset between utterances) --------------------------------
  Float32List cacheChannel    = Float32List(_prod(_kCacheChannelShape));
  Float32List cacheTime       = Float32List(_prod(_kCacheTimeShape));
  Int64List   cacheChannelLen = Int64List(1); // [0]

  void resetCache() {
    cacheChannel    = Float32List(_prod(_kCacheChannelShape));
    cacheTime       = Float32List(_prod(_kCacheTimeShape));
    cacheChannelLen = Int64List(1);
  }

  // ---- chunk inference -------------------------------------------------------
  final sw = Stopwatch();
  var totalInferMs = 0;

  // Accumulated logprobs for the current VAD segment [T_total * V].
  final logprobBuf  = <double>[];
  var   logprobT    = 0;

  void inferChunk(Float32List chunk) {
    if (chunk.isEmpty) return;
    // Mel features [T_frames, 80].
    final frames = melExtractor.extract(chunk);
    if (frames.isEmpty) return;
    melExtractor.applyCmvn(frames, cmvnMean, cmvnStd);
    final T    = frames.length;
    final feat = melExtractor.toModelInput(frames); // [1, 80, T] flat

    // Build ORT input tensors.
    final tAudio  = OrtValueTensor.createTensorWithDataList(feat,        [1, 80, T]);
    final tLen    = OrtValueTensor.createTensorWithDataList(Int64List.fromList([T]), [1]);
    final tCacheCh  = OrtValueTensor.createTensorWithDataList(cacheChannel, _kCacheChannelShape);
    final tCacheTm  = OrtValueTensor.createTensorWithDataList(cacheTime,    _kCacheTimeShape);
    final tCacheLen = OrtValueTensor.createTensorWithDataList(cacheChannelLen, _kCacheLenShape);

    final inputs = <String, OrtValueTensor>{
      'audio_signal':         tAudio,
      'length':               tLen,
      'cache_last_channel':   tCacheCh,
      'cache_last_time':      tCacheTm,
      'cache_last_channel_len': tCacheLen,
    };

    sw.reset(); sw.start();
    List<OrtValue?>? outputs;
    try {
      outputs = session.run(OrtRunOptions(), inputs);
    } catch (e) {
      dlog('[ASR-worker] ORT run error: $e');
      return;
    } finally {
      tAudio.release();
      tLen.release();
      tCacheCh.release();
      tCacheTm.release();
      tCacheLen.release();
      sw.stop();
      totalInferMs += sw.elapsedMilliseconds;
    }

    if (outputs.isEmpty) return;

    // Extract logprobs [1, T_out, 1025] → flatten to T_out*1025.
    try {
      final lpRaw = outputs[0]?.value;
      if (lpRaw is List) {
        final batch  = lpRaw[0] as List;   // [T_out][1025]
        for (final frame in batch) {
          final f = frame as List;
          logprobBuf.addAll(f.cast<double>());
          logprobT++;
        }
      }
    } catch (_) {}

    // Update rolling cache from outputs [3]=channel, [4]=time, [5]=len.
    try {
      void readCache(int idx, Float32List dest) {
        final raw = outputs![idx]?.value;
        if (raw is List) {
          var i = 0;
          void visit(dynamic v) {
            if (v is List) { for (final x in v) { visit(x); } }
            else if (i < dest.length) { dest[i++] = (v as num).toDouble(); }
          }
          visit(raw);
        }
      }
      readCache(3, cacheChannel);
      readCache(4, cacheTime);
      final rawLen = outputs[5]?.value;
      if (rawLen is List && rawLen.isNotEmpty) {
        cacheChannelLen[0] = (rawLen[0] as num).toInt();
      }
    } catch (_) {}

    for (final o in outputs) { try { o?.release(); } catch (_) {} }
  }

  // ---- decode full segment --------------------------------------------------
  void decodeSegment(Float32List seg) {
    if (seg.length < _kMinDecodeSamples) return;

    // Reset accumulators.
    logprobBuf.clear();
    logprobT = 0;
    resetCache();
    totalInferMs = 0;

    // Append trailing silence so the model closes open tokens.
    final full = Float32List(seg.length + _kTrailingSilence);
    full.setAll(0, seg);

    // Process in chunks of _kChunkSamples (200ms).
    var offset = 0;
    while (offset < full.length) {
      final end   = (offset + _kChunkSamples).clamp(0, full.length);
      final chunk = full.sublist(offset, end);
      inferChunk(chunk);
      offset = end;

      // Emit partial after each chunk so the UI updates during long ayat.
      if (logprobT > 0) {
        final lp = Float32List.fromList(logprobBuf);
        final partial = ctcDecoder.decode(lp, logprobT);
        if (partial.isNotEmpty) {
          init.toMain.send({'type': 'partial', 'text': partial});
        }
      }
    }

    // Final decode.
    if (logprobT > 0) {
      final lp    = Float32List.fromList(logprobBuf);
      final text  = ctcDecoder.decode(lp, logprobT);
      final audio = seg.length / _kSampleRate.toDouble();
      init.toMain.send({
        'type':     'result',
        'text':     text,
        'audioSec': audio,
        'inferMs':  totalInferMs,
      });
    }
  }

  // ---- VAD drain ------------------------------------------------------------
  var samplesSinceSegment = 0;
  final watchdogSamples   = (_kWatchdogSeconds * _kSampleRate).round();

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      samplesSinceSegment = 0;
      decodeSegment(seg.samples);
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
      resetCache();
      logprobBuf.clear();
      logprobT = 0;
      samplesSinceSegment = 0;
    } else if (msg == 'flush') {
      try { vad.flush(); } catch (_) {}
      drainVad();
    } else if (msg == 'finalize') {
      try { vad.flush(); } catch (_) {}
      drainVad();
    } else if (msg == 'dispose') {
      try {
        session.release();
        port.close();
      } catch (_) {}
    }
  });
}

int _prod(List<int> shape) => shape.fold(1, (a, b) => a * b);
