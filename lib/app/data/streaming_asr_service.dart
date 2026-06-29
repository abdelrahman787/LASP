/// StreamingAsrService — onnxruntime direct inference with rolling cache.
///
/// Model: model_streaming_with_encoder.q8.onnx (Q8 streaming NeMo-CTC)
///   Inputs per chunk:
///     audio_signal           float32 [1, 80, T]        mel features (CMVN applied)
///     length                 int64   [1]               number of mel frames T
///     cache_last_channel     float32 [1, 17, 70, 512]  zero-init, carried forward
///     cache_last_time        float32 [1, 17, 512,  8]  zero-init, carried forward
///     cache_last_channel_len int64   [1]               zero-init, carried forward
///   Outputs:
///     [0] logprobs                 float32 [1, T_out, 1025]
///     [1] encoder_output           (ignored)
///     [2] encoded_lengths          (ignored)
///     [3] cache_last_channel_next  float32 [1, 17, 70, 512]
///     [4] cache_last_time_next     float32 [1, 17, 512,  8]
///     [5] cache_last_channel_next_len int64 [1]
///
/// VAD: pure-Dart energy-based (RMS per 200ms chunk, simple state machine).
///   Silero VAD via sherpa_onnx was removed to avoid libonnxruntime.so conflict:
///   sherpa bundles its own ORT .so; packagingOptions pickFirst picked the wrong
///   copy, making libsherpa-onnx-c-api.so unable to resolve OrtGetApiBase.
///
/// Why onnxruntime (not sherpa OfflineRecognizer):
///   model_int8.onnx + SherpaOnnxDecodeOfflineStream = SIGSEGV on Android 16
///   (deterministic SEGV_ACCERR at offset +68). Q8 streaming model + onnxruntime
///   direct bypasses sherpa's decode path entirely.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../debug.dart';
import 'cmvn_data.dart';
import 'ctc_decoder.dart';
import 'mel_features.dart';

// ---------------------------------------------------------------------------
// Asset paths
// ---------------------------------------------------------------------------
const String _kModelAsset  = 'assets/models/streaming/model_streaming_with_encoder.q8.onnx';
const String _kTokensAsset = 'assets/models/streaming/tokens.txt';

// ---------------------------------------------------------------------------
// Tuning
// ---------------------------------------------------------------------------
const int    _kSampleRate       = 16000;
const int    _kNumThreads       = 2;
const int    _kChunkSamples     = 3200;   // 200ms per inference step
const int    _kMinDecodeSamples = 3200;   // skip sub-200ms artifacts
const int    _kTrailingSilence  = 6400;   // 400ms appended to close open tokens

// Energy VAD — pure Dart, no native libs required.
const double _kEnergyThreshold   = 0.02;  // RMS in float32 [-1,1] range
const int    _kVoiceOnChunks     = 2;     // consecutive loud chunks to start
const int    _kSilenceChunks     = 6;     // consecutive quiet chunks to end
const int    _kLookbackChunks    = 2;     // pre-onset chunks to include in seg
const int    _kMaxSpeechSamples  = 80000; // 5s → force segment even mid-speech

