import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../debug.dart';

/// On-device ASR using the Tarteel Whisper model (whisper-base-ar-quran) via
/// Sherpa-ONNX, gated by Silero VAD v5 (also Sherpa-ONNX). Implements the same
/// [AsrService] the [RecitationController] already consumes — only this layer
/// changes; the matching engine is untouched.
///
/// Pipeline: continuous PCM16 16 kHz mono mic stream → Float32 → Silero VAD
/// (segments speech, replaces the old RMS gate) → Whisper recognizes each
/// speech segment → AsrResult(text, confidence). All offline; no network.
class TarteelOnDeviceAsrService implements AsrService {
  static const String _dir = 'assets/models/tarteel';
  // Sherpa-ONNX Whisper export format (see tools/asr/export_onnx.py).
  static const String _encoderAsset = '$_dir/encoder.onnx';
  static const String _decoderAsset = '$_dir/decoder.onnx';
  static const String _tokensAsset = '$_dir/tokens.txt';
  static const String _vadAsset = '$_dir/silero_vad.onnx';

  static const int _sampleRate = 16000;
  static bool _bindingsInited = false;

  final AudioRecorder _recorder = AudioRecorder();
  bool _running = false;
  bool _paused = false;
  bool _initFailed = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;

  sherpa.OfflineRecognizer? _recognizer;
  sherpa.VoiceActivityDetector? _vad;

  /// Lazy, cached init: copy the bundled model files out of assets, load the
  /// Whisper recognizer + Silero VAD. Returns false (no crash) if the assets
  /// aren't present or loading fails — the session then just produces silent
  /// failures (and the user can flip kUseOnDeviceAsr off to use the Worker).
  Future<bool> _ensureInit() async {
    if (_recognizer != null && _vad != null) return true;
    if (_initFailed) return false;
    try {
      if (!_bindingsInited) {
        sherpa.initBindings();
        _bindingsInited = true;
      }
      final enc = await _copyAsset(_encoderAsset, 'tarteel-encoder.onnx');
      final dec = await _copyAsset(_decoderAsset, 'tarteel-decoder.onnx');
      final tok = await _copyAsset(_tokensAsset, 'tarteel-tokens.txt');
      final vadPath = await _copyAsset(_vadAsset, 'silero_vad.onnx');

      _recognizer = sherpa.OfflineRecognizer(
        sherpa.OfflineRecognizerConfig(
          model: sherpa.OfflineModelConfig(
            whisper: sherpa.OfflineWhisperModelConfig(
              encoder: enc,
              decoder: dec,
              language: 'ar',
              task: 'transcribe',
            ),
            tokens: tok,
            numThreads: 1,
            modelType: 'whisper',
            debug: false,
          ),
        ),
      );
      _vad = sherpa.VoiceActivityDetector(
        config: sherpa.VadModelConfig(
          sileroVad: sherpa.SileroVadModelConfig(
            model: vadPath,
            threshold: 0.5,
            minSilenceDuration: 0.25,
            minSpeechDuration: 0.25,
          ),
          sampleRate: _sampleRate,
          numThreads: 1,
        ),
        bufferSizeInSeconds: 30,
      );
      dlog('tarteel ASR initialized (on-device Whisper + Silero VAD)');
      return true;
    } catch (e) {
      dlog('tarteel init failed: $e');
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
    if (!await _ensureInit()) {
      onResult(const AsrResult('', 0));
      return;
    }
    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: 1,
        ),
      );
      _running = true;
      _sub = stream.listen(
        _onPcm,
        onError: (Object e) => dlog('stream error: $e'),
        cancelOnError: false,
      );
      dlog('tarteel mic start — pcm16 ${_sampleRate}Hz mono');
    } catch (e) {
      dlog('mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  void _onPcm(Uint8List chunk) {
    if (!_running || _paused) return;
    final vad = _vad;
    if (vad == null) return;
    // VAD gates audio: only completed speech segments are recognized; silence
    // never reaches the model (replaces the RMS threshold).
    vad.acceptWaveform(_pcm16ToFloat(chunk));
    while (!vad.isEmpty()) {
      final seg = vad.front();
      vad.pop();
      _recognizeSegment(seg.samples);
    }
  }

  void _recognizeSegment(Float32List samples) {
    final rec = _recognizer;
    if (rec == null || !_running) return;
    try {
      final s = rec.createStream();
      s.acceptWaveform(samples: samples, sampleRate: _sampleRate);
      rec.decode(s);
      final text = rec.getResult(s).text.trim();
      s.free();
      dlog('tarteel result "$text" '
          '(${(samples.length / _sampleRate).toStringAsFixed(2)}s)');
      if (_running) _onResult?.call(AsrResult(text, text.isEmpty ? 0 : 0.9));
    } catch (e) {
      dlog('tarteel recognize failed: $e');
      if (_running) _onResult?.call(const AsrResult('', 0));
    }
  }

  Float32List _pcm16ToFloat(Uint8List bytes) {
    final n = bytes.length ~/ 2;
    final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, n * 2);
    final out = Float32List(n);
    for (var i = 0; i < n; i++) {
      out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
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
    // Clear VAD state for the next session (recognizer + vad stay cached).
    try {
      _vad?.flush();
      final vad = _vad;
      if (vad != null) {
        while (!vad.isEmpty()) {
          vad.pop();
        }
      }
    } catch (_) {}
    dlog('tarteel mic stop');
  }
}
