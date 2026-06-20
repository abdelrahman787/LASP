/// Orchestrates the closed review loop over swappable repositories:
/// weak items → aggregate → generate/refresh plan → run review → reschedule →
/// persist. Pure Dart; works against the in-memory repos today and the
/// Firestore-backed ones later without changes.
library;

import '../recitation/matching_engine.dart';
import '../recitation/recitation_controller.dart';
import 'aggregation.dart';
import 'models.dart';
import 'repositories.dart';
import 'scheduler.dart';

class ReviewService {
  final WeakItemRepository weakItems;
  final PlanRepository plans;
  final ReviewHistoryRepository history;
  final AggregationConfig aggConfig;
  final int masteryHorizon;

  ReviewService({
    required this.weakItems,
    required this.plans,
    required this.history,
    this.aggConfig = const AggregationConfig(),
    this.masteryHorizon = kDefaultMasteryHorizon,
  });

  /// Build (or rebuild) the auto plan from the current weak items and persist
  /// it. Returns the saved plan.
  Future<ReviewPlan> rebuildAutoPlan({
    required int nowMs,
    String planId = 'auto',
    int dailyTarget = kDefaultDailyTarget,
    int Function(int surah, int ayah)? pageResolver,
  }) async {
    final items = await weakItems.getAll();
    final ayat = aggregate(items, nowMs: nowMs, pageResolver: pageResolver);
    final qualifying = qualifyingAyat(ayat, aggConfig);
    final plan = generatePlan(
      qualifying,
      nowMs: nowMs,
      planId: planId,
      dailyTarget: dailyTarget,
      mergeContiguous: aggConfig.mergeContiguous,
    );
    await plans.save(plan);
    return plan;
  }

  /// Apply a finished review to a plan item: record history, reschedule the
  /// item via SM-2-lite, persist the updated plan, and nudge the matching
  /// weak item's mastery upward (loop closure, spec Phase 4).
  ///
  /// Returns the updated plan.
  Future<ReviewPlan> applyReview({
    required String planId,
    required ReviewResult result,
    required int nowMs,
  }) async {
    final plan = await plans.get(planId);
    if (plan == null) {
      throw StateError('plan "$planId" not found');
    }

    await history.add(result);

    final idx = plan.items.indexWhere((i) => i.id == result.planItemId);
    if (idx < 0) {
      throw StateError('item "${result.planItemId}" not in plan "$planId"');
    }

    final updatedItem = reschedule(
      plan.items[idx],
      result,
      nowMs: nowMs,
      masteryHorizon: masteryHorizon,
    );
    final newItems = [...plan.items];
    newItems[idx] = updatedItem;
    final updatedPlan = plan.copyWith(items: newItems, updatedAt: nowMs);
    await plans.save(updatedPlan);

    // Reflect the review in the weak item(s) for the reviewed ayah/range:
    // a passing review raises mastery and decays errorCount.
    await _nudgeWeakItems(updatedItem, result, nowMs);

    return updatedPlan;
  }

  Future<void> _nudgeWeakItems(
      PlanItem item, ReviewResult result, int nowMs) async {
    final ayahEnd = item.ayahEnd ?? item.ayah;
    final all = await weakItems.getAll();
    final affected = all.where((w) =>
        w.surah == item.surah && w.ayah >= item.ayah && w.ayah <= ayahEnd);
    final updates = <WeakItem>[];
    for (final w in affected) {
      // Passing review (score >= 0.6 ≈ q>=3) decays one error; failing keeps it.
      final passed = result.score >= 0.6;
      final newErrorCount = passed && w.errorCount > 0
          ? w.errorCount - 1
          : w.errorCount;
      final newMastery = _clamp01((w.masteryScore + result.score) / 2);
      updates.add(WeakItem(
        wordId: w.wordId,
        surah: w.surah,
        ayah: w.ayah,
        wordIndex: w.wordIndex,
        errorCount: newErrorCount,
        lastErrorAt: w.lastErrorAt,
        masteryScore: newMastery,
        forgetCount: w.forgetCount,
      ));
    }
    if (updates.isNotEmpty) await weakItems.upsertAll(updates);
  }

  static double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

