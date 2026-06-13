import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';

/// Placeholder Firebase ID token used until SWAP POINT 2 (Firebase) is wired.
///
/// The Cloudflare Worker verifies this token before calling Groq, so requests
/// will be rejected (401) until a real token is supplied — that's expected and
/// intentional. Everything else (mic capture, chunking, multipart upload,
/// parsing, failure handling) is complete and exercised; only this header value
/// is stubbed.
const String kPlaceholderIdToken = '';

/// Real ASR client (spec Phase 2): captures mic audio in short chunks, uploads
/// each to the Cloudflare Worker's `POST /asr/transcribe` (Groq proxy), and
/// delivers parsed [AsrResult]s.
///
/// Failure semantics match the spec + the engine contract: a failed chunk
/// (empty audio, network error, or the Worker's `502 {error:"asr_failed"}`)
/// yields `AsrResult('', 0)` — `isFailure == true` — which the
/// `RecitationController` counts toward its "audio unclear" hint without
/// passing anything to the matching engine.
class GroqAsrService implements AsrService {
  /// Base Worker URL, e.g. `https://…workers.dev` (no trailing slash needed).
  final String workerUrl;

  /// Recitation mode string sent as the `mode` field (`easy|normal|strict`).
  final String mode;

  /// Duration of each captured chunk (spec default 2.5–4 s).
  final Duration chunkWindow;

  /// Supplies the Firebase ID token for the `Authorization: Bearer` header.
  /// SWAP POINT 2 wires this to `FirebaseAuth.instance.currentUser?.getIdToken()`.
  /// Until then it defaults to [kPlaceholderIdToken].
  final Future<String?> Function()? idTokenProvider;

  /// Privacy: raw audio is deleted after upload unless the user explicitly
  /// consents (spec Phase 2). Stubbed flag, default off.
  final bool storeRawAudio;

  final Dio _dio;
  final AudioRecorder _recorder = AudioRecorder();

  bool _running = false;
  void Function(AsrResult)? _onResult;

  GroqAsrService({
    required this.workerUrl,
    this.mode = 'normal',
    this.chunkWindow = const Duration(milliseconds: 3000),
    this.idTokenProvider,
    this.storeRawAudio = false,
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 30),
              // Don't throw on 4xx/5xx — we inspect the status ourselves so the
              // Worker's 401 (bad token) and 502 (asr_failed) become silent
              // failures rather than exceptions.
              validateStatus: (s) => s != null && s < 600,
            ));

  @override
  Future<void> start(void Function(AsrResult) onResult) async {
    _onResult = onResult;

    final status = await Permission.microphone.request();
    if (!status.isGranted) {
      onResult(const AsrResult('', 0)); // treated as a failure, no crash
      return;
    }
    _running = true;
    unawaited(_loop());
  }

  @override
  Future<void> stop() async {
    _running = false;
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  Future<void> _loop() async {
    while (_running) {
      String? outPath;
      try {
        final path =
            '${Directory.systemTemp.path}/tasmee3_${DateTime.now().microsecondsSinceEpoch}.m4a';
        await _recorder.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: path,
        );
        await Future.delayed(chunkWindow);
        if (!_running) {
          await _safeStop();
          break;
        }
        outPath = await _recorder.stop();
        if (outPath == null) continue;

        final file = File(outPath);
        final bytes = await file.readAsBytes();
        if (!storeRawAudio) {
          try {
            file.deleteSync();
          } catch (_) {}
        }

        if (bytes.isEmpty) {
          _emit(const AsrResult('', 0));
          continue;
        }
        _emit(await _transcribe(bytes));
      } catch (_) {
        // Network/recorder error → a failure result; keep listening.
        _emit(const AsrResult('', 0));
      }
    }
  }

  Future<AsrResult> _transcribe(List<int> bytes) async {
    final token = (await idTokenProvider?.call()) ?? kPlaceholderIdToken;
    final form = FormData.fromMap({
      'mode': mode,
      'file': MultipartFile.fromBytes(bytes, filename: 'chunk.m4a'),
    });

    final resp = await _dio.post<dynamic>(
      '$workerUrl/asr/transcribe',
      data: form,
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );

    final data = resp.data;
    if (resp.statusCode == 200 && data is Map) {
      final text = (data['text'] ?? '').toString();
      final confRaw = data['confidence'];
      final conf = confRaw is num ? confRaw.toDouble() : 0.0;
      return AsrResult(text, conf);
    }
    // 401 (placeholder token until Firebase), 502 asr_failed, anything else →
    // a silent failure the controller counts.
    return const AsrResult('', 0);
  }

  Future<void> _safeStop() async {
    try {
      if (await _recorder.isRecording()) await _recorder.stop();
    } catch (_) {}
  }

  void _emit(AsrResult r) {
    if (_running) _onResult?.call(r);
  }
}
