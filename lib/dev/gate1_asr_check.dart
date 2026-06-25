/// GATE 1 — sherpa_onnx compatibility check for the Quran FastConformer-CTC model.
///
/// THROWAWAY dev harness (CLAUDE.md Phase 2, "Gate 1 first"). It does ONE thing:
/// try to load `model_int8.onnx` + `tokens.txt` as an OFFLINE NeMo-CTC model in
/// sherpa_onnx and transcribe the bundled Gate-0 wav — then show, verbatim,
/// whether it loaded and what it said, or the EXACT error sherpa threw.
///
/// Run it standalone (does not touch the real app):
///     flutter run -t lib/dev/gate1_main.dart
///
/// Required files (gitignored — copy your Gate-0-verified files in first):
///   assets/models/tarteel/model_int8.onnx
///   assets/models/tarteel/tokens.txt
///   assets/test_audio/ayah16k.wav      (16 kHz mono PCM16, the Gate-0 clip)
///
/// WHY this can fail: sherpa's offline NeMo-CTC reader REQUIRES the ONNX model
/// to carry `vocab_size` and `subsampling_factor` in its metadata (and reads
/// `normalize_type` if present). A plain onnxruntime export (which Saboorhsn's
/// is) usually lacks these, so sherpa throws at construction. If that happens,
/// this screen prints the exact message — do NOT work around it silently; report
/// it and we decide (inject metadata via tools/asr/add_sherpa_metadata.py, or
/// re-export, or fall back to raw onnxruntime) together.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Asset paths (registered in pubspec.yaml under flutter: assets:).
const String _kModelAsset = 'assets/models/tarteel/model_int8.onnx';
const String _kTokensAsset = 'assets/models/tarteel/tokens.txt';
const String _kWavAsset = 'assets/test_audio/ayah16k.wav';

/// Outcome of one Gate-1 run, rendered to the screen.
class GateOneReport {
  final bool loaded;
  final bool transcribed;
  final String text;
  final double rtf;
  final double audioSeconds;
  final int inferMs;
  final String log;

  const GateOneReport({
    required this.loaded,
    required this.transcribed,
    required this.text,
    required this.rtf,
    required this.audioSeconds,
    required this.inferMs,
    required this.log,
  });
}

/// Copies a bundled asset to a real file path (sherpa needs file paths, not
/// asset keys). Returns the on-disk path.
Future<String> _copyAssetToFile(String assetKey, Directory dir) async {
  final data = await rootBundle.load(assetKey);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  final name = assetKey.split('/').last;
  final f = File('${dir.path}/$name');
  await f.writeAsBytes(bytes, flush: true);
  return f.path;
}

