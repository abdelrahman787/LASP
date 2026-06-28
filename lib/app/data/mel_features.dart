/// 80-dim log-mel spectrogram extractor for NeMo FastConformer streaming CTC.
///
/// Parameters match AudioToMelSpectrogramPreprocessor defaults:
///   sample_rate=16000, window_size=25ms (400 samples), hop=10ms (160 samples),
///   n_fft=512, n_mels=80, freq_min=0 Hz, freq_max=8000 Hz,
///   log=True, window=Hann, normalize_type=per_feature (CMVN applied here).
library;

import 'dart:math' as math;
import 'dart:typed_data';

class MelExtractor {
  static const int sampleRate = 16000;
  static const int nFft      = 512;
  static const int nMels     = 80;
  static const int winLen    = 400; // 25 ms
  static const int hopLen    = 160; // 10 ms
  static const double fMin   = 0.0;
  static const double fMax   = 8000.0;

  // NeMo log guard: 2^-24 ≈ 5.96e-8.
  static const double _logGuard = 5.960464477539063e-8;

  late final Float64List _window;              // Hann [winLen]
  late final List<Float64List> _melFb;         // [nMels][nFft/2+1]
  late final Float64List _fftReal;             // scratch buffer
  late final Float64List _fftImag;
  late final Float64List _cosTable;            // FFT twiddle
  late final Float64List _sinTable;

  MelExtractor() {
    _window   = _buildHann(winLen);
    _melFb    = _buildMelFb(nMels, nFft, sampleRate, fMin, fMax);
    _fftReal  = Float64List(nFft);
    _fftImag  = Float64List(nFft);
    _cosTable = Float64List(nFft ~/ 2);
    _sinTable = Float64List(nFft ~/ 2);
    for (var k = 0; k < nFft ~/ 2; k++) {
      final angle = -2.0 * math.pi * k / nFft;
      _cosTable[k] = math.cos(angle);
      _sinTable[k] = math.sin(angle);
    }
  }

  /// Extract [numFrames, 80] mel features (CMVN NOT applied here).
  /// Caller applies CMVN via [applyCmvn].
  List<Float32List> extract(Float32List samples) {
    final nFrames = math.max(0, (samples.length - winLen) ~/ hopLen + 1);
    final frames  = List<Float32List>.generate(nFrames, (_) => Float32List(nMels));
    const halfFft = nFft ~/ 2 + 1;
    final power   = Float64List(halfFft);

    for (var t = 0; t < nFrames; t++) {
      final start = t * hopLen;
      // Apply Hann window + zero-pad to nFft.
      for (var n = 0; n < nFft; n++) {
        final s = (n < winLen && start + n < samples.length)
            ? samples[start + n] * _window[n]
            : 0.0;
        _fftReal[n] = s;
        _fftImag[n] = 0.0;
      }
      // In-place FFT.
      _fft(_fftReal, _fftImag);
      // Power spectrum (one-sided).
      for (var k = 0; k < halfFft; k++) {
        final re = _fftReal[k], im = _fftImag[k];
        power[k] = re * re + im * im;
      }
      // Mel filterbank → log.
      final frame = frames[t];
      for (var m = 0; m < nMels; m++) {
        var s = 0.0;
        final fb = _melFb[m];
        for (var k = 0; k < halfFft; k++) {
          s += fb[k] * power[k];
        }
        frame[m] = math.log(s + _logGuard).toDouble().toFloat32();
      }
    }
    return frames;
  }

  /// Apply per-feature CMVN in-place: (x − mean[m]) / std[m].
  void applyCmvn(
      List<Float32List> frames, List<double> mean, List<double> std) {
    for (final frame in frames) {
      for (var m = 0; m < nMels; m++) {
        frame[m] = ((frame[m] - mean[m]) / std[m]).toFloat32();
      }
    }
  }

