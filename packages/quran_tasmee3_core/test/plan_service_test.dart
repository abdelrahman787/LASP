import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

const int _msPerDay = 86400000;
const int now = 1000000000000;

/// Small mushaf metadata fixture:
///  - surah 1: 7 ayat, juz 1, page 1
///  - surah 2: ayat 1–5, juz 1, pages 2 (1–3) & 3 (4–5)
List<AyahMeta> fixtureMeta() {
  final meta = <AyahMeta>[];
  for (var a = 1; a <= 7; a++) {
    meta.add(AyahMeta(surah: 1, ayah: a, juz: 1, page: 1));
  }
  for (var a = 1; a <= 5; a++) {
    meta.add(AyahMeta(surah: 2, ayah: a, juz: 1, page: a <= 3 ? 2 : 3));
  }
  return meta;
}

WeakItem wi(int surah, int ayah, {int errorCount = 3, int? lastErrorAt}) =>
    WeakItem(
      wordId: '$surah:$ayah:1',
      surah: surah,
      ayah: ayah,
      wordIndex: 1,
      errorCount: errorCount,
      lastErrorAt: lastErrorAt ?? now,
      masteryScore: 0.4,
    );

void main() {
  late InMemoryPlanRepository plans;
  late InMemoryWeakItemRepository weak;
  late InMemorySettingsRepository settingsRepo;
  late PlanService svc;

  PlanService build({UserSettings? settings}) {
    plans = InMemoryPlanRepository();
    weak = InMemoryWeakItemRepository();
    settingsRepo = InMemorySettingsRepository(settings);
    return PlanService(
      plans: plans,
      weakItems: weak,
      settings: settingsRepo,
      resolver: InMemoryAyahRangeResolver(fixtureMeta()),
      now: () => now,
    );
  }

  group('createCustomPlan by range', () {
    test('surah range seeds one item per ayah and persists', () async {
      svc = build();
      final plan = await svc.createCustomPlan(
          type: RangeType.surah, start: 1, end: 1);
      expect(plan.items.length, 7); // Al-Fatiha
      expect(plan.items.every((i) => i.dueAt == now), isTrue);
      expect(plan.items.every((i) => i.status == PlanItemStatus.newItem), isTrue);
      expect((await plans.get(plan.id))!.items.length, 7);
    });

    test('page range picks only that page', () async {
      svc = build();
      final plan =
          await svc.createCustomPlan(type: RangeType.page, start: 2, end: 2);
      // page 2 = surah 2 ayat 1–3
      expect(plan.items.map((i) => i.id).toSet(), {'2:1', '2:2', '2:3'});
    });

    test('juz range spans surahs', () async {
      svc = build();
      final plan =
          await svc.createCustomPlan(type: RangeType.juz, start: 1, end: 1);
      expect(plan.items.length, 12); // 7 + 5
    });

    test('ayahRange uses global ordinals', () async {
      svc = build();
      // ordinals 8..9 = surah 2 ayah 1, 2 (after Fatiha's 7).
      final plan = await svc.createCustomPlan(
          type: RangeType.ayahRange, start: 8, end: 9);
      expect(plan.items.map((i) => i.id), equals(['2:1', '2:2']));
    });

    test('priority orders by weaknessScore desc (history beats no-history)',
        () async {
      svc = build();
      // Make surah 1 ayah 5 the weakest.
      await weak.upsert(wi(1, 5, errorCount: 9));
      await weak.upsert(wi(1, 2, errorCount: 4));
      final plan = await svc.createCustomPlan(
          type: RangeType.surah, start: 1, end: 1);
      expect(plan.items.first.id, '1:5');
      expect(plan.items[1].id, '1:2');
      // the remaining (no history) keep natural order after the weak ones.
      expect(plan.items[2].id, '1:1');
    });

    test('dailyTarget falls back to settings, override respected', () async {
      svc = build(settings: const UserSettings(dailyTarget: 7));
      final p1 =
          await svc.createCustomPlan(type: RangeType.surah, start: 1, end: 1);
      expect(p1.dailyTarget, 7);
      final p2 = await svc.createCustomPlan(
          type: RangeType.surah, start: 1, end: 1, dailyTarget: 3);
      expect(p2.dailyTarget, 3);
    });
  });

  group('snooze / reset / delete', () {
    test('snooze pushes dueAt forward by N days, status scheduled', () async {
      svc = build();
      final plan =
          await svc.createCustomPlan(type: RangeType.surah, start: 1, end: 1);
      final id = plan.items.first.id;
      final updated = await svc.snoozePlanItem(plan.id, id, 3);
      final item = updated.items.firstWhere((i) => i.id == id);
      expect(item.dueAt, now + 3 * _msPerDay);
      expect(item.status, PlanItemStatus.scheduled);
      // persisted
      expect(
          (await plans.get(plan.id))!.items.firstWhere((i) => i.id == id).dueAt,
          now + 3 * _msPerDay);
    });

    test('reset restores defaults and clears progress', () async {
      svc = build();
      final plan =
          await svc.createCustomPlan(type: RangeType.surah, start: 1, end: 1);
      final id = plan.items.first.id;
      // First mutate the item to a non-default state.
      await svc.snoozePlanItem(plan.id, id, 10);
      final loaded = (await plans.get(plan.id))!;
      final mutated = loaded.items.firstWhere((i) => i.id == id);
      final hacked = mutated.copyWith(
          repetitions: 4, intervalDays: 20, ease: 1.7, lastScore: 0.3);
      await plans.save(loaded.copyWith(items: [
        for (final i in loaded.items) i.id == id ? hacked : i,
      ]));

      final updated = await svc.resetPlanItem(plan.id, id);
      final item = updated.items.firstWhere((i) => i.id == id);
      expect(item.repetitions, 0);
      expect(item.intervalDays, 0);
      expect(item.ease, 2.5);
      expect(item.dueAt, now);
      expect(item.lastScore, isNull);
      expect(item.status, PlanItemStatus.newItem);
    });

    test('delete removes the plan from the repo', () async {
      svc = build();
      final plan =
          await svc.createCustomPlan(type: RangeType.surah, start: 1, end: 1);
      expect(await plans.get(plan.id), isNotNull);
      await svc.deletePlan(plan.id);
      expect(await plans.get(plan.id), isNull);
    });

    test('mutating a missing item/plan throws', () async {
      svc = build();
      expect(() => svc.snoozePlanItem('nope', 'x', 1), throwsStateError);
    });
  });

  group('settings propagation', () {
    test('weaknessThreshold changes which ayat qualify for the auto plan',
        () async {
      svc = build(
          settings: const UserSettings(
              weaknessThreshold: 2.0, mergeContiguous: false));
      // weaknessScore ≈ errorCount * 2 (errors at "now"): 1 error → ~2.0.
      await weak.upsert(wi(2, 1, errorCount: 1)); // ~2.0
      await weak.upsert(wi(2, 2, errorCount: 5)); // ~10.0

      final lenient = await svc.generateAutoPlan();
      expect(lenient.items.length, 2, reason: 'both qualify at threshold 2.0');

      // Raise the threshold so only the strong-weakness ayah qualifies.
      await settingsRepo
          .save(const UserSettings(weaknessThreshold: 5.0, mergeContiguous: false));
      final strict = await svc.generateAutoPlan();
      expect(strict.items.length, 1);
      expect(strict.items.single.id, '2:2');
    });

    test('dailyTarget setting flows into the generated auto plan', () async {
      svc = build(settings: const UserSettings(dailyTarget: 4));
      await weak.upsert(wi(1, 1, errorCount: 5));
      final plan = await svc.generateAutoPlan();
      expect(plan.dailyTarget, 4);
    });

    test('UserSettings.toAggregationConfig + recitationConfig derive correctly',
        () {
      const s = UserSettings(
          weaknessThreshold: 3.5,
          mergeContiguous: false,
          defaultMode: RecitationMode.strict);
      expect(s.toAggregationConfig().weaknessThreshold, 3.5);
      expect(s.toAggregationConfig().mergeContiguous, isFalse);
      expect(s.recitationConfig.levThreshold, RecitationConfig.strict.levThreshold);
    });
  });
}
