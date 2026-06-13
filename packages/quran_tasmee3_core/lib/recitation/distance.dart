/// Edit-distance utilities used to decide whether a recited token is the
/// "same word within tolerance" as an expected word (Recitation Engine
/// spec, Phase 1b). All inputs are expected to be already-normalized strings.
library;

/// Classic char-level Levenshtein distance via dynamic programming.
///
/// Uses two rolling rows for O(min(a,b)) space. Operates on Unicode code
/// units (runes), which is correct for the Arabic letters that survive
/// normalization (all in the BMP).
int levenshtein(String a, String b) {
  if (identical(a, b) || a == b) return 0;
  if (a.isEmpty) return b.runes.length;
  if (b.isEmpty) return a.runes.length;

  final ra = a.runes.toList(growable: false);
  final rb = b.runes.toList(growable: false);
  final n = ra.length;
  final m = rb.length;

  // previous and current rows
  var prev = List<int>.generate(m + 1, (j) => j, growable: false);
  var curr = List<int>.filled(m + 1, 0, growable: false);

  for (var i = 1; i <= n; i++) {
    curr[0] = i;
    final ai = ra[i - 1];
    for (var j = 1; j <= m; j++) {
      final cost = (ai == rb[j - 1]) ? 0 : 1;
      final del = prev[j] + 1;
      final ins = curr[j - 1] + 1;
      final sub = prev[j - 1] + cost;
      var best = del < ins ? del : ins;
      if (sub < best) best = sub;
      curr[j] = best;
    }
    // swap rows
    final tmp = prev;
    prev = curr;
    curr = tmp;
  }

  return prev[m];
}

/// Normalized Levenshtein ratio in `[0,1]`:
/// `levenshtein(a,b) / max(len(a), len(b))`.
///
/// Returns `0.0` when both strings are empty (perfectly equal).
double levRatio(String a, String b) {
  final la = a.runes.length;
  final lb = b.runes.length;
  final maxLen = la > lb ? la : lb;
  if (maxLen == 0) return 0.0;
  return levenshtein(a, b) / maxLen;
}
