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

import 'data/auth_service.dart';
import 'data/fake_data.dart';
import 'data/firestore_repositories.dart';
import 'data/groq_asr_service.dart';
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

// --- Auth (Firebase email/password) ------------------------------------------
final authServiceProvider = Provider<AuthService>((ref) {
  // Tests override this with FakeAuthService so Firebase is never touched.
  return FirebaseAuthService();
});

/// Current auth state; the app gates on this.
final authStateProvider = StreamProvider<AppUser?>((ref) {
  return ref.watch(authServiceProvider).authState();
});

/// Signed-in uid, or null. Firestore repos scope to it.
final uidProvider = Provider<String?>((ref) {
  return ref.watch(authStateProvider).valueOrNull?.uid;
});

// --- External dependency #1: ASR (Cloudflare Worker + Groq) ------------------

/// Deployed Cloudflare Worker (Groq ASR proxy). Used by [GroqAsrService].
const String kWorkerUrl =
    'https://quran-tasmee3-backend.abdelrahman-khamis.workers.dev';

/// SWAP POINT 1 — REAL [GroqAsrService] (mic + Worker upload) is now active.
/// The Firebase ID token (SWAP POINT 2) is wired via `idTokenProvider` below.
/// Tests override `asrServiceProvider` with a fake, so this flag only affects
/// the running app.
const bool kUseRealAsr = true;

final asrServiceProvider = Provider<AsrService>((ref) {
  if (kUseRealAsr) {
    final mode = ref.watch(settingsProvider).valueOrNull?.defaultMode.name ??
        'normal';
    final auth = ref.watch(authServiceProvider);
    return GroqAsrService(
      workerUrl: kWorkerUrl,
      mode: mode,
      idTokenProvider: auth.idToken, // SWAP POINT 2 complete
    );
  }
  return FakeAsrService();
});

// --- External dependency #2: persistence (Firebase Firestore) ----------------
// SWAP POINT 2 complete: Firestore-backed when signed in (data under
// users/<uid>/...); in-memory fallback when signed out so nothing touches
// Firebase before login.
final weakItemRepositoryProvider = Provider<WeakItemRepository>((ref) {
  final uid = ref.watch(uidProvider);
  return uid == null
      ? InMemoryWeakItemRepository()
      : FirestoreWeakItemRepository(uid);
});

final planRepositoryProvider = Provider<PlanRepository>((ref) {
  final uid = ref.watch(uidProvider);
  return uid == null ? InMemoryPlanRepository() : FirestorePlanRepository(uid);
});

final reviewHistoryRepositoryProvider = Provider<ReviewHistoryRepository>((ref) {
  final uid = ref.watch(uidProvider);
  return uid == null
      ? InMemoryReviewHistoryRepository()
      : FirestoreReviewHistoryRepository(uid);
});

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final uid = ref.watch(uidProvider);
  return uid == null
      ? InMemorySettingsRepository()
      : FirestoreSettingsRepository(uid);
});

// --- External dependency #3: Quran data (Quran Foundation API → SQLite) ------
// SWAP POINT 3 complete: load the bundled quran_qcf_v2.sqlite once into memory.
// While loading (or if the asset/plugins are unavailable, e.g. tests), the
// providers fall back to the Al-Fatiha fakes — so the app always runs.
final quranDataProvider = FutureProvider<QuranData?>((ref) async {
  try {
    return await loadQuranData();
  } catch (_) {
    return null; // asset missing / unsupported platform → fall back to fakes
  }
});

final quranRepositoryProvider = Provider<QuranRepository>((ref) {
  final data = ref.watch(quranDataProvider).valueOrNull;
  return data != null ? SqliteQuranRepository(data) : FakeQuranRepository();
});

final ayahRangeResolverProvider = Provider<AyahRangeResolver>((ref) {
  final data = ref.watch(quranDataProvider).valueOrNull;
  return InMemoryAyahRangeResolver(data?.ayahMeta ?? fakeAyahMeta);
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
      ref.watch(settingsRepositoryProvider).get();

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
  final int reviewedToday; // history entries reviewed since local midnight
  final int streakDays; // consecutive days (ending today) with ≥1 review
  const DashboardData(this.autoPlan, this.dueToday, this.weakAyat,
      this.reviewedToday, this.streakDays);

  int get dailyTarget => autoPlan.dailyTarget;
  double get dailyProgress =>
      dailyTarget <= 0 ? 0 : (reviewedToday / dailyTarget).clamp(0.0, 1.0);
}

const int _msPerDayUi = 86400000;

int _dayIndex(int epochMs) => epochMs ~/ _msPerDayUi; // UTC day bucket

int _computeStreak(Iterable<int> reviewedAtMs, int nowMs) {
  final days = reviewedAtMs.map(_dayIndex).toSet();
  if (days.isEmpty) return 0;
  var streak = 0;
  var day = _dayIndex(nowMs);
  while (days.contains(day)) {
    streak++;
    day--;
  }
  return streak;
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

  final history = await ref.watch(reviewHistoryRepositoryProvider).getAll();
  final todayStart = _dayIndex(now) * _msPerDayUi;
  final reviewedToday =
      history.where((r) => r.reviewedAt >= todayStart).length;
  final streak = _computeStreak(history.map((r) => r.reviewedAt), now);

  return DashboardData(plan, due, ayat, reviewedToday, streak);
});

/// All saved plans (auto + custom).
final plansListProvider = FutureProvider<List<ReviewPlan>>((ref) async {
  return ref.watch(planRepositoryProvider).getAll();
});
