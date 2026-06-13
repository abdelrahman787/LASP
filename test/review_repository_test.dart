import 'package:test/test.dart';

import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/review_service.dart';

const int _msPerDay = 86400000;

WeakItem wi(int surah, int ayah, int wordIndex,
        {int errorCount = 3, required int lastErrorAt, double mastery = 0.4}) =>
    WeakItem(
      wordId: '$surah:$ayah:$wordIndex',
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
      errorCount: errorCount,
      lastErrorAt: lastErrorAt,
      masteryScore: mastery,
    );

void main() {
  const now = 1000000000000;

  group('in-memory repositories', () {
    test('weak item upsert/get/delete/clear', () async {
      final repo = InMemoryWeakItemRepository();
      await repo.upsert(wi(1, 1, 1, lastErrorAt: now));
      await repo.upsertAll([wi(1, 1, 2, lastErrorAt: now), wi(2, 5, 1, lastErrorAt: now)]);
      expect((await repo.getAll()).length, 3);
      expect((await repo.get('1:1:1'))!.surah, 1);

      // upsert overwrites by wordId
      await repo.upsert(wi(1, 1, 1, errorCount: 9, lastErrorAt: now));
      expect((await repo.get('1:1:1'))!.errorCount, 9);
      expect((await repo.getAll()).length, 3);

      await repo.delete('1:1:1');
      expect(await repo.get('1:1:1'), isNull);
      await repo.clear();
      expect(await repo.getAll(), isEmpty);
    });

    test('plan save/get/delete', () async {
      final repo = InMemoryPlanRepository();
      final plan = ReviewPlan(
        id: 'p1', name: 'n', items: const [], dailyTarget: 10,
        createdAt: now, updatedAt: now,
      );
      await repo.save(plan);
      expect((await repo.get('p1'))!.name, 'n');
      await repo.delete('p1');
      expect(await repo.get('p1'), isNull);
    });

    test('history append/query', () async {
      final repo = InMemoryReviewHistoryRepository();
      await repo.add(ReviewResult.fromCounts(
          planItemId: 'a', confirmedErrors: 0, totalWords: 4, reviewedAt: now));
      await repo.add(ReviewResult.fromCounts(
          planItemId: 'b', confirmedErrors: 1, totalWords: 4, reviewedAt: now));
      expect((await repo.getAll()).length, 2);
      expect((await repo.forItem('a')).length, 1);
    });
  });

  group('ReviewService full loop', () {
    test('aggregate → schedule → review → reschedule, persisted', () async {
      final weak = InMemoryWeakItemRepository();
      final plans = InMemoryPlanRepository();
      final history = InMemoryReviewHistoryRepository();
      final service = ReviewService(
        weakItems: weak, plans: plans, history: history,
      );

      // Seed weak items: surah 2 ayat 10 & 11 (contiguous), surah 3 ayah 1.
      await weak.upsertAll([
        wi(2, 10, 1, errorCount: 4, lastErrorAt: now),
        wi(2, 11, 1, errorCount: 4, lastErrorAt: now),
        wi(3, 1, 1, errorCount: 6, lastErrorAt: now),
      ]);

      // 1. Build the plan from weak items.
      final plan = await service.rebuildAutoPlan(
          nowMs: now, pageResolver: (s, a) => 1);
      // Merged 2:10-11 (weakness 8+8=16) outranks 3:1 (12); merge gives 2 items.
      expect(plan.items.length, 2);
      expect(plan.items.first.id, '2:10-11');
      final range = plan.items.firstWhere((i) => i.isRange);
      expect(range.id, '2:10-11');

      // Plan persisted.
      expect((await plans.get('auto'))!.items.length, 2);

      // 2. Run a PASSING review on the surah-3 item.
      final result = ReviewResult.fromCounts(
        planItemId: '3:1', confirmedErrors: 0, totalWords: 5, reviewedAt: now,
      );
      final updated = await service.applyReview(
          planId: 'auto', result: result, nowMs: now);

      final item3 = updated.items.firstWhere((i) => i.id == '3:1');
      expect(item3.repetitions, 1);
      expect(item3.intervalDays, 1);
      expect(item3.status, PlanItemStatus.scheduled);
      expect(item3.dueAt, now + _msPerDay);

      // History recorded.
      expect((await history.forItem('3:1')).length, 1);

      // Weak item for 3:1 nudged: errorCount decayed, mastery raised.
      final w31 = await weak.get('3:1:1');
      expect(w31!.errorCount, 5, reason: 'passing review decays one error');
      expect(w31.masteryScore, greaterThan(0.4));

      // 3. Persisted plan reflects the reschedule.
      final reloaded = await plans.get('auto');
      expect(reloaded!.items.firstWhere((i) => i.id == '3:1').intervalDays, 1);
    });

    test('failing review keeps errorCount and resets the item', () async {
      final weak = InMemoryWeakItemRepository();
      final plans = InMemoryPlanRepository();
      final history = InMemoryReviewHistoryRepository();
      final service = ReviewService(
          weakItems: weak, plans: plans, history: history);

      await weak.upsert(wi(5, 7, 1, errorCount: 3, lastErrorAt: now));
      final plan = await service.rebuildAutoPlan(nowMs: now);
      final itemId = plan.items.first.id;

      final fail = ReviewResult.fromCounts(
          planItemId: itemId, confirmedErrors: 8, totalWords: 10, reviewedAt: now);
      final updated =
          await service.applyReview(planId: 'auto', result: fail, nowMs: now);

      final item = updated.items.first;
      expect(item.intervalDays, 1);
      expect(item.status, PlanItemStatus.due);

      final w = await weak.get('5:7:1');
      expect(w!.errorCount, 3, reason: 'failing review does not decay errors');
    });
  });
}
