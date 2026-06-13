import 'package:test/test.dart';

import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/aggregation.dart';
import 'package:quran_tasmee3_core/review/scheduler.dart';

const int _msPerDay = 86400000;

WeakItem wi(
  int surah,
  int ayah,
  int wordIndex, {
  required int errorCount,
  required int lastErrorAt,
  double mastery = 0.5,
  int forgetCount = 0,
}) {
  return WeakItem(
    wordId: '$surah:$ayah:$wordIndex',
    surah: surah,
    ayah: ayah,
    wordIndex: wordIndex,
    errorCount: errorCount,
    lastErrorAt: lastErrorAt,
    masteryScore: mastery,
    forgetCount: forgetCount,
  );
}

void main() {
  // Fixed "now" for deterministic recency math.
  const now = 1000000000000;

  group('aggregation', () {
    test('words across 2 ayat aggregate correctly', () {
      final items = [
        wi(1, 1, 1, errorCount: 2, lastErrorAt: now, mastery: 0.4),
        wi(1, 1, 2, errorCount: 1, lastErrorAt: now - _msPerDay, mastery: 0.6),
        wi(1, 2, 1, errorCount: 5, lastErrorAt: now, mastery: 0.2),
      ];
      final ayat = aggregate(items, nowMs: now);
      expect(ayat.length, 2);

      final a1 = ayat.firstWhere((a) => a.ayah == 1);
      expect(a1.totalErrors, 3);
      expect(a1.lastErrorAt, now);
      expect(a1.masteryScore, closeTo(0.4, 1e-9)); // min of 0.4, 0.6

      final a2 = ayat.firstWhere((a) => a.ayah == 2);
      expect(a2.totalErrors, 5);
      expect(a2.masteryScore, closeTo(0.2, 1e-9));
    });

    test('recency weighting orders a recent low-count ayah vs old high-count',
        () {
      // Ayah A: 1 error, today. Ayah B: 2 errors, 100 days ago.
      final items = [
        wi(2, 1, 1, errorCount: 1, lastErrorAt: now), // recent
        wi(2, 2, 1, errorCount: 2, lastErrorAt: now - 100 * _msPerDay), // old
      ];
      final ayat = aggregate(items, nowMs: now);
      // recencyWeight(today) ≈ 2.0 → A weakness ≈ 2.0
      // recencyWeight(100d) ≈ 1.0099 → B weakness ≈ 2.0198
      // They're close; verify the recent single error nearly matches an old
      // double error, demonstrating recency lifts a fresh low-count ayah.
      final a = ayat.firstWhere((x) => x.ayah == 1);
      final b = ayat.firstWhere((x) => x.ayah == 2);
      expect(a.weaknessScore, closeTo(2.0, 0.01));
      expect(b.weaknessScore, lessThan(2.05));
      expect(a.weaknessScore, greaterThan(1.9));
    });

    test('threshold filtering + forget override', () {
      final items = [
        // weak enough by score
        wi(3, 1, 1, errorCount: 3, lastErrorAt: now),
        // below threshold but has a confirmed forget → still qualifies
        wi(3, 2, 1,
            errorCount: 1, lastErrorAt: now - 50 * _msPerDay, forgetCount: 1),
        // below threshold, no forget → excluded
        wi(3, 3, 1, errorCount: 1, lastErrorAt: now - 50 * _msPerDay),
      ];
      final ayat = aggregate(items, nowMs: now);
      final q = qualifyingAyat(ayat, const AggregationConfig());
      final ayahs = q.map((a) => a.ayah).toSet();
      expect(ayahs, containsAll(<int>[1, 2]));
      expect(ayahs, isNot(contains(3)));
    });

    test('pageResolver maps surah/ayah to page', () {
      final items = [wi(5, 7, 1, errorCount: 3, lastErrorAt: now)];
      final ayat = aggregate(items, nowMs: now, pageResolver: (s, a) => 99);
      expect(ayat.single.page, 99);
    });
  });

  group('generatePlan + contiguous merge', () {
    test('contiguous qualifying ayat merge into a ranged item', () {
      final ayat = [
        const WeakAyah(
            surah: 2, ayah: 10, page: 1, weaknessScore: 5, totalErrors: 5,
            lastErrorAt: now, masteryScore: 0.3),
        const WeakAyah(
            surah: 2, ayah: 11, page: 1, weaknessScore: 4, totalErrors: 4,
            lastErrorAt: now, masteryScore: 0.3),
        const WeakAyah(
            surah: 2, ayah: 13, page: 1, weaknessScore: 3, totalErrors: 3,
            lastErrorAt: now, masteryScore: 0.3),
      ];
      final plan = generatePlan(ayat, nowMs: now, planId: 'p1');
      // 10-11 merge; 13 stands alone → 2 items.
      expect(plan.items.length, 2);
      final range = plan.items.firstWhere((i) => i.isRange);
      expect(range.ayah, 10);
      expect(range.ayahEnd, 11);
      expect(range.id, '2:10-11');
      // All new items due now.
      expect(plan.items.every((i) => i.dueAt == now), isTrue);
      expect(plan.items.every((i) => i.status == PlanItemStatus.newItem), isTrue);
    });

    test('items ordered by weakness priority', () {
      final ayat = [
        const WeakAyah(
            surah: 1, ayah: 1, page: 1, weaknessScore: 2, totalErrors: 2,
            lastErrorAt: now, masteryScore: 0.5),
        const WeakAyah(
            surah: 3, ayah: 1, page: 5, weaknessScore: 9, totalErrors: 9,
            lastErrorAt: now, masteryScore: 0.5),
      ];
      final plan =
          generatePlan(ayat, nowMs: now, planId: 'p', mergeContiguous: false);
      expect(plan.items.first.surah, 3); // higher weakness first
    });
  });

  group('SM-2-lite reschedule', () {
    PlanItem freshItem() => PlanItem(
          id: '1:1',
          surah: 1,
          ayah: 1,
          dueAt: now,
          status: PlanItemStatus.newItem,
        );

    test('failed review resets interval to 1 day and reduces ease', () {
      final item = freshItem().copyWith(
          repetitions: 3, intervalDays: 15, ease: 2.5);
      final r = ReviewResult.fromCounts(
          planItemId: '1:1', confirmedErrors: 8, totalWords: 10, reviewedAt: now);
      // score 0.2 → q=1 (failed)
      final out = reschedule(item, r, nowMs: now);
      expect(out.repetitions, 0);
      expect(out.intervalDays, 1);
      expect(out.ease, closeTo(2.3, 1e-9));
      expect(out.dueAt, now + _msPerDay);
      expect(out.status, PlanItemStatus.due);
    });

    test('consecutive passes grow intervals 1 → 3 → ease-scaled', () {
      var item = freshItem();
      final perfect = ReviewResult.fromCounts(
          planItemId: '1:1', confirmedErrors: 0, totalWords: 10, reviewedAt: now);

      item = reschedule(item, perfect, nowMs: now); // pass #1
      expect(item.repetitions, 1);
      expect(item.intervalDays, 1);

      item = reschedule(item, perfect, nowMs: now); // pass #2
      expect(item.repetitions, 2);
      expect(item.intervalDays, 3);

      final prevInterval = item.intervalDays;
      final easeUsed = item.ease;
      item = reschedule(item, perfect, nowMs: now); // pass #3
      expect(item.repetitions, 3);
      expect(item.intervalDays, (prevInterval * easeUsed).round());
      expect(item.intervalDays, greaterThan(3));
    });

    test('ease never drops below 1.3', () {
      var item = freshItem().copyWith(ease: 1.3);
      final fail = ReviewResult.fromCounts(
          planItemId: '1:1', confirmedErrors: 10, totalWords: 10, reviewedAt: now);
      for (var i = 0; i < 5; i++) {
        item = reschedule(item, fail, nowMs: now);
        expect(item.ease, greaterThanOrEqualTo(1.3));
      }
    });

    test('item reaching the horizon becomes mastered', () {
      // Force a large interval so the next pass exceeds the 30-day horizon.
      var item = freshItem().copyWith(repetitions: 5, intervalDays: 20, ease: 2.5);
      final perfect = ReviewResult.fromCounts(
          planItemId: '1:1', confirmedErrors: 0, totalWords: 10, reviewedAt: now);
      final out = reschedule(item, perfect, nowMs: now);
      // interval = round(20 * 2.5) = 50 >= 30
      expect(out.intervalDays, 50);
      expect(out.status, PlanItemStatus.mastered);
    });
  });

  group('dueToday / todaysQueue / upcoming', () {
    test('partitions by due date, caps queue, excludes mastered', () {
      final items = [
        PlanItem(id: 'a', surah: 1, ayah: 1, dueAt: now - 2 * _msPerDay), // overdue
        PlanItem(id: 'b', surah: 1, ayah: 2, dueAt: now - _msPerDay), // overdue
        PlanItem(id: 'c', surah: 1, ayah: 3, dueAt: now), // due now
        PlanItem(id: 'd', surah: 1, ayah: 4, dueAt: now + _msPerDay), // future
        PlanItem(
            id: 'e',
            surah: 1,
            ayah: 5,
            dueAt: now - _msPerDay,
            status: PlanItemStatus.mastered), // excluded
      ];
      final plan = ReviewPlan(
        id: 'p',
        name: 'n',
        items: items,
        dailyTarget: 2,
        createdAt: now,
        updatedAt: now,
      );

      final due = dueToday(plan, now);
      expect(due.map((i) => i.id), equals(['a', 'b', 'c'])); // overdue first
      expect(upcoming(plan, now).map((i) => i.id), equals(['d']));

      final queue = todaysQueue(plan, now);
      expect(queue.length, 2); // capped at dailyTarget
      expect(queue.map((i) => i.id), equals(['a', 'b']));
    });
  });
}
