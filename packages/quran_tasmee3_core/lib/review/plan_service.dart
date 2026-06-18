/// Manual / custom plan management (spec Phase 5): create plans by range,
/// snooze and reset items, delete plans, and generate the auto plan using
/// [UserSettings] instead of hardcoded defaults. Pure Dart over the existing
/// repositories + scheduler.
library;

import 'aggregation.dart';
import 'models.dart';
import 'repositories.dart';
import 'scheduler.dart';
import 'settings.dart';

const int _msPerDay = 86400000;

/// The kinds of range a custom plan can be built from.
enum RangeType { surah, juz, page, ayahRange }

/// A surah/ayah reference produced by an [AyahRangeResolver].
class AyahRef {
  final int surah;
  final int ayah;
  const AyahRef(this.surah, this.ayah);

  String get key => '$surah:$ayah';

  @override
  String toString() => 'AyahRef($surah:$ayah)';
}

/// Per-ayah location metadata (mirrors the mushaf data layer).
class AyahMeta {
  final int surah;
  final int ayah;
  final int juz;
  final int page;
  const AyahMeta({
    required this.surah,
    required this.ayah,
    required this.juz,
    required this.page,
  });
}

/// Expands a [RangeType]+bounds into the ordered ayat it covers. The Flutter
/// app implements this over `QuranRepository`; tests/in-app use
/// [InMemoryAyahRangeResolver].
abstract class AyahRangeResolver {
  List<AyahRef> resolve(RangeType type, int start, int end);
}

/// Resolver backed by an in-memory list of [AyahMeta]. For `ayahRange`, `start`
/// and `end` are treated as **1-based global ayah ordinals** into the mushaf
/// order (surah, then ayah) — the only range type whose bounds aren't a
/// surah/juz/page number.
class InMemoryAyahRangeResolver implements AyahRangeResolver {
  final List<AyahMeta> _meta;

  InMemoryAyahRangeResolver(List<AyahMeta> meta)
      : _meta = [...meta]..sort((a, b) {
          final s = a.surah.compareTo(b.surah);
          return s != 0 ? s : a.ayah.compareTo(b.ayah);
        });

  @override
  List<AyahRef> resolve(RangeType type, int start, int end) {
    final lo = start <= end ? start : end;
    final hi = start <= end ? end : start;

    Iterable<AyahMeta> picked;
    switch (type) {
      case RangeType.surah:
        picked = _meta.where((m) => m.surah >= lo && m.surah <= hi);
        break;
      case RangeType.juz:
        picked = _meta.where((m) => m.juz >= lo && m.juz <= hi);
        break;
      case RangeType.page:
        picked = _meta.where((m) => m.page >= lo && m.page <= hi);
        break;
      case RangeType.ayahRange:
        // 1-based global ordinals into the sorted mushaf order.
        final from = (lo - 1).clamp(0, _meta.length);
        final to = hi.clamp(0, _meta.length);
        picked = from < to ? _meta.sublist(from, to) : const [];
        break;
    }
    return picked.map((m) => AyahRef(m.surah, m.ayah)).toList(growable: false);
  }
}

/// Custom-plan + settings-aware operations.
class PlanService {
  final PlanRepository plans;
  final WeakItemRepository weakItems;
  final SettingsRepository settings;
  final AyahRangeResolver resolver;
  final int Function() now;

  PlanService({
    required this.plans,
    required this.weakItems,
    required this.settings,
    required this.resolver,
    required this.now,
  });

