# quran_tasmee3_core — Public API Reference (v0.9.0)

> Phase-0 deliverable of the rebuild blueprint. This is the **frozen, fully
> tested** pure-Dart engine the new Flutter app consumes unchanged. Zero Flutter
> / Firebase / ASR-library dependencies; runs under plain `dart test` (128 tests
> pass, `dart analyze` clean).
>
> Consume it as a path dependency:
> ```yaml
> dependencies:
>   quran_tasmee3_core:
>     path: packages/quran_tasmee3_core
> ```
> Import surface lives under `package:quran_tasmee3_core/recitation/…` and
> `…/review/…`.

---

## 1. Recitation — matching

### `normalizer.dart`
- `String normalizeForMatch(String input)` — matching-only normalization:
  strips tatweel/diacritics; unifies alef variants (incl. dagger-alef U+0670 →
  full alef), alef-maqsura→ya, hamza carriers, ta-marbuta→ha. **Never alters
  displayed text.**
- `List<String> tokenize(String normalized)` — whitespace split, drops empties.

### `distance.dart`
- `int levenshtein(String a, String b)` — rolling-row DP edit distance.
- `double levRatio(String a, String b)` — `levenshtein / maxLen` in `[0,1]`.

### `recitation_config.dart`
- `enum RecitationMode { easy, normal, strict }`
- `class RecitationConfig { double levThreshold; double confFloor; … }` —
  presets `RecitationConfig.easy` (0.30) / `.normal` (0.20) / `.strict` (0.10).

### `matching_engine.dart`
- `enum ErrorType { forget, substitution, order, pronunciation, addition, asrLag }`
- `class ExpectedWord { String wordId; int surah, ayah, wordIndex; String norm, display; }`
- `class RecitationError { ErrorType type; … }`
- `class MatchResult { … }`
- `MatchResult matchUtterance({ required List<ExpectedWord> scope, required int cursor, required List<String> recognized, required RecitationConfig mode, … })`
  — stateless. Context-replay absorption, longest-correct-prefix matching across
  ayah boundaries, substitution/order/addition classification + pronunciation
  flags. (Order look-ahead bounded to an 8-word window.)
- `class AnchorMatch { int index; int matchedRun; … }`
- `findBestAnchor(…)` — scans the whole scope for the best re-alignment when the
  cursor is stuck; returns a candidate only above min-words/min-fraction.

### `alignment.dart` (Phase 1)
- `enum WordAlignOp { matched, substituted, omitted, inserted }`
- `class AlignedPair { WordAlignOp op; int expectedIndex, recognizedIndex; double score; }`
- `class WordAlignment { List<AlignedPair> pairs; Map<int,int> expectedToRecognized; int firstExpected, lastExpected, matchedCount, recognizedCount; double coverage; }`
- `WordAlignment fittingAlign({ required List<String> expected, required List<String> recognized, required RecitationConfig mode, double gapCost })`
  — Needleman-Wunsch with a free prefix/suffix gap; alef-insensitive scoring.
- `WordAlignment fittingAlignScope({ required List<ExpectedWord> scope, required List<String> recognized, … })`
- Forced-alignment seam: `class WordSpan { int wordIndex; double startSec, endSec; }`,
  `abstract class ForcedAligner`, `class UniformForcedAligner implements ForcedAligner`
  (in-memory fake; Phase 2 replaces with real CTC Viterbi).

---

## 2. Recitation — controller, ASR contract, report

### `asr_service.dart`
- `class AsrResult { String text; double confidence; bool get isFailure; }` —
  `isFailure` = empty/whitespace text OR `confidence == 0` (silent non-result;
  must not reach the engine).
- `abstract class AsrService { Future<void> start(void Function(AsrResult)); Future<void> pause(); Future<void> resume(); Future<void> flush(); Future<void> stop(); }`
  — **the swap point for the new `StreamingAsrService`.**
- `class FakeAsrService implements AsrService` — scripted driver for tests.

