/// Weak-ayah aggregation (spec Phase 0): roll word-level weakness up to the
/// reviewable ayah level. Pure Dart, fully deterministic given `nowMs`.
library;

import 'models.dart';

const int _msPerDay = 86400000;

/// Tunable knobs for aggregation. Surfaced as user settings later (spec
/// Phase 5) and passed into the pure functions.
class AggregationConfig {
  /// Minimum weakness score for an ayah to qualify for the plan.
  final double weaknessThreshold;

  /// Whether contiguous qualifying ayat in the same surah are merged into a
  /// single ranged plan item.
  final bool mergeContiguous;

  const AggregationConfig({
    this.weaknessThreshold = 2.0,
    this.mergeContiguous = true,
  });
}

/// Recency weight for an error timestamp: `1 + 1/(1 + daysSince)`.
///
/// A fresh error (daysSince≈0) weighs ~2.0; a very old one decays toward 1.0.
/// Documented + isolated so it can be swapped/tuned. `nowMs` and `lastErrorAt`
/// are epoch ms.
double recencyWeight(int lastErrorAt, int nowMs) {
  final daysSince = (nowMs - lastErrorAt) / _msPerDay;
  final d = daysSince < 0 ? 0.0 : daysSince; // clamp future timestamps
  return 1.0 + 1.0 / (1.0 + d);
}

/// Group weak words by `(surah, ayah)` and roll them up to [WeakAyah]s.
///
///  - `totalErrors`   = sum(errorCount)
///  - `lastErrorAt`   = max(lastErrorAt)
///  - `masteryScore`  = min(word masteryScore)
///  - `weaknessScore` = sum(errorCount * recencyWeight(lastErrorAt))
///  - `hasForget`     = any word has forgetCount > 0
///
/// [pageResolver] maps `(surah, ayah)` → mushaf page (via QuranRepository in
/// the app; pass a fake in tests). Defaults to page 0 when omitted.
///
/// Returns **all** aggregated ayat (qualified or not), sorted by weaknessScore
/// desc then lastErrorAt desc. Use [qualifyingAyat] to filter for the plan.
List<WeakAyah> aggregate(
  List<WeakItem> items, {
  required int nowMs,
  int Function(int surah, int ayah)? pageResolver,
}) {
  final groups = <String, List<WeakItem>>{};
  for (final it in items) {
    groups.putIfAbsent('${it.surah}:${it.ayah}', () => []).add(it);
  }

  final result = <WeakAyah>[];
  for (final entry in groups.values) {
    final surah = entry.first.surah;
    final ayah = entry.first.ayah;

    var totalErrors = 0;
    var lastErrorAt = 0;
    var mastery = double.infinity;
    var weakness = 0.0;
    var hasForget = false;

    for (final w in entry) {
      totalErrors += w.errorCount;
      if (w.lastErrorAt > lastErrorAt) lastErrorAt = w.lastErrorAt;
      if (w.masteryScore < mastery) mastery = w.masteryScore;
      weakness += w.errorCount * recencyWeight(w.lastErrorAt, nowMs);
      if (w.forgetCount > 0) hasForget = true;
    }

    result.add(WeakAyah(
      surah: surah,
      ayah: ayah,
      page: pageResolver?.call(surah, ayah) ?? 0,
      weaknessScore: weakness,
      totalErrors: totalErrors,
      lastErrorAt: lastErrorAt,
      masteryScore: mastery == double.infinity ? 1.0 : mastery,
      hasForget: hasForget,
    ));
  }

  result.sort((a, b) {
    final byWeak = b.weaknessScore.compareTo(a.weaknessScore);
    if (byWeak != 0) return byWeak;
    return b.lastErrorAt.compareTo(a.lastErrorAt);
  });
  return result;
}

/// An ayah qualifies if `weaknessScore >= threshold` OR it contains a
/// confirmed forget (spec Phase 0).
bool qualifies(WeakAyah a, AggregationConfig config) =>
    a.weaknessScore >= config.weaknessThreshold || a.hasForget;

/// Filter aggregated ayat down to those that qualify for the plan.
List<WeakAyah> qualifyingAyat(List<WeakAyah> ayat, AggregationConfig config) =>
    ayat.where((a) => qualifies(a, config)).toList(growable: false);
