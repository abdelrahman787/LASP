import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/review_service.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

/// =============================================================================
/// Dependency injection (rebuild — clean slate).
///
/// Every external dependency is hidden behind a core interface and bound here.
/// Each binding is a single-line SWAP POINT: fakes/in-memory today, real
/// implementations as each blueprint phase lands. Tests override these
/// providers, so production flags never affect tests.
/// =============================================================================

/// Monotonic clock (epoch ms) used by all schedulers/timers.
final clockProvider = Provider<int Function()>(
  (ref) => () => DateTime.now().millisecondsSinceEpoch,
);

/// Day/night theme.
final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.system);

/// App locale (Arabic-first).
final localeProvider = StateProvider<Locale>((ref) => const Locale('ar'));

// --- SWAP POINT 1: ASR -------------------------------------------------------
// Phase 2 replaces FakeAsrService with the new on-device StreamingAsrService
// (sherpa OnlineRecognizer on a background isolate). Until then the app runs on
// the scripted fake so it boots with no mic/model.
final asrServiceProvider = Provider<AsrService>((ref) => FakeAsrService());

// --- SWAP POINT 2: persistence (in-memory now → Firestore in Phase 4) --------
final weakItemRepositoryProvider =
    Provider<WeakItemRepository>((ref) => InMemoryWeakItemRepository());

final planRepositoryProvider =
    Provider<PlanRepository>((ref) => InMemoryPlanRepository());

final reviewHistoryRepositoryProvider =
    Provider<ReviewHistoryRepository>((ref) => InMemoryReviewHistoryRepository());

final settingsRepositoryProvider =
    Provider<SettingsRepository>((ref) => InMemorySettingsRepository());

// --- Composed core services (pure Dart — no swap needed) ---------------------
final reviewServiceProvider = Provider<ReviewService>((ref) {
  return ReviewService(
    weakItems: ref.watch(weakItemRepositoryProvider),
    plans: ref.watch(planRepositoryProvider),
    history: ref.watch(reviewHistoryRepositoryProvider),
  );
});

final settingsProvider = FutureProvider<UserSettings>((ref) {
  return ref.watch(settingsRepositoryProvider).get();
});

// NOTE: PlanService also needs an AyahRangeResolver + Quran data; those land
// with the mushaf data layer (Phase 3, SWAP POINT 3). Until then the plans
// screen uses the in-memory repos directly.
