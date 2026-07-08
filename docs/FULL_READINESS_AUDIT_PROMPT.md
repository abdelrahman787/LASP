# Continuation prompt — full Android readiness audit for `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool.

---

You are running a **full readiness audit** of this repo before it's handed
to a human to install and test on a real Android device. This is broader
than the ASR-only gates you've been working through — check every subsystem
a real user would touch: app boot, mushaf display, ASR/audio, recitation
scoring, reports, review plans, settings, and persistence. The goal is a
single document the human can read once and know exactly what works, what
doesn't, and what to test themselves.

**You have a documented history on this repo of both fabricated claims
(early commits) and, more recently, genuinely evidence-backed claims (your
last 3 commits verified clean). Stay in the second mode.** Every finding
below must be backed by one of: (a) an actual command's pasted output, (b) a
direct file-content quote with its path, or (c) an explicit "could not
verify — reason" statement. No bare pass/fail claims.

## Part 1 — Build & environment readiness

1. `flutter doctor -v` — paste full output. Flag any ✗ or missing Android
   toolchain component.
2. `flutter build apk --debug` — you already confirmed this passes (commit
   `7352855`). Re-confirm it's still true after any changes since, and paste
   fresh output if you've touched `pubspec.yaml`/native config since then.
3. `android/app/src/main/AndroidManifest.xml` — read it and list every
   declared `<uses-permission>`. Cross-check against what the app actually
   needs:
   - `RECORD_AUDIO` (mic capture) — confirm present.
   - Storage/notification permissions if `data_backup.dart`'s export uses
     anything beyond clipboard (re-check: does it ONLY use
     `Clipboard.setData`, or does it also write files? If files, is a
     storage permission declared?).
   - Any permission declared but never used in code (dead permission) —
     flag it, don't just list.
4. Check `android/app/build.gradle.kts` and root `android/build.gradle.kts`
   for the compileSdk/JVM-heap fixes from the spec (§3.13/§3.14) — confirm
   both are still present and unmodified since they were last verified.