### `recitation_controller.dart`
- `enum RecitationStatus { idle, listening, matching, revealing, error, completed, paused }`
- `enum ErrorSeverity { transient, soft, confirmed, flag }`
- `class RecordedError { … }`
- `abstract class SessionLogger` + `class InMemorySessionLogger`
- `enum RecitationEventType { … }` + `class RecitationEvent`
- `class RecitationController` — orchestrates `matchUtterance` + injectable
  clock-driven silence timers (indicator / direct-forget), the attempt ladder
  (1 transient / 2 soft / 3+ confirmed), Reveal Next Word / Reveal Full Ayah
  (direct forgets bypassing the ladder), context-replay pass-through,
  pronunciation flags, ASR-failure counting, re-anchor recovery, pause/resume.
  Constants: `kAsrUnclearThreshold=3`, `kSilentStallThreshold=5`,
  `kAsrResetStuckMultiplier=2`, `kMaxBackwardReanchor=4`.

### `session_report.dart`
- `class ReportEntry`, `class AyahAccuracy`, `class SessionReport`
- `SessionReport buildSessionReport({ required List<RecordedError> log, … })` —
  groups errors into the 5 Arabic buckets (forget split silence/manual,
  substitution, addition, order, pronunciation), computes a score penalizing
  only confirmed errors, per-ayah accuracy, one display bucket per word.

---

## 3. Review — planner & scheduler

### `models.dart`
- `class WeakItem`, `class WeakAyah`, `enum PlanItemStatus { newItem, due, scheduled, mastered }`,
  `class PlanItem`, `class ReviewPlan`, `class ReviewResult` (epoch-ms timestamps).

### `aggregation.dart`
- `class AggregationConfig { … recencyWeight … }`
- `List<WeakAyah> aggregate(List<WeakItem> items, { required int nowMs, AggregationConfig config })`
  — word→ayah rollup with recency weighting + threshold/confirmed-forget filter.

### `scheduler.dart`
- `ReviewPlan generatePlan(…)` — priority ordering + contiguous-ayah merge.
- `PlanItem reschedule(…)` — SM-2-lite (interval growth, ease floor 1.3, mastery).
- `List<PlanItem> dueToday(plan, nowMs)` / `todaysQueue(plan, nowMs)` / `upcoming(plan, nowMs)`.

### `settings.dart`
- `class UserSettings { dailyTarget, defaultMode, weaknessThreshold, masteryHorizonDays, mergeContiguous; … toAggregationConfig(); recitationConfig; }`
- `abstract class SettingsRepository` + `class InMemorySettingsRepository`.

### `repositories.dart`
- `abstract class WeakItemRepository` (incl. batched `getMany`/`upsertAll`),
  `abstract class PlanRepository`, `abstract class ReviewHistoryRepository`, and
  in-memory implementations. **Swap points for Firestore in Phase 4.**

### `plan_service.dart`
- `enum RangeType { surah, juz, page, ayahRange }`, `class AyahRef`, `class AyahMeta`,
  `abstract class AyahRangeResolver` + `InMemoryAyahRangeResolver`.
- `class PlanService` — `createCustomPlan` by range, `generateAutoPlan`,
  `snoozePlanItem`, `resetPlanItem`, `deletePlan`.

### `review_service.dart`
- `class ReviewService` — `aggregate → generatePlan → applyReview` (reschedule +
  history + weak-item mastery nudge); `ingestSession` rolls confirmed errors into
  weak items. `class ParsedWordId` / id validation.

---

## 4. Integration contract for the new app

The new app wires the core at exactly these seams (all behind Riverpod
providers, swappable for fakes in tests):

| Core seam | New-app implementation | Phase |
|---|---|---|
| `AsrService` | `StreamingAsrService` (sherpa OnlineRecognizer, isolate) | 2 |
| `WeakItem/Plan/ReviewHistory/Settings Repository` | Firestore-backed + in-memory fallback | 4 |
| `AyahRangeResolver` + page/word data | SQLite (QCF V2) repo | 3 |
| `RecitationController` | driven by the recitation screen | 3 |
| `matchUtterance` / `fittingAlign` / `findBestAnchor` | called from the recitation flow | 3 |
| `buildSessionReport` | report screen | 3 |
| `aggregate` / `generatePlan` / `reschedule` / `PlanService` | plans + dashboard | 3 |

**Rule:** the app adapts to these signatures. The core is never edited to fit the
app.
