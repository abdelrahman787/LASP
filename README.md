# Quran Tasmee3

Quran Tasmee3 is a Flutter, offline-first Quran memorization app. The repo is a
two-part workspace:

- **`packages/quran_tasmee3_core/`** — the **pure-Dart, fully unit-tested cores**
  (recitation matching engine + review-plan scheduler). No Flutter/Firebase/ASR/
  Quran-API dependencies; runnable with plain `dart test`.
- **`lib/` + `android/ios/web/`** — the **Flutter app shell** wiring those cores
  into Riverpod providers. It runs end-to-end **entirely on fakes** today (no
  credentials), and each external dependency swaps to a real implementation via a
  single line in `lib/app/providers.dart` (see **Swapping in real services**).

## What's implemented

### 1. Recitation matching engine — `packages/quran_tasmee3_core/lib/recitation/`
The heart of features 2 & 3 (Recitation Engine spec, **Phase 1**).

| File | Purpose |
|------|---------|
| `normalizer.dart` | `normalizeForMatch` (tatweel/diacritic stripping, alef/ya/hamza/ta-marbuta unification) + `tokenize`. Matching-only; never alters displayed text. |
| `distance.dart` | `levenshtein` (rolling-row DP) + `levRatio`. |
| `recitation_config.dart` | Runtime-configurable mode thresholds — `easy` / `normal` / `strict`. |
| `matching_engine.dart` | Stateless `matchUtterance`: context-replay absorption, longest-correct-prefix matching across ayah boundaries, and classification into `substitution` / `order` / `addition`, with `pronunciation` flags on low-confidence accepts. |
| `asr_service.dart` | `AsrService` contract (real impl is mic/`dio` in the app) + scripted `FakeAsrService` for tests. |
| `recitation_controller.dart` | The Phase 3 orchestrator: matching + injectable-clock silence timers (5s indicator / 10s direct forget, no auto-advance), attempt ladder (1 transient / 2 soft / 3+ confirmed), Reveal Next Word / Full Ayah (direct forgets), pronunciation flags, ASR-failure → unclear hint. |
| `session_report.dart` | Phase 6 post-session report: five Arabic buckets (نسيان split silence/manual, استبدال, زيادة, خطأ ترتيب, نطق), session score penalizing only confirmed errors with a soft/confirmed breakdown, and per-ayah accuracy. |

Locked decisions honored: Rule D dropped (longest-correct-prefix), context
replay is not an error, `forget` is **not** produced here (it comes from the
silence timer / manual reveal in the controller, Phase 3).

### 2. Review-plan scheduler — `packages/quran_tasmee3_core/lib/review/`
Feature 4 (Review Plans spec, **Phases 0–1**).

| File | Purpose |
|------|---------|
| `models.dart` | `WeakItem`, `WeakAyah`, `PlanItem`, `ReviewPlan`, `ReviewResult`. Timestamps are epoch ms; statuses serialize to `new\|due\|scheduled\|mastered`. |
| `aggregation.dart` | Roll word-level weakness up to ayah level with a documented, configurable `recencyWeight`; threshold + confirmed-forget qualification. |
| `scheduler.dart` | `generatePlan` (priority ordering + contiguous-ayah merge), SM-2-lite `reschedule`, `dueToday` / `todaysQueue` / `upcoming`. |
| `repositories.dart` | Swappable async `WeakItemRepository` / `PlanRepository` / `ReviewHistoryRepository` interfaces (Firestore later) + in-memory implementations. |
| `review_service.dart` | Closes the loop: `rebuildAutoPlan`, `applyReview` (reschedule + history + mastery nudge), and `ingestSession` (roll a recitation session's confirmed errors into `weakItems`, ordered for plan generation). |
| `settings.dart` | `UserSettings` (dailyTarget, defaultMode, weaknessThreshold, masteryHorizonDays, mergeContiguous) — the single source for the knobs once hardcoded in aggregation/scheduler — + `SettingsRepository` (in-memory now). |
| `plan_service.dart` | Phase 5 manual management: `createCustomPlan` by `RangeType` (surah/juz/page/ayahRange) prioritized by weakness, `generateAutoPlan` (settings-driven), `snoozePlanItem`, `resetPlanItem`, `deletePlan`, plus an `AyahRangeResolver` seam (in-memory impl mirroring `QuranRepository`). |

### 3. Flutter app shell — `lib/`

| Path | Purpose |
|------|---------|
| `lib/main.dart` · `lib/app/app.dart` | Entry point + `MaterialApp` (RTL, day/night themes). |
| `lib/app/providers.dart` | **All dependency injection** — every external dep bound to a fake with a `SWAP POINT` marker. |
| `lib/app/data/quran_repository.dart` | `QuranRepository` seam + `FakeQuranRepository` (Al-Fatiha). |
| `lib/features/dashboard/` | Today's review + weak-spots dashboard (Review Plans Phase 3). |
| `lib/features/recitation/` | Recitation screen driving `RecitationController`; "simulate" buttons feed canned ASR so it runs without a mic. |
| `lib/features/report/` | Post-session report screen (five buckets, score, per-ayah accuracy). |
| `lib/features/plans/` | Plans list + custom-plan creation + per-item snooze/reset/delete (Phase 4/5). |
| `lib/features/settings/` | Edit `UserSettings`. |

## Run it

```bash
# Core (pure Dart — no Flutter needed):
cd packages/quran_tasmee3_core
dart pub get && dart test          # 69 tests
dart run example/demo.dart         # closed-loop demo on fake data

# Flutter app (runs fully on fakes, no credentials):
cd ../..
flutter pub get
flutter test                       # widget smoke test
flutter run                        # launches on a connected device/emulator
```

In the running app: tap **تسميع صفحة ١** → use the **محاكاة** (simulate) buttons
to feed correct/wrong/unclear "recitations", or the reveal buttons — finishing
produces the report and updates the dashboard's weak spots and the auto plan.

## Swapping in real services

All three external dependencies are faked behind interfaces. To go live, change
**one line per provider** in `lib/app/providers.dart`:

| # | Provider (SWAP POINT) | Fake now | Real later | You provide |
|---|------------------------|----------|------------|-------------|
| 1 | `asrServiceProvider` | — | `GroqAsrService` ✅ **active** (`kUseRealAsr = true`; mic via `record`, upload via `dio`, Firebase ID-token header). | **Cloudflare Worker URL** ✅ wired. |
| 2 | the four repo providers + `authServiceProvider` + `main.dart` | in-memory (signed-out fallback) | ✅ **Firestore** + **Firebase Auth** active when signed in (`users/<uid>/...`). | **`firebase_options.dart`** ✅ added (project `tasmeea-497bf`). Deploy `firestore.rules`. |
| 3 | `quranRepositoryProvider` + `ayahRangeResolverProvider` | `FakeQuranRepository` / `InMemoryAyahRangeResolver` | SQLite-backed | **Quran Foundation API creds** → seeded `quran_qcf_v2.sqlite` + QCF V2 fonts |

> **Deploy the security rules** (`firestore.rules`) to the project:
> `firebase deploy --only firestore:rules` (or paste them in the console). They
> restrict every `users/<uid>/...` doc to its owner.

The pure-Dart cores were written against the documented contracts (`wordId =
"<surah>:<ayah>:<wordIndex>"`, the `weakItems` document shape, epoch-ms
timestamps), so the real implementations drop in without touching them.
