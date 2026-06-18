import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

import '../debug.dart';

/// Placeholder Firebase ID token used until SWAP POINT 2 (Firebase) is wired.
/// Now superseded by the real `idTokenProvider`, kept as a harmless fallback.
const String kPlaceholderIdToken = '';

/// Real ASR client (spec Phase 2), rebuilt around **continuous PCM streaming**.
///
/// Why not record-a-file-per-chunk: stopping and restarting the recorder for
/// every chunk (a) drops audio during each upload (mic is off between
/// stop/start), (b) cuts words at fixed window boundaries, and (c) thrashes
/// Android's MediaCodec/MPEG4Writer (the "0 chunks written" / repeated
/// start→stop logcat noise, plus occasional empty files).
///
/// Instead we open ONE continuous 16 kHz mono PCM stream and keep it running
/// for the whole session. A rolling buffer holds the last [windowDuration] of
/// audio; every [emitInterval] we snapshot that window, wrap it as WAV, and
/// upload. Because consecutive windows OVERLAP, no word is ever cut at a
/// boundary — and the matching engine's context-replay absorption de-dupes the
/// repeated leading words for free. Near-silent windows are skipped (cheap RMS
/// gate), so we don't spam Groq while the reciter pauses; the controller's
/// silence timer still handles forgets. The recorder never stops mid-session,
/// so manual reveals (Reveal Next/Full Ayah) need no restart — capture simply
/// keeps flowing.
class GroqAsrService implements AsrService {
  /// Base Worker URL (no trailing slash needed).
  final String workerUrl;

  /// Recitation mode string sent as the `mode` field (`easy|normal|strict`).
  final String mode;

  /// How much trailing audio each uploaded window covers.
  final Duration windowDuration;

  /// How often a window is emitted. `windowDuration - emitInterval` is the
  /// overlap between consecutive windows.
  final Duration emitInterval;

  /// RMS (int16) below which a window is treated as silence and not uploaded.
  final double silenceRmsThreshold;

  /// Supplies the Firebase ID token for the `Authorization: Bearer` header.
  final Future<String?> Function()? idTokenProvider;

  final Dio _dio;
  final AudioRecorder _recorder = AudioRecorder();

  static const int _sampleRate = 16000;
  static const int _channels = 1;
  static const int _bytesPerSample = 2; // pcm16
  static const int _bytesPerSecond = _sampleRate * _channels * _bytesPerSample;

  bool _running = false;
  bool _paused = false;
  bool _inFlight = false;
  void Function(AsrResult)? _onResult;
  StreamSubscription<Uint8List>? _sub;
  Timer? _emitTimer;

  /// Rolling PCM buffer, trimmed to the last [windowDuration].
  final List<int> _buffer = [];
  int get _maxBufferBytes =>
      (windowDuration.inMilliseconds * _bytesPerSecond) ~/ 1000;
  int get _minEmitBytes => _bytesPerSecond ~/ 2; // ~0.5s minimum

  GroqAsrService({
    required this.workerUrl,
    this.mode = 'normal',
    this.windowDuration = const Duration(milliseconds: 3000),
    this.emitInterval = const Duration(milliseconds: 2000),
    this.silenceRmsThreshold = 350.0,
    this.idTokenProvider,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              validateStatus: (s) => s != null && s < 600,
            ));

  @override
  Future<void> start(void Function(AsrResult) onResult) async {
    _onResult = onResult;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      dlog('mic permission denied');
      onResult(const AsrResult('', 0));
      return;
    }