5. List every asset directory referenced in `pubspec.yaml`'s `flutter:
   assets:` section, then `ls` each one for real and report: does it exist,
   is it non-empty, and roughly how large (in case something is
   accidentally a 0-byte placeholder)? Specifically check:
   - `assets/quran/quran_uthmani.json` (claimed 1.4MB, 6236 ayahs — you
     already verified this once; re-confirm it's still there and unchanged).
   - `assets/fonts/` — Amiri Regular + Bold (claimed real TTF files, ~600KB
     each — re-confirm).
   - `assets/models/` (or wherever `model_int8.onnx` and `tokens.txt` live)
     — is the actual `.onnx` model file present and non-trivial in size
     (should be tens of MB, not a stub), or is it gitignored/absent (in
     which case: does the app have a clear error path when the model file is
     missing at runtime, rather than crashing silently)?
   - Any other font/icon/image asset declared in `pubspec.yaml` — confirm
     existence.

## Part 2 — Mushaf / Quran display readiness

1. Read `lib/features/mushaf/mushaf_screen.dart` (or wherever the current
   implementation lives) in full.
2. Confirm it actually calls `QuranData.load()` (the real 1.4MB JSON loader,
   not `seedForTesting`) in the real app path — `seedForTesting` must only
   be reachable from test code, never from `main.dart`'s real boot path.
   Grep `lib/` (excluding `test/`) for `seedForTesting` to confirm zero
   production call sites.
3. Confirm surah search/pagination code paths don't have an obvious
   off-by-one or empty-state bug by reading the logic (e.g., does surah 114
   render correctly at the end of the list? Does an empty search query show
   all 114 surahs or a blank screen?).
4. Confirm Arabic text actually renders with correct directionality
   assumptions in code (RTL from commit `a25c9be` — re-confirm the
   `Directionality`/`locale` wiring is still intact and this screen doesn't
   override it incorrectly).

## Part 3 — ASR / audio readiness (code-level, not device — that's Gate 1/2, already documented separately)

1. Confirm the dev ASR screen is still reachable via the documented
   trigger (5x long-press Settings tab within 3s) — read the actual
   gesture-detection code, don't just trust the comment.
2. Confirm `asrServiceProvider` still correctly points to `FakeAsrServiceImpl`
   in the real app (production `RecitationScreen` should NOT accidentally
   be wired to the unverified `StreamingAsrService` — that swap only happens
   after Gate 2, per your own sign-off). Quote the current
   `providers.dart` line.
3. Confirm `FakeAsrServiceImpl`'s behavior is reasonable for a human doing a
   manual smoke test right now (does it produce plausible scripted Arabic
   text a tester could sanity-check the UI against, or empty/garbage
   output?).
4. Re-confirm `RECORD_AUDIO` permission is requested at runtime (not just
   declared in the manifest) before any real mic access is attempted —
   quote the permission-request code path.

## Part 4 — Recitation scoring, report, review, settings

1. `RecitationScreen` — confirm it's wired to `RecitationController` from
   the core package (not a reimplementation), and that word-coloring states
   (gray/dark/red/orange/green outline per spec §8) map to real
   `ErrorType`/status values from the core, not hardcoded app-layer guesses.
2. `ReportScreen` — confirm it reads from a real `SessionReport`-shaped
   object produced by the core's aggregation, not synthetic/hardcoded
   numbers. Trace one path: where does the report screen's data come from
   after a recitation session ends?
3. `ReviewScreen` — confirm `dueToday()`/`todaysQueue()`/`upcoming()` are
   real calls into the core's `ReviewService`, and that the Hive-backed
   `PlanRepository`/`ReviewHistoryRepository` from Phase 5 are actually the
   ones wired in (not still `InMemory*` by accident — check
   `providers.dart` for all repo providers, not just ASR).
4. `SettingsScreen` — confirm the 5 settings (dailyTarget, defaultMode,
   weaknessThreshold, masteryHorizonDays, mergeContiguous) round-trip
   through the real `SharedPreferencesSettingsRepository`, and that the
   export/import feature (post-defect-fix, using `data_backup.dart`) is the
   single live implementation with no leftover duplicate logic (re-confirm
   this stayed fixed since commit `2b3787d`).

## Part 5 — Persistence sanity

1. Confirm `main.dart` actually calls `Hive.initFlutter()` (or equivalent)
   and opens all required boxes before the app renders — trace the actual
   boot sequence in `main()`.
2. Confirm there's no code path where a Hive box is read before it's
   opened (would throw at runtime) — spot-check the repository
   implementations for this ordering hazard.

## Part 6 — End-to-end smoke test script for the human

Write out, as a numbered list in `PROGRESS.md`, the exact manual steps a
human should follow after installing the APK to sanity-check every
subsystem in one pass — something like: open app → see home screen → open
mushaf → search/browse a surah → open recitation for a known short surah →
use manual reveal buttons (since real ASR isn't wired yet) → finish session
→ view report → check review screen shows something reasonable → open
settings → change a setting → force-close and reopen the app → confirm the
setting persisted (this specifically tests Hive/SharedPreferences
persistence survives a real process restart, which nothing so far has
verified). Make each step concrete and checkable (what should the human see
if it's working, what would indicate it's broken).

## Reporting rules (same as every prior round)

- Every finding is CONFIRMED (with quoted evidence) / NOT CONFIRMED (with
  what's actually there instead) / COULD NOT CHECK (with the specific
  reason — missing tool, no device, etc.).
- Do not write "readiness: 100%" or similar aggregate scores. List findings
  per part, let the human draw their own conclusion.
- If you find a real bug or gap while doing this audit (not just a
  documentation gap), fix it if it's small and self-contained (e.g., a
  missing permission, an off-by-one), and say exactly what you changed and
  why. If it's a larger fix, just report it — don't attempt a large
  refactor mid-audit.
- Commit and push when done, same as every round. Confirm the push actually
  landed (check the GitHub URL yourself if you have a way to, the same way
  you'd want a reviewer to check it).
