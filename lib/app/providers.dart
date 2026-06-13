import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/review/aggregation.dart';
import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/review_service.dart';
import 'package:quran_tasmee3_core/review/scheduler.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

import 'data/fake_data.dart';
import 'data/quran_repository.dart';

// =============================================================================
// Dependency injection.
//
// Every external dependency is hidden behind an interface and bound to a FAKE
// here. To go live, change exactly ONE line per provider at its "SWAP POINT".
// Nothing else in the app references the concrete fakes.
// =============================================================================

/// Monotonic clock used by all schedulers/timers (epoch ms).
final clockProvider = Provider<int Function()>(
  (ref) => () => DateTime.now().millisecondsSinceEpoch,
);

/// Day/night theme selection.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

// --- External dependency #1: ASR (Cloudflare Worker + Groq) ------------------
final asrServiceProvider = Provider<AsrService>((ref) {
  // SWAP POINT 1 (Cloudflare Worker URL):
  //   return GroqAsrService(workerUrl: kWorkerUrl, idTokenProvider: ...);
  return FakeAsrService();
});

// --- External dependency #2: persistence (Firebase Firestore) ----------------
final weakItemRepositoryProvider = Provider<WeakItemRepository>((ref) {
  // SWAP POINT 2 (Firebase): return FirestoreWeakItemRepository(uid);
  return InMemoryWeakItemRepository();
});

final planRepositoryProvider = Provider<PlanRepository>((ref) {
  // SWAP POINT 2 (Firebase): return FirestorePlanRepository(uid);
  return InMemoryPlanRepository();
});

final reviewHistoryRepositoryProvider = Provider<ReviewHistoryRepository>((ref) {
  // SWAP POINT 2 (Firebase): return FirestoreReviewHistoryRepository(uid);
  return InMemoryReviewHistoryRepository();
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  // SWAP POINT 2 (Firebase) or local prefs: return FirestoreSettingsRepository(uid);
  return InMemorySettingsRepository();
});

// --- External dependency #3: Quran data (Quran Foundation API → SQLite) ------
final quranRepositoryProvider = Provider<QuranRepository>((ref) {
  // SWAP POINT 3 (bundled SQLite): return SqliteQuranRepository();
  return FakeQuranRepository();
});

final ayahRangeResolverProvider = Provider<AyahRangeResolver>((ref) {
  // SWAP POINT 3 (bundled SQLite): return SqliteAyahRangeResolver(...);
  return InMemoryAyahRangeResolver(fakeAyahMeta);
});

// --- Composed services (no swap needed — pure-Dart cores) --------------------
final reviewServiceProvider = Provider<ReviewService>((ref) {
  return ReviewService(
    weakItems: ref.watch(weakItemRepositoryProvider),
    plans: ref.watch(planRepositoryProvider),
    history: ref.watch(reviewHistoryRepositoryProvider),
  );
});

final planServiceProvider = Provider<PlanService>((ref) {
  return PlanService(
    plans: ref.watch(planRepositoryProvider),
    weakItems: ref.watch(weakItemRepositoryProvider),
    settings: ref.watch(settingsRepositoryProvider),
    resolver: ref.watch(ayahRangeResolverProvider),
    now: ref.watch(clockProvider),
  );
});

// --- Settings state ----------------------------------------------------------
class SettingsNotifier extends AsyncNotifier<UserSettings> {
  @override
  Future<UserSettings> build() =>
      ref.read(settingsRepositoryProvider).get();

  Future<void> save(UserSettings settings) async {
    state = const AsyncValue.loading();
    await ref.read(settingsRepositoryProvider).save(settings);
    state = AsyncValue.data(settings);
  }
}

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, UserSettings>(SettingsNotifier.new);

// --- Dashboard aggregate -----------------------------------------------------
class DashboardData {
  final ReviewPlan autoPlan;
  final List<PlanItem> dueToday;
  final List<WeakAyah> weakAyat;
  const DashboardData(this.autoPlan, this.dueToday, this.weakAyat);
}

/// Rebuilds the auto plan from current weak items and derives the dashboard
/// view. Invalidate this after a session to refresh.
final dashboardProvider = FutureProvider<DashboardData>((ref) async {
  final planSvc = ref.watch(planServiceProvider);
  final now = ref.watch(clockProvider)();
  final plan = await planSvc.generateAutoPlan();
  final due = todaysQueue(plan, now);
  final weak = await ref.watch(weakItemRepositoryProvider).getAll();
  final ayat = aggregate(weak, nowMs: now);
  return DashboardData(plan, due, ayat);
});

/// All saved plans (auto + custom).
final plansListProvider = FutureProvider<List<ReviewPlan>>((ref) async {
  return ref.watch(planRepositoryProvider).getAll();
});
