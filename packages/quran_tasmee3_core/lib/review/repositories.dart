/// Swappable persistence interfaces for weak items, plans, and review history,
/// plus in-memory implementations.
///
/// These mirror the Firestore collections (`users/<uid>/weakItems`,
/// `.../reviewPlans`, `.../reviewHistory`) and are async so the Firestore-
/// backed implementations drop in later without changing call sites. The
/// in-memory versions make the full review loop testable with no Firebase.
library;

import 'models.dart';

/// CRUD over word-level weak items (`users/<uid>/weakItems/<wordId>`).
abstract class WeakItemRepository {
  Future<List<WeakItem>> getAll();
  Future<WeakItem?> get(String wordId);

  /// Batched read for many ids at once (one or few round-trips), returning only
  /// the ids that exist. Used by `ingestSession` to avoid N individual gets.
  Future<Map<String, WeakItem>> getMany(Iterable<String> wordIds);

  Future<void> upsert(WeakItem item);
  Future<void> upsertAll(Iterable<WeakItem> items);
  Future<void> delete(String wordId);
  Future<void> clear();
}

/// CRUD over review plans (`users/<uid>/reviewPlans/<planId>`).
abstract class PlanRepository {
  Future<List<ReviewPlan>> getAll();
  Future<ReviewPlan?> get(String planId);
  Future<void> save(ReviewPlan plan);
  Future<void> delete(String planId);
}

/// Append-only review history (`users/<uid>/reviewHistory/<resultId>`).
abstract class ReviewHistoryRepository {
  Future<void> add(ReviewResult result);
  Future<List<ReviewResult>> getAll();
  Future<List<ReviewResult>> forItem(String planItemId);
}

// --- in-memory implementations ---------------------------------------------

class InMemoryWeakItemRepository implements WeakItemRepository {
  final Map<String, WeakItem> _items = {};

  @override
  Future<List<WeakItem>> getAll() async => _items.values.toList();

  @override
  Future<WeakItem?> get(String wordId) async => _items[wordId];

  @override
  Future<Map<String, WeakItem>> getMany(Iterable<String> wordIds) async => {
        for (final id in wordIds)
          if (_items[id] != null) id: _items[id]!,
      };

  @override
  Future<void> upsert(WeakItem item) async {
    _items[item.wordId] = item;
  }

  @override
  Future<void> upsertAll(Iterable<WeakItem> items) async {
    for (final it in items) {
      _items[it.wordId] = it;
    }
  }

  @override
  Future<void> delete(String wordId) async {
    _items.remove(wordId);
  }

  @override
  Future<void> clear() async => _items.clear();
}

class InMemoryPlanRepository implements PlanRepository {
  final Map<String, ReviewPlan> _plans = {};

  @override
  Future<List<ReviewPlan>> getAll() async => _plans.values.toList();

  @override
  Future<ReviewPlan?> get(String planId) async => _plans[planId];

  @override
  Future<void> save(ReviewPlan plan) async {
    _plans[plan.id] = plan;
  }

  @override
  Future<void> delete(String planId) async {
    _plans.remove(planId);
  }
}

class InMemoryReviewHistoryRepository implements ReviewHistoryRepository {
  final List<ReviewResult> _history = [];

  @override
  Future<void> add(ReviewResult result) async => _history.add(result);

  @override
  Future<List<ReviewResult>> getAll() async => List.unmodifiable(_history);

  @override
  Future<List<ReviewResult>> forItem(String planItemId) async =>
      _history.where((r) => r.planItemId == planItemId).toList();
}