  /// Pack [numFrames, 80] frames into [1, 80, numFrames] flat Float32List
  /// (NeMo expects [B, feature, time] layout).
  Float32List toModelInput(List<Float32List> frames) {
    final T   = frames.length;
    final out = Float32List(nMels * T);
    for (var t = 0; t < T; t++) {
      final frame = frames[t];
      for (var m = 0; m < nMels; m++) {
        out[m * T + t] = frame[m];
      }
    }
    return out;
  }

  // ---- Cooley-Tukey radix-2 FFT (in-place, DIT) ----------------------------

  void _fft(Float64List re, Float64List im) {
    final n = re.length;
    // Bit-reversal permutation.
    var j = 0;
    for (var i = 1; i < n; i++) {
      var bit = n >> 1;
      while (j >= bit) {
        j -= bit;
        bit >>= 1;
      }
      j += bit;
      if (i < j) {
        var tmp = re[i]; re[i] = re[j]; re[j] = tmp;
        tmp = im[i]; im[i] = im[j]; im[j] = tmp;
      }
    }
    // Butterfly stages.
    for (var len = 2; len <= n; len <<= 1) {
      final halfLen = len >> 1;
      final step = n ~/ len;
      for (var i = 0; i < n; i += len) {
        for (var k = 0; k < halfLen; k++) {
          final w  = k * step;
          final wr = _cosTable[w], wi = _sinTable[w];
          final ur = re[i + k], ui = im[i + k];
          final vr = re[i + k + halfLen] * wr - im[i + k + halfLen] * wi;
          final vi = re[i + k + halfLen] * wi + im[i + k + halfLen] * wr;
          re[i + k]          = ur + vr;
          im[i + k]          = ui + vi;
          re[i + k + halfLen] = ur - vr;
          im[i + k + halfLen] = ui - vi;
        }
      }
    }
  }

  // ---- Hann window ----------------------------------------------------------

  static Float64List _buildHann(int n) {
    final w = Float64List(n);
    for (var i = 0; i < n; i++) {
      w[i] = 0.5 * (1.0 - math.cos(2.0 * math.pi * i / (n - 1)));
    }
    return w;
  }

  // ---- Mel filterbank (HTK-style, triangular) -------------------------------

  static List<Float64List> _buildMelFb(
      int nMels, int nFft, int sr, double fMin, double fMax) {
    final halfFft = nFft ~/ 2 + 1;

    double hzToMel(double hz) => 2595.0 * math.log(1.0 + hz / 700.0) / math.ln10;
    double melToHz(double mel) => 700.0 * (math.pow(10.0, mel / 2595.0) - 1.0);

    final melMin = hzToMel(fMin);
    final melMax = hzToMel(fMax);
    // nMels + 2 evenly-spaced mel points.
    final melPts = List<double>.generate(
        nMels + 2, (i) => melMin + i * (melMax - melMin) / (nMels + 1));
    // Convert to Hz then to FFT bin indices.
    final binPts = melPts
        .map((m) => (melToHz(m) / sr * nFft).roundToDouble())
        .toList();

    final fb = List<Float64List>.generate(nMels, (_) => Float64List(halfFft));
    for (var m = 0; m < nMels; m++) {
      final lo = binPts[m].toInt();
      final ctr = binPts[m + 1].toInt();
      final hi = binPts[m + 2].toInt();
      // Rising slope.
      for (var k = lo; k <= ctr && k < halfFft; k++) {
        final d = binPts[m + 1] - binPts[m];
        if (d > 0) fb[m][k] = (k - binPts[m]) / d;
      }
      // Falling slope.
      for (var k = ctr; k <= hi && k < halfFft; k++) {
        final d = binPts[m + 2] - binPts[m + 1];
        if (d > 0) fb[m][k] = (binPts[m + 2] - k) / d;
      }
    }
    return fb;
  }
}

extension on double {
  double toFloat32() {
    final buf = Float32List(1);
    buf[0] = this;
    return buf[0];
  }
}
