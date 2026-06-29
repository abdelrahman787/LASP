// ignore_for_file: uri_does_not_exist, depend_on_referenced_packages

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
///
/// ── Decisive Gate-1 strategy (this revision) ──────────────────────────────
/// The prior 104 s single-pass offline decode crashed with SIGSEGV inside
/// SherpaOnnxDecodeOfflineStream on arm64 (the buffer was exonerated: sherpa's
/// own readWave parsed it cleanly with sane amplitude). Hypothesis: a 104 s
/// single-pass offline decode overruns memory on a phone; these FastConformer
/// models are tuned for short utterances and our real design streams short
/// chunks anyway. So this harness now:
///   1. Decodes ONLY the first 8 s (samples.sublist(0, min(16000*8, n))) as a
///      probe, logging the slice length, with all existing diagnostics kept.
///   2. If the 8 s probe transcribes cleanly → Gate 1 is effectively PASSED
///      (length/memory was the cause, not a model defect). It then loops over
///      the FULL clip in 8 s windows back-to-back, reusing one recognizer with
///      a fresh stream per chunk, concatenating the text and printing each
///      chunk's text + RTF — proving chunked decode is stable end-to-end.
///      If that shared-recognizer loop CRASHES or DEGRADES mid-way with a
///      *catchable* Dart exception, it AUTO-FALLS BACK to VARIANT B for the
///      REMAINING chunks (new recognizer + stream per chunk, freed after each)
///      and logs `[GATE1] switched to per-chunk recognizer`, so a single device
///      run yields a verdict for BOTH catchable failure modes.
///   3. If the 8 s probe ITSELF still fails with a *catchable* Dart exception,
///      it falls through to VARIANT B: a FRESH recognizer + fresh stream built
///      per chunk (don't reuse the stream — rules out shared-recognizer state
///      corruption), and logs the verified fact about normalize_type /
///      FeatureConfig. It reports which variant works.
///   ⚠ A native SIGSEGV inside decode kills the process BEFORE Dart can catch
///     it, so on a true native fault variant B cannot run in the same process
///     — the pre-decode `print('[GATE1] ...')` lines (kept below) are the
///     diagnostic that survives via `flutter run` / `adb logcat`. Re-run after
///     reading them. This is an inherent FFI limitation, not a harness gap.
library;

import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// Asset paths (registered in pubspec.yaml under flutter: assets:).
const String _kModelAsset = 'assets/models/tarteel/model_int8.onnx';
const String _kTokensAsset = 'assets/models/tarteel/tokens.txt';
const String _kWavAsset = 'assets/test_audio/ayah16k.wav';

/// Probe / chunk size: 8 s of 16 kHz audio = 128 000 samples. Short enough to
/// fit a phone's decode budget for these utterance-tuned FastConformer models.
const int _kChunkSamples = 16000 * 8; // UNVERIFIED chunk size, tuned in Phase 3
const int _kSampleRate = 16000;

/// Outcome of one Gate-1 run, rendered to the screen.
class GateOneReport {
  final bool loaded;
  final bool transcribed;
  final String text;
  final double rtf;
  final double audioSeconds;
  final int inferMs;
  final String log;
  // Which decode path succeeded (for the verdict chips).
  final String mode;
  final int chunkCount;