/// Runs the Gate-1 check. Never throws — failures are captured in the report
/// `log` so the screen can show sherpa's exact error.
Future<GateOneReport> runGateOneCheck() async {
  final sb = StringBuffer();
  // Echo every line to stdout/logcat too: a native SIGSEGV inside
  // SherpaOnnxDecodeOfflineStream kills the process BEFORE the on-screen
  // report can render, so the pre-decode buffer stats only survive if they
  // were already printed to the console (visible via `flutter run` and
  // `adb logcat`). Without this, the crash erases the very diagnostics we
  // need to see.
  void log(String m) {
    sb.writeln(m);
    print('[GATE1] $m');
  }

  log('GATE 1 — sherpa_onnx offline NeMo-CTC compatibility');
  log('sherpa_onnx version: see pubspec.lock');
  log('');

  final tmp = await getTemporaryDirectory();
  String modelPath, tokensPath, wavPath;
  try {
    modelPath = await _copyAssetToFile(_kModelAsset, tmp);
    tokensPath = await _copyAssetToFile(_kTokensAsset, tmp);
    wavPath = await _copyAssetToFile(_kWavAsset, tmp);
    log('Copied assets → ${tmp.path}');
    log('  model : ${File(modelPath).lengthSync()} bytes');
    log('  tokens: ${File(tokensPath).lengthSync()} bytes');
    log('  wav   : ${File(wavPath).lengthSync()} bytes');
  } catch (e) {
    log('');
    log('✗ MISSING ASSET — copy the gitignored files in first:');
    log('  $_kModelAsset / $_kTokensAsset / $_kWavAsset');
    log('  error: $e');
    return GateOneReport(
      loaded: false, transcribed: false, text: '', rtf: 0,
      audioSeconds: 0, inferMs: 0, log: sb.toString(),
    );
  }

  // --- Step 1: construct the recognizer (THE compatibility gate) -------------
  sherpa.OfflineRecognizer recognizer;
  try {
    sherpa.initBindings();
    recognizer = sherpa.OfflineRecognizer(
      sherpa.OfflineRecognizerConfig(
        // NeMo CTC is greedy; the model card uses CTC greedy decode.
        decodingMethod: 'greedy_search',
        // FastConformer NeMo preprocessor: 80-dim log-mel @ 16 kHz. sherpa does
        // the feature extraction + CMVN in C++ (the reason we chose it).
        feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
        model: sherpa.OfflineModelConfig(
          nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: modelPath),
          tokens: tokensPath,
          numThreads: 2,
          modelType: 'nemo_ctc',
          // debug:true makes sherpa print the metadata it read to logcat — vital
          // for diagnosing a missing-metadata rejection.
          debug: true,
        ),
      ),
    );
    log('');
    log('✓ RECOGNIZER LOADED — model metadata accepted by sherpa.');
  } catch (e) {
    log('');
    log('✗ LOAD FAILED — sherpa rejected the model. EXACT error:');
    log('────────────────────────────────────────────');
    log('$e');
    log('────────────────────────────────────────────');
    log('');
    log('If this mentions vocab_size / subsampling_factor / meta_data, the');
    log('generic ONNX export lacks sherpa\'s required metadata. Likely fix:');
    log('  python tools/asr/add_sherpa_metadata.py \\');
    log('    --in model_int8.onnx --out model_int8.sherpa.onnx');
    log('Then re-run Gate 1 with the patched model. REPORT the error first.');
    return GateOneReport(
      loaded: false, transcribed: false, text: '', rtf: 0,
      audioSeconds: 0, inferMs: 0, log: sb.toString(),
    );
  }

  // --- Step 2: transcribe the Gate-0 wav -------------------------------------
  try {
    // Use sherpa_onnx's own bundled readWave() — it parses the RIFF
    // header in native C (the exact path sherpa's examples and the model
    // card use) and returns a mono Float32List normalized to [-1,1] with
    // the sample rate. This removes the hand-rolled Dart WAV parser as a
    // source of buffer error: the ONLY thing that changed between the
    // working Gate-0 (Python/librosa) and the crashing Gate-1 (Dart) is
    // the audio-reading path, so we feed sherpa exactly what its own
    // reader produces. readWave() returns an EMPTY WaveData (0 samples,
    // rate 0) on a parse failure — guarded below before any decode,
    // because a zero-frame decode is a native SIGSEGV in the CTC greedy
    // path.
    final fileBytes = await File(wavPath).length();
    final wav = sherpa.readWave(wavPath);

    // Buffer facts — emitted BEFORE acceptWaveform so they survive even a
    // native fault in the next call. readWave exposes samples + sampleRate
    // only (no raw header fields), so we report the on-disk file size and
    // the parsed buffer it handed back. If readWave failed, sampleCount is
    // 0 and sampleRate is 0 — caught by the guard below.
    log('');
    log('WAV (via sherpa.readWave):');
    log('  fileBytes    : $fileBytes bytes (on disk)');
    log('  sampleRate   : ${wav.sampleRate} Hz (0 => readWave failed to parse)');
    log('  sampleCount  : ${wav.samples.length} (0 => empty/failed — must NOT decode)');

    // Buffer sanity — computed and printed BEFORE decode. A SIGSEGV inside
    // SherpaOnnxDecodeOfflineStream still leaves these on the console/logcat
    // (log() also print()s), so we can tell whether the crash is the buffer
    // (count == 0, min/max outside [-1,1], sampleRate != 16000) or the model.
    final n = wav.samples.length;
    if (n <= 0 || wav.sampleRate == 0) {
      log('');
      log('✗ readWave returned an empty buffer (sampleCount=$n, sampleRate=${wav.sampleRate}).');
      log('  The WAV could not be parsed by sherpa\'s own reader — do NOT decode');
      log('  (a zero-frame decode is a native SIGSEGV in the CTC greedy path).');
      log('  Check assets/test_audio/ayah16k.wav is a real 16 kHz mono PCM16 WAV.');
      recognizer.free();
      return GateOneReport(
        loaded: true, transcribed: false, text: '', rtf: 0,
        audioSeconds: 0, inferMs: 0, log: sb.toString(),
      );
    }
    var mn = double.infinity;
    var mx = -double.infinity;
    for (var i = 0; i < n; i++) {
      final v = wav.samples[i];
      if (v < mn) mn = v;
      if (v > mx) mx = v;
    }
    final audioSeconds = n / wav.sampleRate;
    log('  duration     : ${audioSeconds.toStringAsFixed(3)} s');
    log('  amplitude    : min=${mn.toStringAsFixed(4)}  max=${mx.toStringAsFixed(4)}  (expect ∈ [-1,1])');
    log('  first8       : ${wav.samples.take(8).map((v) => v.toStringAsFixed(3)).join(', ')}');
    if (wav.sampleRate != 16000) {
      log('  ⚠ sampleRate != 16000 — model expects 16 kHz; decode may misbehave.');
    }
    if (mn < -1.0 || mx > 1.0) {
      log('  ⚠ amplitude outside [-1,1] — buffer is NOT normalized; do not decode.');
    }

    final sw = Stopwatch()..start();
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: wav.samples, sampleRate: wav.sampleRate);
    log('  acceptWaveform: ok ($n Float32 samples handed to native)');
    log('  decode… (crash here ⇒ model/feature path, not buffer — see stats above)');
    recognizer.decode(stream);
    final text = recognizer.getResult(stream).text;
    stream.free();
    sw.stop();

    final rtf = audioSeconds > 0 ? sw.elapsedMilliseconds / 1000 / audioSeconds : 0.0;
    log('');
    log('✓ TRANSCRIBED');
    log('  text : $text');
    log('  infer: ${sw.elapsedMilliseconds} ms   RTF=${rtf.toStringAsFixed(3)}');
    log('');
    log('Compare this text against your Gate-0 PC output. If they match (modulo');
    log('alef forms — matching is alef-insensitive), Gate 1 PASSES.');

    recognizer.free();
    return GateOneReport(
      loaded: true, transcribed: true, text: text, rtf: rtf,
      audioSeconds: audioSeconds, inferMs: sw.elapsedMilliseconds,
      log: sb.toString(),
    );
  } catch (e) {
    log('');
    log('✗ Loaded but DECODE failed. EXACT error:');
    log('$e');
    recognizer.free();
    return GateOneReport(
      loaded: true, transcribed: false, text: '', rtf: 0,
      audioSeconds: 0, inferMs: 0, log: sb.toString(),
    );
  }
}