  /// Roll a finished recitation session's errors into `weakItems` (spec
  /// Phase 5/6 weak-item aggregation + handoff). Only **confirmed** mistakes
  /// (attempt 3+, silence forget, manual reveal, addition) bump a word's
  /// `errorCount`; soft (attempt 2) and pronunciation flags do not. Mastery is
  /// recomputed as `max(0, 1 - errorCount/10)`.
  ///
  /// Returns the updated weak items ordered for plan generation:
  /// `errorCount` desc, then `lastErrorAt` desc.
  Future<List<WeakItem>> ingestSession({
    required List<RecordedError> errors,
    required int nowMs,
  }) async {
    // Aggregate this session's counting errors per (validated) word.
    final addErrors = <String, int>{};
    final addForgets = <String, int>{};
    final lastAt = <String, int>{};
    final parsedById = <String, ParsedWordId>{};

    for (final e in errors) {
      if (e.severity != ErrorSeverity.confirmed) continue; // ignore soft/flag
      // asrLag is a system limitation (ASR fell behind), not a memorization
      // gap — it must never inflate a word's errorCount / weaken its mastery.
      if (e.errorType == ErrorType.asrLag) continue;
      final parsed = parseWordId(e.wordId);
      if (parsed == null) {
        // Malformed id — skip rather than writing a garbage 0:0:0 weak item.
        assert(() {
          // ignore: avoid_print
          print('ingestSession: skipping malformed wordId "${e.wordId}"');
          return true;
        }());
        continue;
      }
      parsedById[e.wordId] = parsed;
      addErrors[e.wordId] = (addErrors[e.wordId] ?? 0) + 1;
      if (e.errorType == ErrorType.forget) {
        addForgets[e.wordId] = (addForgets[e.wordId] ?? 0) + 1;
      }
      final at = e.createdAt == 0 ? nowMs : e.createdAt;
      if (at > (lastAt[e.wordId] ?? 0)) lastAt[e.wordId] = at;
    }

    if (addErrors.isNotEmpty) {
      // One batched read for all existing items, then one batched write.
      final existing = await weakItems.getMany(addErrors.keys);
      final updates = <WeakItem>[];
      for (final wordId in addErrors.keys) {
        final p = parsedById[wordId]!;
        final ex = existing[wordId];
        final newErrorCount = (ex?.errorCount ?? 0) + addErrors[wordId]!;
        final newForget = (ex?.forgetCount ?? 0) + (addForgets[wordId] ?? 0);
        final candidateLast = lastAt[wordId] ?? nowMs;
        final newLast =
            candidateLast > (ex?.lastErrorAt ?? 0) ? candidateLast : ex!.lastErrorAt;
        updates.add(WeakItem(
          wordId: wordId,
          surah: ex?.surah ?? p.surah,
          ayah: ex?.ayah ?? p.ayah,
          wordIndex: ex?.wordIndex ?? p.wordIndex,
          errorCount: newErrorCount,
          lastErrorAt: newLast,
          masteryScore: _clamp01(1.0 - newErrorCount / 10.0),
          forgetCount: newForget,
        ));
      }
      await weakItems.upsertAll(updates);
    }

    final all = await weakItems.getAll()
      ..sort((a, b) {
        final byCount = b.errorCount.compareTo(a.errorCount);
        if (byCount != 0) return byCount;
        return b.lastErrorAt.compareTo(a.lastErrorAt);
      });
    return all;
  }
}

/// A validated `"<surah>:<ayah>:<wordIndex>"` id.
class ParsedWordId {
  final int surah;
  final int ayah;
  final int wordIndex;
  const ParsedWordId(this.surah, this.ayah, this.wordIndex);
}

/// Parse + validate a wordId. Returns null on wrong shape or out-of-range
/// components (surah 1–114, ayah ≥ 1, wordIndex ≥ 0).
ParsedWordId? parseWordId(String id) {
  final parts = id.split(':');
  if (parts.length != 3) return null;
  final s = int.tryParse(parts[0]);
  final a = int.tryParse(parts[1]);
  final w = int.tryParse(parts[2]);
  if (s == null || a == null || w == null) return null;
  if (s < 1 || s > 114 || a < 1 || w < 0) return null;
  return ParsedWordId(s, a, w);
}