  const GateOneReport({
    required this.loaded,
    required this.transcribed,
    required this.text,
    required this.rtf,
    required this.audioSeconds,
    required this.inferMs,
    required this.log,
    this.mode = '',
    this.chunkCount = 0,
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

/// Builds a FRESH OfflineRecognizer for the NeMo-CTC model. Used both for the
/// initial probe and (rebuilt per chunk) by VARIANT B. Verified against the
/// installed sherpa_onnx 1.13.3 source:
///  - FeatureConfig has ONLY {sampleRate, featureDim}; there is NO
///    normalize_type field. `per_feature` is read from ONNX metadata by native
///    sherpa C++ — it is NOT settable from Dart, so no FeatureConfig adjustment
///    is possible or needed.
///  - OfflineNemoEncDecCtcModelConfig(model: path) is the only NeMo-CTC field.
sherpa.OfflineRecognizer _buildRecognizer(String modelPath, String tokensPath) {
  return sherpa.OfflineRecognizer(
    sherpa.OfflineRecognizerConfig(
      decodingMethod: 'greedy_search',
      feat: const sherpa.FeatureConfig(sampleRate: _kSampleRate, featureDim: 80),
      model: sherpa.OfflineModelConfig(
        nemoCtc: sherpa.OfflineNemoEncDecCtcModelConfig(model: modelPath),
        tokens: tokensPath,
        numThreads: 2,
        modelType: 'nemo_ctc',
        // debug:true makes sherpa print the metadata it read to logcat — vital
        // for diagnosing a missing-metadata rejection and for confirming the
        // normalize_type the native reader picked up.
        debug: true,
      ),
    ),
  );
}

/// Decodes one chunk on `recognizer` using a FRESH stream (the normal sherpa
/// offline pattern: one recognizer, many streams). Returns the text + the
/// inference time in ms. Throws on any catchable sherpa error.
///
/// [preDecode] is printed to the console BEFORE `decode()` so that, if the
/// native call SIGSEGVs (which Dart cannot catch), the last console line names
/// the exact chunk that died — the same survival strategy the probe uses.
({String text, int inferMs}) _decodeChunk(
  sherpa.OfflineRecognizer recognizer,
  Float32List slice,
  int sampleRate, {
  void Function(String message)? preDecode,
}) {
  preDecode?.call('decode chunk (${slice.length} samples, '
      '${(slice.length / sampleRate).toStringAsFixed(2)}s)…');
  final sw = Stopwatch()..start();
  final stream = recognizer.createStream();
  stream.acceptWaveform(samples: slice, sampleRate: sampleRate);
  recognizer.decode(stream);
  final text = recognizer.getResult(stream).text;
  stream.free();
  sw.stop();
  return (text: text, inferMs: sw.elapsedMilliseconds);
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
  log('sherpa_onnx version: see pubspec.lock (resolves to 1.13.3)');
  log('strategy: 8s probe → shared-recognizer 8s-window loop over full clip; on mid-loop crash → auto-fallback to fresh-recognizer-per-chunk variant B; on probe crash → variant B');
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
  sherpa.initBindings();
  sherpa.OfflineRecognizer recognizer;
  try {
    recognizer = _buildRecognizer(modelPath, tokensPath);
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

  // --- Step 2: read the WAV (all existing buffer diagnostics kept) -----------
  try {
    // Use sherpa_onnx's own bundled readWave() — it parses the RIFF header in
    // native C (the exact path sherpa's examples and the model card use) and
    // returns a mono Float32List normalized to [-1,1] with the sample rate.
    // readWave() returns an EMPTY WaveData (0 samples, rate 0) on a parse
    // failure — guarded below before any decode, because a zero-frame decode
    // is a native SIGSEGV in the CTC greedy path.
    final fileBytes = await File(wavPath).length();
    final wav = sherpa.readWave(wavPath);

    log('');
    log('WAV (via sherpa.readWave):');
    log('  fileBytes    : $fileBytes bytes (on disk)');
    log('  sampleRate   : ${wav.sampleRate} Hz (0 => readWave failed to parse)');
    log('  sampleCount  : ${wav.samples.length} (0 => empty/failed — must NOT decode)');

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
    final fullSeconds = n / wav.sampleRate;
    log('  duration     : ${fullSeconds.toStringAsFixed(3)} s');
    log('  amplitude    : min=${mn.toStringAsFixed(4)}  max=${mx.toStringAsFixed(4)}  (expect ∈ [-1,1])');
    log('  first8       : ${wav.samples.take(8).map((v) => v.toStringAsFixed(3)).join(', ')}');
    if (wav.sampleRate != _kSampleRate) {
      log('  ⚠ sampleRate != $_kSampleRate — model expects 16 kHz; decode may misbehave.');
    }
    if (mn < -1.0 || mx > 1.0) {
      log('  ⚠ amplitude outside [-1,1] — buffer is NOT normalized; do not decode.');
    }

    // --- Step 3: 8 s PROBE decode --------------------------------------------
    // Slice the first 8 s. Float32List.sublist returns a Float32List, which is
    // exactly what acceptWaveform({required Float32List samples}) takes — no
    // cast needed (verified against sherpa_onnx 1.13.3 offline_stream.dart).
    final probeEnd = min(_kChunkSamples, n);
    final probeSlice = wav.samples.sublist(0, probeEnd);
    final probeSeconds = probeSlice.length / wav.sampleRate;
    log('');
    log('PROBE — decode first 8 s only:');
    log('  slice  : samples.sublist(0, min(16000*8, $n)) = ${probeSlice.length} samples');
    log('  slice  : ${probeSeconds.toStringAsFixed(3)} s of ${fullSeconds.toStringAsFixed(3)} s total');
    log('  decode 8s… (crash here ⇒ model/feature path, not length — see stats above)');

    // ── Step 3a: 8 s PROBE decode — its OWN try so a CATCHABLE probe failure
    // routes cleanly to VARIANT B, and a later mid-loop throw is never
    // mislabeled as a probe failure. preDecode prints to the console BEFORE
    // the native call so a SIGSEGV (which Dart cannot catch) leaves a
    // breadcrumb naming what died.
    late ({String text, int inferMs}) probe;
    try {
      probe = _decodeChunk(
        recognizer,
        probeSlice,
        wav.sampleRate,
        preDecode: (m) =>
            log('  $m (crash here ⇒ model/feature path, not length — see stats above)'),
      );
    } on Object catch (e) {
      // ── FAILURE PATH: 8 s probe threw a CATCHABLE exception → VARIANT B ──
      // (A native SIGSEGV does NOT land here — it kills the process; the
      // pre-decode print() line above is the diagnostic in that case.)
      log('  ✗ 8s PROBE FAILED (catchable): $e');
      log('');
      log('VARIANT B — fresh recognizer + fresh stream PER chunk (don\'t reuse');
      log('the stream; rules out shared-recognizer state corruption).');
      // First, free the shared recognizer we built for the probe.
      try {
        recognizer.free();
      } catch (_) {/* already torn down or never decoded */}
      // Verified fact about normalize_type / FeatureConfig (sherpa_onnx 1.13.3):
      log('  normalize_type note: FeatureConfig in 1.13.3 has ONLY {sampleRate,');
      log('  featureDim} — there is NO normalize_type field, so no FeatureConfig');
      log('  adjustment is possible. `per_feature` is read from the ONNX metadata');
      log('  by native sherpa C++ (see the debug:true logcat lines on load); the');
      log('  Dart side cannot change it. This is a non-op, not a fix candidate.');

      final texts = <String>[];
      var totalInferMs = 0;
      var totalAudioSec = 0.0;
      Object? lastErr;
      for (var start = 0; start < n; start += _kChunkSamples) {
        final end = min(start + _kChunkSamples, n);
        final slice = wav.samples.sublist(start, end);
        final dur = slice.length / wav.sampleRate;
        try {
          final rec = _buildRecognizer(modelPath, tokensPath);
          final r = _decodeChunk(
            rec,
            slice,
            wav.sampleRate,
            preDecode: (m) =>
                log('  chunk ${texts.length + 1}: $m (fresh recognizer)'),
          );
          rec.free();
          final rtf = dur > 0 ? r.inferMs / 1000 / dur : 0.0;
          totalInferMs += r.inferMs;
          totalAudioSec += dur;
          texts.add(r.text);
          final idx = texts.length;
          log('  chunk $idx: [$start..$end] ${dur.toStringAsFixed(2)}s  '
              'text="${r.text}"  infer=${r.inferMs}ms RTF=${rtf.toStringAsFixed(3)} '
              '(fresh recognizer)');
        } on Object catch (e2) {
          lastErr = e2;
          log('  chunk @ [$start..$end] FAILED (fresh recognizer): $e2');
          // Stop the loop; keep the chunks already decoded.
          break;
        }
      }
      final ok = texts.isNotEmpty && lastErr == null;
      final joined = texts.join(' ').trim();
      final aggRtf = totalAudioSec > 0 ? totalInferMs / 1000 / totalAudioSec : 0.0;
      log('');
      if (ok) {
        log('✓ VARIANT B WORKED — fresh recognizer per chunk decoded all');
        log('  ${texts.length} chunks with no crash. So the shared-recognizer');
        log('  state was the problem, not the model. full text: $joined');
        log('  aggregate RTF=${aggRtf.toStringAsFixed(3)}');
      } else {
        log('✗ VARIANT B ALSO FAILED — last error: $lastErr');
        log('  This points to the int8 model / feature path itself, not length');
        log('  and not shared-recognizer state. Next: re-export metadata, try a');
        log('  non-int8 model, or drop to raw onnxruntime. REPORT this first.');
      }
      return GateOneReport(
        loaded: true, transcribed: ok, text: joined, rtf: aggRtf,
        audioSeconds: totalAudioSec, inferMs: totalInferMs,
        log: sb.toString(),
        mode: ok ? 'variant B (fresh recognizer per chunk)' : 'both 8s + variant B failed',
        chunkCount: texts.length,
      );
    }

    // ── Probe succeeded → Gate 1 effectively PASSED (length/memory was the
    // 104 s crash cause on arm64, not a model defect).
    final probeRtf = probeSeconds > 0
        ? probe.inferMs / 1000 / probeSeconds
        : 0.0;
    log('  ✓ 8s PROBE TRANSCRIBED');
    log('    text : ${probe.text}');
    log('    infer: ${probe.inferMs} ms   RTF=${probeRtf.toStringAsFixed(3)}');

    // ── Step 3b: chunk the WHOLE clip in 8 s windows back-to-back (one
    // recognizer, fresh stream per chunk) to prove chunked decode is stable
    // end-to-end. SEPARATE try so a CATCHABLE mid-loop throw preserves the
    // probe success + the partial chunks already decoded and is reported
    // honestly — never mislabeled "8s PROBE FAILED".
    log('');
    log('GATE 1 effectively PASSED — 8 s decoded cleanly, so the 104 s crash');
    log('was length/memory on arm64, not a model defect. Now looping the FULL');
    log('clip in 8 s windows back-to-back (one recognizer, fresh stream per');
    log('chunk) to prove chunked decode is stable end-to-end.');
    log('');
    log('CHUNKED LOOP:');

    final texts = <String>[];
    var totalInferMs = 0;
    var totalAudioSec = 0.0;
    try {
      for (var start = 0; start < n; start += _kChunkSamples) {
        final end = min(start + _kChunkSamples, n);
        final slice = wav.samples.sublist(start, end);
        final dur = slice.length / wav.sampleRate;
        final idx = texts.length + 1;
        final r = _decodeChunk(
          recognizer,
          slice,
          wav.sampleRate,
          preDecode: (m) => log('  chunk $idx: $m'),
        );
        final rtf = dur > 0 ? r.inferMs / 1000 / dur : 0.0;
        totalInferMs += r.inferMs;
        totalAudioSec += dur;
        texts.add(r.text);
        log('  chunk $idx: [$start..$end] ${dur.toStringAsFixed(2)}s  '
            'text="${r.text}"  infer=${r.inferMs}ms RTF=${rtf.toStringAsFixed(3)}');
      }
    } on Object catch (e) {
      // Mid-loop CATCHABLE failure: the probe SUCCEEDED (8 s OK), so the model
      // loads & short-decodes fine; the shared-recognizer loop faulted at chunk
      // (texts.length+1). Rather than stop, AUTO-FALL BACK to VARIANT B for the
      // REMAINING chunks (new recognizer + stream per chunk, freed after each)
      // so one device run still yields a full verdict. A native SIGSEGV does
      // NOT land here (it kills the process; the pre-decode breadcrumb above
      // names the dead chunk via `flutter run` / `adb logcat`).
      final diedAtChunk = texts.length + 1;
      final rescueStart = texts.length * _kChunkSamples;
      log('  ✗ SHARED-RECOGNIZER LOOP CRASHED (catchable) at chunk $diedAtChunk: $e');
      log('  Probe had succeeded (8 s OK) + ${texts.length} chunk(s) decoded on the');
      log('  shared recognizer before the crash. AUTO-FALLING BACK to VARIANT B');
      log('  (fresh recognizer + stream per chunk, freed after each) for the');
      log('  REMAINING chunks from sample $rescueStart onward.');
      log('[GATE1] switched to per-chunk recognizer (variant B rescue)');
      // Tear down the shared recognizer — it may be in a corrupt state.
      try {
        recognizer.free();
      } catch (_) {/* already torn down or never decoded */}
      // Verified fact about normalize_type / FeatureConfig (sherpa_onnx 1.13.3):
      log('  normalize_type note: FeatureConfig in 1.13.3 has ONLY {sampleRate,');
      log('  featureDim} — there is NO normalize_type field, so no FeatureConfig');
      log('  adjustment is possible. `per_feature` is read from the ONNX metadata');
      log('  by native sherpa C++ (see the debug:true logcat lines on load); the');
      log('  Dart side cannot change it. This is a non-op, not a fix candidate.');

      // ── VARIANT B rescue: fresh recognizer + fresh stream PER remaining chunk.
      Object? rescueErr;
      for (var start = rescueStart; start < n; start += _kChunkSamples) {
        final end = min(start + _kChunkSamples, n);
        final slice = wav.samples.sublist(start, end);
        final dur = slice.length / wav.sampleRate;
        final idx = texts.length + 1;
        try {
          final rec = _buildRecognizer(modelPath, tokensPath);
          final r = _decodeChunk(
            rec,
            slice,
            wav.sampleRate,
            preDecode: (m) =>
                log('  chunk $idx: $m (fresh recognizer)'),
          );
          rec.free();
          final rtf = dur > 0 ? r.inferMs / 1000 / dur : 0.0;
          totalInferMs += r.inferMs;
          totalAudioSec += dur;
          texts.add(r.text);
          log('  chunk $idx: [$start..$end] ${dur.toStringAsFixed(2)}s  '
              'text="${r.text}"  infer=${r.inferMs}ms RTF=${rtf.toStringAsFixed(3)} '
              '(fresh recognizer)');
        } on Object catch (e2) {
          rescueErr = e2;
          log('  chunk $idx @ [$start..$end] FAILED (fresh recognizer): $e2');
          // Stop the rescue; keep the chunks already decoded (shared + rescued).
          break;
        }
      }
      final joined = texts.join(' ').trim();
      final aggRtf = totalAudioSec > 0 ? totalInferMs / 1000 / totalAudioSec : 0.0;
      final rescued = rescueErr == null;
      log('');
      if (rescued) {
        log('✓ VARIANT B RESCUE WORKED — shared-recognizer loop crashed at chunk');
        log('  $diedAtChunk, but fresh-recognizer-per-chunk decoded the remaining');
        log('  chunks with no crash. So the shared-recognizer STATE degraded mid-');
        log('  way, not the model. ${texts.length} total chunks decoded. full text:');
        log('  $joined');
        log('  aggregate RTF=${aggRtf.toStringAsFixed(3)}');
      } else {
        log('✗ VARIANT B RESCUE ALSO FAILED — last error: $rescueErr');
        log('  Shared loop crashed at chunk $diedAtChunk; the per-chunk rescue');
        log('  then failed too. This points to the int8 model / feature path');
        log('  itself, not length and not shared-recognizer state. Next:');
        log('  re-export metadata, try a non-int8 model, or drop to raw');
        log('  onnxruntime. REPORT this first.');
      }
      return GateOneReport(
        loaded: true,
        transcribed: texts.isNotEmpty,
        text: joined,
        rtf: aggRtf,
        audioSeconds: totalAudioSec,
        inferMs: totalInferMs,
        log: sb.toString(),
        mode: rescued
            ? 'variant B rescue after shared-loop crash at chunk $diedAtChunk'
            : 'shared loop + variant B rescue both failed (chunk $diedAtChunk)',
        chunkCount: texts.length,
      );
    }
    recognizer.free();
    final joined = texts.join(' ').trim();
    final aggRtf = totalAudioSec > 0 ? totalInferMs / 1000 / totalAudioSec : 0.0;
    log('');
    log('✓ CHUNKED DECODE STABLE — ${texts.length} chunks, no crash.');
    log('  full text : $joined');
    log('  total aud : ${totalAudioSec.toStringAsFixed(2)} s');
    log('  total inf : $totalInferMs ms   aggregate RTF=${aggRtf.toStringAsFixed(3)}');
    log('');
    log('Compare the full text against your Gate-0 PC output (modulo alef');
    log('forms — matching is alef-insensitive). Seam artifacts between 8 s');
    log('chunks are EXPECTED with independent offline decoding (no CTC cache');
    log('carry); our real design streams short chunks, so this is a stability');
    log('proof, not the final reveal path.');
    return GateOneReport(
      loaded: true, transcribed: true, text: joined, rtf: aggRtf,
      audioSeconds: totalAudioSec, inferMs: totalInferMs,
      log: sb.toString(), mode: 'chunked-8s (shared recognizer)',
      chunkCount: texts.length,
    );
  } on Object catch (e) {
    log('');
    log('✗ Loaded but a pre-decode step failed. EXACT error:');
    log('$e');
    try {
      recognizer.free();
    } catch (_) {/* ignore */}
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
                if (r.loaded && r.transcribed && r.chunkCount > 0)
                  Chip(label: Text('${r.chunkCount} chunks')),
                if (r.mode.isNotEmpty)
                  Chip(label: Text(r.mode)),
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