/// Minimal screen: a button to run the check and a scrollable verbatim report.
class GateOneScreen extends StatefulWidget {
  const GateOneScreen({super.key});

  @override
  State<GateOneScreen> createState() => _GateOneScreenState();
}

class _GateOneScreenState extends State<GateOneScreen> {
  GateOneReport? _report;
  bool _running = false;

  Future<void> _run() async {
    setState(() => _running = true);
    final r = await runGateOneCheck();
    if (!mounted) return;
    setState(() {
      _report = r;
      _running = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = _report;
    return Scaffold(
      appBar: AppBar(title: const Text('Gate 1 — sherpa_onnx NeMo CTC')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            FilledButton(
              onPressed: _running ? null : _run,
              child: Text(_running ? 'Running…' : 'Run Gate 1 check'),
            ),
            const SizedBox(height: 12),
            if (r != null)
              Wrap(spacing: 8, children: [
                Chip(label: Text(r.loaded ? 'LOADED ✓' : 'LOAD FAILED ✗')),
                if (r.loaded)
                  Chip(label: Text(r.transcribed
                      ? 'RTF ${r.rtf.toStringAsFixed(3)}'
                      : 'DECODE FAILED ✗')),
              ]),
            const SizedBox(height: 12),
            Expanded(
              child: SingleChildScrollView(
                child: SelectableText(
                  r?.log ?? 'Press “Run Gate 1 check”.\n\n'
                      'Needs assets/models/tarteel/{model_int8.onnx,tokens.txt}\n'
                      'and assets/test_audio/ayah16k.wav (gitignored).',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
