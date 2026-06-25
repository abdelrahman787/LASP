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

/// Minimal WAV (PCM16 mono) reader → Float32 samples in [-1,1] + sample rate.
/// We parse manually rather than rely on a sherpa wav helper so the harness is
/// robust across sherpa_onnx versions. Assumes a canonical 44-byte header.
({Float32List samples, int sampleRate}) _readWavPcm16(Uint8List bytes) {
  final bd = ByteData.view(bytes.buffer, bytes.offsetInBytes, bytes.length);
  // Validate RIFF/WAVE.
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') {
    throw const FormatException('not a RIFF/WAVE file');
  }
  // Walk chunks to find fmt and data (don't assume fixed offsets).
  var pos = 12;
  var sampleRate = 16000;
  var bitsPerSample = 16;
  int? dataOffset, dataLen;
  while (pos + 8 <= bytes.length) {
    final id = tag(pos);
    final sz = bd.getUint32(pos + 4, Endian.little);
    final body = pos + 8;
    if (id == 'fmt ') {
      sampleRate = bd.getUint32(body + 4, Endian.little);
      bitsPerSample = bd.getUint16(body + 14, Endian.little);
    } else if (id == 'data') {
      dataOffset = body;
      dataLen = sz;
    }
    pos = body + sz + (sz.isOdd ? 1 : 0);
  }
  if (dataOffset == null || dataLen == null) {
    throw const FormatException('no data chunk');
  }
  if (bitsPerSample != 16) {
    throw FormatException('expected PCM16, got $bitsPerSample-bit');
  }
  final n = dataLen ~/ 2;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(dataOffset + i * 2, Endian.little) / 32768.0;
  }
  // The Gate-0 clip is mono PCM16; interleaved-stereo handling is out of scope.
  return (samples: out, sampleRate: sampleRate == 0 ? 16000 : sampleRate);
}

/// Runs the Gate-1 check. Never throws — failures are captured in the report
/// `log` so the screen can show sherpa's exact error.
Future<GateOneReport> runGateOneCheck() async {
  final sb = StringBuffer();
  void log(String m) => sb.writeln(m);

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
    final wavBytes = await File(wavPath).readAsBytes();
    final wav = _readWavPcm16(wavBytes);
    final audioSeconds = wav.samples.length / wav.sampleRate;
    log('audio: ${audioSeconds.toStringAsFixed(2)}s @ ${wav.sampleRate} Hz');

    final sw = Stopwatch()..start();
    final stream = recognizer.createStream();
    stream.acceptWaveform(samples: wav.samples, sampleRate: wav.sampleRate);
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