  /// Create a custom plan over a range. Items seed with `dueAt = now`,
  /// prioritized by `weaknessScore` from the [WeakItemRepository] (0 for ayat
  /// with no history). [dailyTarget] defaults to the user setting.
  Future<ReviewPlan> createCustomPlan({
    required RangeType type,
    required int start,
    required int end,
    int? dailyTarget,
    String? planId,
    String? name,
  }) async {
    final nowMs = now(); // one timestamp for the whole operation
    final s = await settings.get();
    final refs = resolver.resolve(type, start, end);

    // Dedup defensively, preserving order.
    final seen = <String>{};
    final unique = <AyahRef>[];
    for (final r in refs) {
      if (seen.add(r.key)) unique.add(r);
    }

    // Weakness lookup from existing history.
    final agg = aggregate(await weakItems.getAll(), nowMs: nowMs);
    final weaknessByKey = {for (final a in agg) '${a.surah}:${a.ayah}': a.weaknessScore};

    // Order by weakness desc, then natural mushaf order.
    final ordered = [...unique]..sort((a, b) {
        final wa = weaknessByKey[a.key] ?? 0.0;
        final wb = weaknessByKey[b.key] ?? 0.0;
        final byW = wb.compareTo(wa);
        if (byW != 0) return byW;
        final bs = a.surah.compareTo(b.surah);
        return bs != 0 ? bs : a.ayah.compareTo(b.ayah);
      });

    final items = [
      for (final r in ordered)
        PlanItem(
          id: r.key,
          surah: r.surah,
          ayah: r.ayah,
          dueAt: nowMs,
          status: PlanItemStatus.newItem,
        ),
    ];

    final plan = ReviewPlan(
      id: planId ?? 'custom-${type.name}-$start-$end-$nowMs',
      name: name ?? _defaultName(type, start, end),
      items: items,
      dailyTarget: dailyTarget ?? s.dailyTarget,
      createdAt: nowMs,
      updatedAt: nowMs,
    );
    await plans.save(plan);
    return plan;
  }

  /// Generate (or rebuild) the auto plan from weak items using [UserSettings]
  /// for the weakness threshold, daily target, and merge behavior — the
  /// settings-propagation entry point.
  Future<ReviewPlan> generateAutoPlan({
    String planId = 'auto',
    int? Function()? dailyTargetOverride,
    int Function(int surah, int ayah)? pageResolver,
  }) async {
    final s = await settings.get();
    final nowMs = now();
    final ayat = aggregate(await weakItems.getAll(),
        nowMs: nowMs, pageResolver: pageResolver);
    final qualifying = qualifyingAyat(ayat, s.toAggregationConfig());
    final plan = generatePlan(
      qualifying,
      nowMs: nowMs,
      planId: planId,
      dailyTarget: dailyTargetOverride?.call() ?? s.dailyTarget,
      mergeContiguous: s.mergeContiguous,
    );
    await plans.save(plan);
    return plan;
  }

  /// Push an item's due date forward by [days]; status stays `scheduled`.
  Future<ReviewPlan> snoozePlanItem(
      String planId, String itemId, int days) async {
    return _mutateItem(planId, itemId, (item) {
      return item.copyWith(
        dueAt: item.dueAt + days * _msPerDay,
        status: PlanItemStatus.scheduled,
      );
    });
  }

  /// Reset an item's progress: repetitions 0, interval 0, ease 2.5, due now,
  /// status back to `new` (and clear the last score).
  Future<ReviewPlan> resetPlanItem(String planId, String itemId) async {
    return _mutateItem(planId, itemId, (item) {
      return PlanItem(
        id: item.id,
        surah: item.surah,
        ayah: item.ayah,
        ayahEnd: item.ayahEnd,
        ease: 2.5,
        intervalDays: 0,
        repetitions: 0,
        dueAt: now(),
        lastScore: null,
        status: PlanItemStatus.newItem,
      );
    });
  }

  /// Delete a plan.
  Future<void> deletePlan(String planId) => plans.delete(planId);

  Future<ReviewPlan> _mutateItem(
      String planId, String itemId, PlanItem Function(PlanItem) f) async {
    final plan = await plans.get(planId);
    if (plan == null) throw StateError('plan "$planId" not found');
    final idx = plan.items.indexWhere((i) => i.id == itemId);
    if (idx < 0) throw StateError('item "$itemId" not in plan "$planId"');
    final items = [...plan.items];
    items[idx] = f(items[idx]);
    final updated = plan.copyWith(items: items, updatedAt: now());
    await plans.save(updated);
    return updated;
  }

  String _defaultName(RangeType type, int start, int end) {
    final label = start == end ? '$start' : '$start–$end';
    switch (type) {
      case RangeType.surah:
        return 'مراجعة سورة $label';
      case RangeType.juz:
        return 'مراجعة جزء $label';
      case RangeType.page:
        return 'مراجعة صفحة $label';
      case RangeType.ayahRange:
        return 'مراجعة آيات $label';
    }
  }
}
