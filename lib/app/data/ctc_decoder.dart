/// Greedy CTC decoder for NeMo FastConformer (vocab_size=1025, blank_id=1024).
///
/// Input:  logprobs [T, V] — raw log-probabilities (NOT softmaxed; we just argmax).
/// Output: decoded string from tokens.txt.
library;

import 'dart:typed_data';

class CtcGreedyDecoder {
  static const int blankId = 1024;

  final List<String> _vocab; // id → piece string

  CtcGreedyDecoder(this._vocab);

  /// Build decoder from tokens.txt content.
  /// Each line: "<piece> <id>"
  factory CtcGreedyDecoder.fromTokensTxt(String content) {
    final vocab = List<String>.filled(1025, '');
    for (final line in content.split('\n')) {
      final parts = line.trim().split(' ');
      if (parts.length < 2) continue;
      final id = int.tryParse(parts.last);
      if (id == null || id < 0 || id >= 1025) continue;
      vocab[id] = parts.sublist(0, parts.length - 1).join(' ');
    }
    return CtcGreedyDecoder(vocab);
  }

  /// Decode logprobs [T * V] (flat, row-major T×V) into a string.
  String decode(Float32List logprobs, int T) {
    final V = logprobs.length ~/ T;
    final tokens = <int>[];
    var prevToken = blankId;
    for (var t = 0; t < T; t++) {
      // Argmax over vocab for frame t.
      var best = 0;
      var bestVal = logprobs[t * V];
      for (var v = 1; v < V; v++) {
        final val = logprobs[t * V + v];
        if (val > bestVal) { bestVal = val; best = v; }
      }
      if (best != blankId && best != prevToken) {
        tokens.add(best);
      }
      prevToken = best;
    }
    return _tokensToString(tokens);
  }

  String _tokensToString(List<int> ids) {
    final sb = StringBuffer();
    for (final id in ids) {
      if (id < 0 || id >= _vocab.length) continue;
      var piece = _vocab[id];
      if (piece == '<unk>') continue;
      // SentencePiece BPE: '▁' (U+2581) = space prefix.
      piece = piece.replaceAll('▁', ' ');
      sb.write(piece);
    }
    return sb.toString().trim();
  }
}