// Cache tensor shapes (verified from model inspection).
const List<int> _kCacheChannelShape = [1, 17, 70, 512];
const List<int> _kCacheTimeShape    = [1, 17, 512, 8];
const List<int> _kCacheLenShape     = [1];

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
      final model  = await _copyAsset(_kModelAsset,  'ort_streaming_model.onnx');
      final tokens = await _copyAsset(_kTokensAsset, 'ort_streaming_tokens.txt');

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
              dlog('[ASR] worker init_failed: ${msg['error']}');
              if (!ready.isCompleted) ready.complete(false);
            case 'partial':
              if (_running && !_paused) {
                final text = (msg['text'] as String).trim();
                if (text.isNotEmpty) _onResult?.call(AsrResult(text, 0.85));
              }
            case 'result':
              final text     = (msg['text']    as String).trim();
              final audioSec = msg['audioSec'] as double;
              final inferMs  = msg['inferMs']  as int;
              final rtf = audioSec > 0 ? inferMs / 1000.0 / audioSec : 0.0;
              dlog('[ASR] "${text.isEmpty ? "(empty)" : text}" '
                  'audio=${audioSec.toStringAsFixed(2)}s '
                  'infer=${inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
              if ((_running && !_paused) || _finalizing) {
                _finalizing = false;
                _onResult?.call(AsrResult(text, text.isEmpty ? 0.0 : 0.85));
              }
          }
        }
      });

      await Isolate.spawn(
        _workerMain,
        _WorkerInit(
          toMain:     _fromWorker!.sendPort,
          modelPath:  model,
          tokensPath: tokens,
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
      dlog('[ASR] streaming mic started — PCM16 $_kSampleRate Hz mono, '
          'Q8 streaming NeMo-CTC via onnxruntime + rolling cache + energy VAD, '
          'chunk=$_kChunkSamples threads=$_kNumThreads');
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
  final int      numThreads;
  const _WorkerInit({
    required this.toMain,
    required this.modelPath,
    required this.tokensPath,
    required this.numThreads,
  });
}

Float32List _toFloat(Uint8List bytes) {
  final n  = bytes.length ~/ 2;
  final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

double _rms(Float32List samples) {
  var sum = 0.0;
  for (final s in samples) { sum += s * s; }
  return math.sqrt(sum / samples.length);
}

enum _VadState { silence, speech }

void _workerMain(_WorkerInit init) {
  final port = ReceivePort();
  init.toMain.send(port.sendPort);

  late OrtSession       session;
  late CtcGreedyDecoder ctcDecoder;
  final mel = MelExtractor();

  try {
    OrtEnv.instance.init();
    final opts = OrtSessionOptions()
      ..setIntraOpNumThreads(init.numThreads)
      ..setInterOpNumThreads(1);
    session = OrtSession.fromFile(File(init.modelPath), opts);

    ctcDecoder = CtcGreedyDecoder.fromTokensTxt(
      File(init.tokensPath).readAsStringSync(),
    );

    init.toMain.send({'type': 'ready'});
  } catch (e) {
    init.toMain.send({'type': 'init_failed', 'error': '$e'});
    return;
  }

  // ---- rolling cache (reset per segment) ------------------------------------
  Float32List cacheChannel    = Float32List(_prod(_kCacheChannelShape));
  Float32List cacheTime       = Float32List(_prod(_kCacheTimeShape));
  Int64List   cacheChannelLen = Int64List(1);

  void resetCache() {
    cacheChannel    = Float32List(_prod(_kCacheChannelShape));
    cacheTime       = Float32List(_prod(_kCacheTimeShape));
    cacheChannelLen = Int64List(1);
  }

  // ---- energy VAD state -----------------------------------------------------
  var _vadState    = _VadState.silence;
  var _voiceCount  = 0;
  var _silenceCount = 0;
  final _lookback  = <Float32List>[];   // pre-onset ringbuffer
  final _speechBuf = <Float32List>[];
  var _speechSamples = 0;

  // ---- CTC accumulator ------------------------------------------------------
  final logprobBuf = <double>[];
  var   logprobT   = 0;
  var   inferMs    = 0;
  final sw         = Stopwatch();

  void inferChunk(Float32List chunk) {
    final frames = mel.extract(chunk);
    if (frames.isEmpty) return;
    mel.applyCmvn(frames, cmvnMean, cmvnStd);
    final T    = frames.length;
    final feat = mel.toModelInput(frames);

    final tAudio    = OrtValueTensor.createTensorWithDataList(feat,                         [1, 80, T]);
    final tLen      = OrtValueTensor.createTensorWithDataList(Int64List.fromList([T]),        [1]);
    final tCacheCh  = OrtValueTensor.createTensorWithDataList(cacheChannel,    _kCacheChannelShape);
    final tCacheTm  = OrtValueTensor.createTensorWithDataList(cacheTime,       _kCacheTimeShape);
    final tCacheLen = OrtValueTensor.createTensorWithDataList(cacheChannelLen, _kCacheLenShape);

    final inputs = <String, OrtValueTensor>{
      'audio_signal':           tAudio,
      'length':                 tLen,
      'cache_last_channel':     tCacheCh,
      'cache_last_time':        tCacheTm,
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
      tAudio.release();   tLen.release();
      tCacheCh.release(); tCacheTm.release(); tCacheLen.release();
      sw.stop();
      inferMs += sw.elapsedMilliseconds;
    }

    if (outputs.isEmpty) return;

    // Extract logprobs [1, T_out, 1025].
    try {
      final lpRaw = outputs[0]?.value;
      if (lpRaw is List) {
        final batch = lpRaw[0] as List;
        for (final frame in batch) {
          final f = frame as List;
          logprobBuf.addAll(f.cast<double>());
          logprobT++;
        }
      }
    } catch (_) {}

    // Update rolling cache.
    try {
      void readF32Cache(int idx, Float32List dest) {
        final raw = outputs![idx]?.value;
        if (raw is! List) return;
        var i = 0;
        void visit(dynamic v) {
          if (v is List) {
            for (final x in v) { visit(x); }
          } else if (i < dest.length) {
            dest[i++] = (v as num).toDouble();
          }
        }
        visit(raw);
      }
      readF32Cache(3, cacheChannel);
      readF32Cache(4, cacheTime);
      final rawLen = outputs[5]?.value;
      if (rawLen is List && rawLen.isNotEmpty) {
        cacheChannelLen[0] = (rawLen[0] as num).toInt();
      }
    } catch (_) {}

    for (final o in outputs) { try { o?.release(); } catch (_) {} }
  }

  // ---- decode one VAD segment -----------------------------------------------
  void decodeSegment(Float32List samples) {
    if (samples.length < _kMinDecodeSamples) return;

    logprobBuf.clear(); logprobT = 0; inferMs = 0;
    resetCache();

    // Append trailing silence so the model closes open tokens.
    final full = Float32List(samples.length + _kTrailingSilence);
    full.setAll(0, samples);

    var offset = 0;
    while (offset < full.length) {
      final end   = (offset + _kChunkSamples).clamp(0, full.length);
      final chunk = full.sublist(offset, end);
      inferChunk(chunk);
      offset = end;

      if (logprobT > 0) {
        final lp      = Float32List.fromList(logprobBuf);
        final partial = ctcDecoder.decode(lp, logprobT);
        if (partial.isNotEmpty) {
          init.toMain.send({'type': 'partial', 'text': partial});
        }
      }
    }

    if (logprobT > 0) {
      final lp       = Float32List.fromList(logprobBuf);
      final text     = ctcDecoder.decode(lp, logprobT);
      final audioSec = samples.length / _kSampleRate.toDouble();
      init.toMain.send({
        'type':     'result',
        'text':     text,
        'audioSec': audioSec,
        'inferMs':  inferMs,
      });
    }
  }

  // ---- flush current speech buffer as one segment ---------------------------
  void flushSpeech() {
    if (_speechBuf.isEmpty) return;
    final total = _speechSamples;
    final merged = Float32List(total);
    var off = 0;
    for (final c in _speechBuf) { merged.setAll(off, c); off += c.length; }
    _speechBuf.clear();
    _speechSamples = 0;
    _vadState = _VadState.silence;
    _voiceCount = 0;
    _silenceCount = 0;
    decodeSegment(merged);
  }

  // ---- energy VAD: accept one float32 chunk ---------------------------------
  void acceptChunk(Float32List chunk) {
    final energy = _rms(chunk);

    if (_vadState == _VadState.silence) {
      // Maintain a short lookback so the speech onset isn't clipped.
      _lookback.add(chunk);
      if (_lookback.length > _kLookbackChunks) { _lookback.removeAt(0); }

      if (energy > _kEnergyThreshold) {
        _voiceCount++;
        if (_voiceCount >= _kVoiceOnChunks) {
          _vadState = _VadState.speech;
          for (final c in _lookback) {
            _speechBuf.add(c);
            _speechSamples += c.length;
          }
          _lookback.clear();
          _silenceCount = 0;
        }
      } else {
        _voiceCount = 0;
      }
    } else {
      // Speech state: accumulate and watch for silence end.
      _speechBuf.add(chunk);
      _speechSamples += chunk.length;

      if (energy < _kEnergyThreshold) {
        _silenceCount++;
        if (_silenceCount >= _kSilenceChunks) { flushSpeech(); }
      } else {
        _silenceCount = 0;
      }

      if (_speechSamples >= _kMaxSpeechSamples) { flushSpeech(); }
    }
  }

  void resetVad() {
    _vadState = _VadState.silence;
    _voiceCount = 0;
    _silenceCount = 0;
    _lookback.clear();
    _speechBuf.clear();
    _speechSamples = 0;
    resetCache();
    logprobBuf.clear();
    logprobT = 0;
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      acceptChunk(_toFloat(msg));
    } else if (msg == 'reset') {
      resetVad();
    } else if (msg == 'flush') {
      flushSpeech();
    } else if (msg == 'finalize') {
      flushSpeech();
    } else if (msg == 'dispose') {
      try { session.release(); port.close(); } catch (_) {}
    }
  });
}

int _prod(List<int> shape) => shape.fold(1, (a, b) => a * b);
