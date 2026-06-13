# Quran Tasmee3 — Pure-Dart Cores

Quran Tasmee3 is a Flutter, offline-first Quran memorization app. This repo
currently contains the two **pure-Dart, fully unit-tested cores** that the rest
of the app builds on. They have **no Flutter, Firebase, ASR, or Quran-API
dependencies**, so they run and test standalone today and drop into the Flutter
app unchanged later.

## What's implemented

### 1. Recitation matching engine — `lib/recitation/`
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

### 2. Review-plan scheduler — `lib/review/`
Feature 4 (Review Plans spec, **Phases 0–1**).

| File | Purpose |
|------|---------|
| `models.dart` | `WeakItem`, `WeakAyah`, `PlanItem`, `ReviewPlan`, `ReviewResult`. Timestamps are epoch ms; statuses serialize to `new\|due\|scheduled\|mastered`. |
| `aggregation.dart` | Roll word-level weakness up to ayah level with a documented, configurable `recencyWeight`; threshold + confirmed-forget qualification. |
| `scheduler.dart` | `generatePlan` (priority ordering + contiguous-ayah merge), SM-2-lite `reschedule`, `dueToday` / `todaysQueue` / `upcoming`. |
| `repositories.dart` | Swappable async `WeakItemRepository` / `PlanRepository` / `ReviewHistoryRepository` interfaces (Firestore later) + in-memory implementations. |
| `review_service.dart` | Closes the loop: `rebuildAutoPlan`, `applyReview` (reschedule + history + mastery nudge), and `ingestSession` (roll a recitation session's confirmed errors into `weakItems`, ordered for plan generation). |

## Run it

```bash
# one-time: get a Dart SDK (3.5+), then:
dart pub get
dart test            # 30 tests across both cores
dart run example/demo.dart   # end-to-end loop on fake data
dart analyze         # clean
```

`example/demo.dart` simulates the closed loop on a fake Al-Fatiha scope:
recite → matching engine flags a substitution → weak item → aggregate →
generate plan → review → reschedule.

## Not yet built (needs external setup — see the spec docs)

These require accounts/secrets/assets that can't be provisioned from a sandbox:

- **Backend** (Firebase Auth + Firestore project on Spark, Cloudflare ASR
  Worker) — see `01_backend_firebase_cloudflare.md`.
- **Mushaf viewer Phase 0** (Quran Foundation API credentials, QCF V2 fonts,
  seeded `quran_qcf_v2.sqlite`) — see `02_mushaf_viewer_1.md`.
- The Flutter UI layers, `AsrService`, `RecitationController` (Phase 3+),
  Firestore persistence, and the review dashboard/detail screens — all consume
  the cores above through the contracts they already expose.

The cores were written against those documented contracts (`wordId =
"<surah>:<ayah>:<wordIndex>"`, the `weakItems` document shape, epoch-ms
timestamps) so they plug in without changes.