    try {
      final stream = await _recorder.startStream(
        const RecordConfig(
          encoder: AudioEncoder.pcm16bits,
          sampleRate: _sampleRate,
          numChannels: _channels,
        ),
      );
      _running = true;
      dlog('mic start — pcm16 ${_sampleRate}Hz mono, '
          'window=${windowDuration.inMilliseconds}ms '
          'emit=${emitInterval.inMilliseconds}ms '
          'overlap=${windowDuration.inMilliseconds - emitInterval.inMilliseconds}ms');

      _sub = stream.listen(
        _onPcm,
        onError: (Object e) => dlog('stream error: $e'),
        cancelOnError: false,
      );
      _emitTimer = Timer.periodic(emitInterval, (_) => _emitWindow());
    } catch (e) {
      dlog('mic start failed: $e');
      _running = false;
      onResult(const AsrResult('', 0));
    }
  }

  void _onPcm(Uint8List chunk) {
    _buffer.addAll(chunk);
    if (_buffer.length > _maxBufferBytes) {
      _buffer.removeRange(0, _buffer.length - _maxBufferBytes);
    }
  }

  Future<void> _emitWindow() async {
    if (!_running || _paused || _inFlight) return;
    if (_buffer.length < _minEmitBytes) {
      dlog('window too short (${_buffer.length}B) — waiting');
      return;
    }

    final pcm = Uint8List.fromList(_buffer);
    final durSec = pcm.length / _bytesPerSecond;
    final rms = _rms(pcm);

    if (rms < silenceRmsThreshold) {
      dlog('window ${pcm.length}B ~${durSec.toStringAsFixed(2)}s '
          'rms=${rms.toStringAsFixed(0)} < $silenceRmsThreshold — silent, skipped');
      return;
    }

    dlog('window ${pcm.length}B ~${durSec.toStringAsFixed(2)}s '
        'rms=${rms.toStringAsFixed(0)} — sending');

    _inFlight = true;
    try {
      final result = await _transcribe(_pcmToWav(pcm));
      if (_running) _onResult?.call(result);
    } catch (e) {
      dlog('chunk failed: $e');
      if (_running) _onResult?.call(const AsrResult('', 0));
    } finally {
      _inFlight = false;
    }
  }

  Future<AsrResult> _transcribe(Uint8List wav) async {
    final token = (await idTokenProvider?.call()) ?? kPlaceholderIdToken;
    final form = FormData.fromMap({
      'mode': mode,
      'file': MultipartFile.fromBytes(wav, filename: 'audio.wav'),
    });

    // Hard timeout so a dead/hanging connection can't stall the session — on
    // timeout it's treated like any other ASR failure (empty result).
    final resp = await _dio
        .post<dynamic>(
          '$workerUrl/asr/transcribe',
          data: form,
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        )
        .timeout(const Duration(seconds: 15));

    final data = resp.data;
    if (resp.statusCode == 200 && data is Map) {
      final text = (data['text'] ?? '').toString();
      final confRaw = data['confidence'];
      final conf = confRaw is num ? confRaw.toDouble() : 0.0;
      dlog('resp 200 text="$text" conf=${conf.toStringAsFixed(2)} '
          'noSpeech=${_avgNoSpeech(data).toStringAsFixed(2)}');
      return AsrResult(text, conf);
    }
    dlog('resp ${resp.statusCode} → failure (asr_failed / 401 / other)');
    return const AsrResult('', 0);
  }

  /// Mean `no_speech_prob` across returned segments (diagnostics only).
  double _avgNoSpeech(Map<dynamic, dynamic> data) {
    final segs = data['segments'];
    if (segs is! List || segs.isEmpty) return 0;
    var sum = 0.0;
    var n = 0;
    for (final s in segs) {
      if (s is Map && s['no_speech_prob'] is num) {
        sum += (s['no_speech_prob'] as num).toDouble();
        n++;
      }
    }
    return n == 0 ? 0 : sum / n;
  }

  double _rms(Uint8List pcm) {
    final n = pcm.length ~/ 2;
    if (n == 0) return 0;
    final bd = ByteData.view(pcm.buffer, pcm.offsetInBytes, n * 2);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final s = bd.getInt16(i * 2, Endian.little);
      sum += s * s;
    }
    return math.sqrt(sum / n);
  }

  Uint8List _pcmToWav(Uint8List pcm) {
    const headerSize = 44;
    final out = Uint8List(headerSize + pcm.length);
    final bd = ByteData.view(out.buffer);
    out.setRange(0, 4, ascii.encode('RIFF'));
    bd.setUint32(4, 36 + pcm.length, Endian.little);
    out.setRange(8, 12, ascii.encode('WAVE'));
    out.setRange(12, 16, ascii.encode('fmt '));
    bd.setUint32(16, 16, Endian.little); // PCM fmt chunk size
    bd.setUint16(20, 1, Endian.little); // audio format = PCM
    bd.setUint16(22, _channels, Endian.little);
    bd.setUint32(24, _sampleRate, Endian.little);
    bd.setUint32(28, _bytesPerSecond, Endian.little);
    bd.setUint16(32, _channels * _bytesPerSample, Endian.little); // block align
    bd.setUint16(34, 8 * _bytesPerSample, Endian.little); // bits per sample
    out.setRange(36, 40, ascii.encode('data'));
    bd.setUint32(40, pcm.length, Endian.little);
    out.setRange(headerSize, out.length, pcm);
    return out;
  }

  @override
  Future<void> pause() async {
    if (!_running || _paused) return;
    _paused = true;
    _emitTimer?.cancel();
    _emitTimer = null;
    _buffer.clear(); // drop buffered audio so resume starts clean
    try {
      if (await _recorder.isRecording()) await _recorder.pause();
    } catch (_) {}
    dlog('mic paused');
  }

  @override
  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    try {
      await _recorder.resume();
    } catch (_) {}
    _emitTimer = Timer.periodic(emitInterval, (_) => _emitWindow());
    dlog('mic resumed');
  }

  @override
  Future<void> stop() async {
    _running = false;
    _paused = false;
    _emitTimer?.cancel();
    _emitTimer = null;
    await _sub?.cancel();
    _sub = null;
    _buffer.clear();
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
    dlog('mic stop');
  }
}
