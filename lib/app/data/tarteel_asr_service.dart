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
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

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
              dlog('tarteel result "$text" (${msg['dur']}s)');
              if (_running && !_paused) {
                _onResult?.call(AsrResult(text, text.isEmpty ? 0 : 0.9));
              }
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
    _toWorker?.send('reset'); // fresh VAD state for this session
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
          if (_running && !_paused) _toWorker?.send(chunk);
        },
        onError: (Object e) => dlog('stream error: $e'),
        cancelOnError: false,
      );
      dlog('tarteel mic start — pcm16 ${_sampleRate}Hz mono, '
          'recognizerThreads=$_recognizerThreads (bg isolate)');
    } catch (e) {
      dlog('mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    _paused = true;
    try {
      if (await _recorder.isRecording()) await _recorder.pause();
    } catch (_) {}
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
  Future<void> stop() async {
    _running = false;
    _paused = false;
    await _sub?.cancel();
    _sub = null;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
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
        model: sherpa.OfflineModelConfig(
          whisper: sherpa.OfflineWhisperModelConfig(
            encoder: init.encoder,
            decoder: init.decoder,
            language: 'ar',
            task: 'transcribe',
          ),
          tokens: init.tokens,
          numThreads: init.numThreads, // multi-core decode
          modelType: 'whisper',
          debug: false,
        ),
      ),
    );
    vad = sherpa.VoiceActivityDetector(
      config: sherpa.VadModelConfig(
        sileroVad: sherpa.SileroVadModelConfig(
          model: init.vad,
          threshold: 0.5,
          // Require a longer pause to END a segment so intra-phrase breaths
          // don't cut words mid-utterance ("وَلَا يَ").
          minSilenceDuration: 0.45,
          minSpeechDuration: 0.25,
          // Safety cap only — long ayah phrases shouldn't be force-cut at 5s.
          maxSpeechDuration: 12.0,
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

  void drainVad() {
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      try {
        final s = recognizer.createStream();
        s.acceptWaveform(samples: seg.samples, sampleRate: sampleRate);
        recognizer.decode(s);
        final text = recognizer.getResult(s).text;
        s.free();
        init.toMain.send({
          'type': 'result',
          'text': text,
          'dur': (seg.samples.length / sampleRate).toStringAsFixed(2),
        });
      } catch (e) {
        init.toMain.send({'type': 'result', 'text': '', 'dur': '0'});
      }
    }
  }

  port.listen((msg) {
    if (msg is Uint8List) {
      vad.acceptWaveform(toFloat(msg));
      drainVad();
    } else if (msg == 'reset') {
      try {
        vad.flush();
        while (!vad.isEmpty()) {
          vad.pop();
        }
      } catch (_) {}
    } else if (msg == 'dispose') {
      port.close();
    }
  });
}
