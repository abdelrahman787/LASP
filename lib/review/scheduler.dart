/// Spaced-repetition scheduling (spec Phase 1): turn qualifying weak ayat into
/// a scheduled plan, and reschedule items after each review with an SM-2-lite
/// algorithm. Pure Dart, deterministic given `nowMs`.
library;

import 'models.dart';

const int _msPerDay = 86400000;
const double _minEase = 1.3;

/// Default cap on items reviewed per day.
const int kDefaultDailyTarget = 10;

/// Default interval (days) at/after which an item is considered mastered.
const int kDefaultMasteryHorizon = 30;

/// A contiguous (or single) ayah range carrying the priority signals needed
/// to order and seed a [PlanItem].
class _Range {
  final int surah;
  final int ayahStart;
  int ayahEnd;
  double weaknessScore;
  int lastErrorAt;
  _Range(this.surah, this.ayahStart, this.ayahEnd, this.weaknessScore,
      this.lastErrorAt);
}

/// Merge contiguous qualifying ayat in the same surah into ranges. A merged
/// range's `weaknessScore` is the sum of its members' and `lastErrorAt` the
/// max. When [merge] is false, every ayah becomes its own single-ayah range.
List<_Range> _toRanges(List<WeakAyah> ayat, {required bool merge}) {
  final sorted = [...ayat]
    ..sort((a, b) {
      final s = a.surah.compareTo(b.surah);
      return s != 0 ? s : a.ayah.compareTo(b.ayah);
    });

  final ranges = <_Range>[];
  for (final a in sorted) {
    if (merge &&
        ranges.isNotEmpty &&
        ranges.last.surah == a.surah &&
        ranges.last.ayahEnd + 1 == a.ayah) {
      final r = ranges.last;
      r.ayahEnd = a.ayah;
      r.weaknessScore += a.weaknessScore;
      if (a.lastErrorAt > r.lastErrorAt) r.lastErrorAt = a.lastErrorAt;
    } else {
      ranges.add(_Range(a.surah, a.ayah, a.ayah, a.weaknessScore, a.lastErrorAt));
    }
  }
  return ranges;
}

/// Build an initial plan from qualifying weak ayat (spec Phase 1, step 1).
///
/// New items get `dueAt = now`, are ordered by priority (weaknessScore desc,
/// then lastErrorAt desc), and start as [PlanItemStatus.newItem].
ReviewPlan generatePlan(
  List<WeakAyah> qualifying, {
  required int nowMs,
  required String planId,
  String name = 'مراجعة النقاط الضعيفة',
  int dailyTarget = kDefaultDailyTarget,
  bool mergeContiguous = true,
}) {
  final ranges = _toRanges(qualifying, merge: mergeContiguous)
    ..sort((a, b) {
      final byWeak = b.weaknessScore.compareTo(a.weaknessScore);
      if (byWeak != 0) return byWeak;
      return b.lastErrorAt.compareTo(a.lastErrorAt);
    });

  final items = <PlanItem>[
    for (final r in ranges)
      PlanItem(
        id: r.ayahEnd > r.ayahStart
            ? '${r.surah}:${r.ayahStart}-${r.ayahEnd}'
            : '${r.surah}:${r.ayahStart}',
        surah: r.surah,
        ayah: r.ayahStart,
        ayahEnd: r.ayahEnd > r.ayahStart ? r.ayahEnd : null,
        dueAt: nowMs,
        status: PlanItemStatus.newItem,
      ),
  ];

  return ReviewPlan(
    id: planId,
    name: name,
    items: items,
    dailyTarget: dailyTarget,
    createdAt: nowMs,
    updatedAt: nowMs,
  );
}

/// SM-2-lite reschedule after a review (spec Phase 1, step 2). Returns a new
/// [PlanItem]; the original is not mutated.
PlanItem reschedule(
  PlanItem item,
  ReviewResult r, {
  required int nowMs,
  int masteryHorizon = kDefaultMasteryHorizon,
}) {
  // Map score → quality 0..5.
  var q = (r.score * 5).round();
  if (q < 0) q = 0;
  if (q > 5) q = 5;

  if (q < 3) {
    // Failed: reset, ease down, due tomorrow.
    final ease = _clampEase(item.ease - 0.2);
    return item.copyWith(
      repetitions: 0,
      intervalDays: 1,
      ease: ease,
      dueAt: nowMs + _msPerDay,
      lastScore: r.score,
      status: PlanItemStatus.due,
    );
  }

  // Passed: grow interval using the *current* ease, then update ease.
  final reps = item.repetitions + 1;
  final int intervalDays;
  if (reps == 1) {
    intervalDays = 1;
  } else if (reps == 2) {
    intervalDays = 3;
  } else {
    intervalDays = (item.intervalDays * item.ease).round();
  }

  final ease = _clampEase(item.ease + (0.1 - (5 - q) * (0.08 + (5 - q) * 0.02)));
  final status = intervalDays >= masteryHorizon
      ? PlanItemStatus.mastered
      : PlanItemStatus.scheduled;

  return item.copyWith(
    repetitions: reps,
    intervalDays: intervalDays,
    ease: ease,
    dueAt: nowMs + intervalDays * _msPerDay,
    lastScore: r.score,
    status: status,
  );
}

double _clampEase(double e) => e < _minEase ? _minEase : e;

/// Items due at or before [nowMs], overdue first (oldest dueAt first).
List<PlanItem> dueToday(ReviewPlan plan, int nowMs) {
  final due = plan.items
      .where((i) => i.status != PlanItemStatus.mastered && i.dueAt <= nowMs)
      .toList()
    ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  return due;
}

/// Today's review queue: due items capped at the plan's daily target.
List<PlanItem> todaysQueue(ReviewPlan plan, int nowMs) {
  final due = dueToday(plan, nowMs);
  if (due.length <= plan.dailyTarget) return due;
  return due.sublist(0, plan.dailyTarget);
}

/// Items not yet due (dueAt in the future), soonest first.
List<PlanItem> upcoming(ReviewPlan plan, int nowMs) {
  final up = plan.items
      .where((i) => i.status != PlanItemStatus.mastered && i.dueAt > nowMs)
      .toList()
    ..sort((a, b) => a.dueAt.compareTo(b.dueAt));
  return up;
}
