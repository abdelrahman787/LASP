# Quran Tasmee3 — Current Version Analysis (Detailed Report)

> Snapshot analysis of the branch **`claude/peaceful-cannon-ktbz8d`** as it
> stands now. Scope: what the current version actually contains, its health, the
> real state of the ASR pipeline, test coverage, and a prioritized list of risks
> with concrete findings. Verified against the working tree and git history — not
> from memory. Anything I could not verify on hardware is marked accordingly.
>
> Companion docs: `DEVELOPMENT_JOURNEY.md` (history of problems) and
> `RECOMMENDATIONS.md` (what to do). This file is the **current-state audit**.

---

## 1. Executive Summary

The project is in a **healthy core / unverified-edge** state:

- The **pure-Dart core is solid**: 128 tests pass, `dart analyze` is clean, and
  the architecture (interfaces + swap points) is intact.
- **Phase 2 (on-device NeMo-CTC ASR) is now implemented in code**
  (`SherpaOnnxAsrService`, 522 LOC) and **wired live** via
  `kUseSherpaOnDeviceAsr = true` — but it runs with several **GATE TEST /
  UNVERIFIED constants** and **cannot be exercised in this environment** (the
  model/tokens/VAD assets are gitignored and absent).
- The main risks are at the edges: **a tracked secrets file**, a **CI workflow
  that targets the wrong project root**, **untested live ASR constants**, and
  **three coexisting ASR backends** (maintenance load).

### Health Scorecard

| Area | Status | Note |
|---|---|---|
| Pure-Dart core | 🟢 Healthy | 128 tests pass, analyze clean |
| Core architecture / guardrails | 🟢 Healthy | swap points + interfaces intact |
| Phase 1 alignment (`fittingAlign`) | 🟢 Done | tested; not yet adopted by controller |
| Phase 2 ASR service (code) | 🟡 Implemented | live flag on, but constants UNVERIFIED |
| Phase 2 ASR (on-device proof) | 🔴 Unverified | assets absent; Gate-1 not yet green here |
| CI pipeline | 🔴 Likely broken | `dart` at a Flutter root (see §6.2) |
| Secret hygiene | 🔴 Issue | `firebase_options.dart` tracked (see §6.1) |
| Encoding robustness | 🟡 Fragile | Arabic mojibake has bitten before |
| Dead/duplicate code | 🟡 Watch | 3 ASR backends coexist |

---

## 2. Inventory — What the Current Version Contains

### Code size
- **App (`lib/`)**: 6,724 LOC of Dart across 37 files.
- **Core (`packages/quran_tasmee3_core/lib/`)**: 3,121 LOC across 15 files.
- **Core tests**: 2,446 LOC across 10 test files.

### Largest files (complexity hotspots)
| LOC | File |
|---|---|
| 614 | `lib/dev/gate1_asr_check.dart` (throwaway gate harness) |
| 553 | `lib/features/mushaf/mushaf_page_widget.dart` (device-tuned) |
| 537 | `lib/app/data/tarteel_asr_service.dart` (old Whisper, device-tuned) |
| 522 | `lib/app/data/sherpa_onnx_asr_service.dart` (new NeMo-CTC) |
| 491 | `lib/features/recitation/recitation_screen.dart` |

### Feature surface (present and wired)
Auth (Firebase) · home dashboard · mushaf reader + index + page widget + font
loader + surah banner · recitation screen · report screen · review/plans/stats ·
settings · bookmarks · app shell/drawer. The app is a **complete UI shell**, not
a prototype.

### Core modules
`recitation/`: normalizer, distance, recitation_config, matching_engine,
recitation_controller, **alignment** (Phase 1), session_report, asr_service
(contract). `review/`: aggregation, scheduler, plan_service, review_service,
repositories, models, settings.

---

## 3. ASR Pipeline — The Critical Subsystem

This is where the current version changed the most. **Three ASR backends now
coexist**, selected by flags in `providers.dart`:

```
asrServiceProvider:
  kUseOnDeviceAsr (false)        → TarteelOnDeviceAsrService  (old Whisper)
  kUseSherpaOnDeviceAsr (TRUE)   → SherpaOnnxAsrService        (new NeMo-CTC)  ← LIVE
  else kUseRealAsr (true)        → GroqAsrService              (cloud fallback)
  else                           → FakeAsrService              (tests)
```

So the **live path today is `SherpaOnnxAsrService`**.

### 3.1 `SherpaOnnxAsrService` design (the new live service)
- Implements the core `AsrService` contract; runs the recognizer on a
  **background isolate** (`Isolate.spawn`) — correct (never blocks the mic/UI).
- **VAD-segmented**: uses Silero VAD (`silero_vad.onnx`) to cut at natural
  silences, then decodes each segment.
- **Variant B decode**: builds a **fresh recognizer + stream per chunk, freed
  after each**. This was a deliberate choice — the shared-recognizer loop could
  crash mid-loop, and Variant B decoded all chunks cleanly (documented in the
  file header). It trades per-chunk construction overhead for stability.
- **Capture discipline carried over** from the Whisper service: mic-byte vs
  sent-byte counters (`_micBytes`/`_sentBytes`), stuck-recovery `flush()` (VAD
  reset, mic stays live), and final-chunk flush at `stop()` (CLAUDE.md item 11).
- **RTF logging** per chunk with the `[ASR]` tag (measured, as required).

### 3.2 ⚠️ Live constants that are UNVERIFIED ("GATE TEST" values)
From `sherpa_onnx_asr_service.dart`:
- `_kMaxSpeechDuration = 20.0` — **was 3.0**; changed to let Silero cut at
  natural silences instead of a forced 3 s flush. Marked `// UNVERIFIED`.
- `_kSegmentOverlap = 0.0` — **was 0.6** (Whisper-era boundary recovery).
  Marked `// UNVERIFIED`.
- `_kChunkSamples = 16000 * 8` (8 s) — `// UNVERIFIED chunk size, to be tuned`.
- `_kNumThreads = 2`, `_kMinDecodeSamples = 8000` (0.5 s skip threshold).
- **Confidence is hardcoded `0.85`** for any non-empty result (`// UNVERIFIED:
  better confidence proxy e.g. average logprob`). The engine's `isFailure`
  semantics still work (empty → 0), but every accepted word reports the same
  fake confidence — which feeds `pronunciation`/low-confidence logic downstream.

There are **9 `UNVERIFIED` + 2 `GATE TEST`** markers across the live code. The
commit history confirms this is intentional but provisional: commit `2591972`
is literally *"snapshot: before Gemini read-only review — maxSpeechDuration=20,
overlap=0 (untested)"*.

### 3.3 Assets required but absent
The live service needs **three gitignored files** that are not in the repo
(only `.gitkeep` is present in `assets/models/tarteel/`):
`model_int8.onnx`, `tokens.txt`, **`silero_vad.onnx`** (new dependency vs the
chunk-only gate harness). Without them the service cannot initialize; the app
would need to fall back (but the flag chain returns `SherpaOnnxAsrService`
unconditionally, so absent assets = init failure on device, not a graceful
fallback — see §6.4).

---

## 4. Phase Status

| Phase | State | Evidence |
|---|---|---|
| Phase 1 — core `fittingAlign` + seam | ✅ Done | `alignment.dart`, `alignment_test.dart`, 128 tests pass |
| Gate 0 (PC accuracy) | ✅ Passed | RTF ≈ 0.055 (human-confirmed) |
| Gate 1 (device load/transcribe) | 🟡 Partial | model loads; tokens fixer added; SIGSEGV mitigated via chunking; clean run not reported here |
| Phase 2 steps 5–8 (service/wiring/measure/seam) | 🟡 Code-complete, unverified | commit `fbbc1a5`; `sherpa_onnx_asr_service.dart`, `sherpa_onnx_asr_seam_test.dart`, provider flag |
| `fittingAlign` adopted by controller | 🔴 Not yet | only seam tests exist; `matchUtterance`/`findBestAnchor` unchanged |

**Important nuance:** Phase 2 was written **ahead of a green Gate 1 in this
environment**. The code exists and compiles-by-inspection, but the
"only-after-Gate-1" discipline from the original plan has been partially
front-run — the on-device verification still owes us a clean transcription run.

---

## 5. Test Coverage

- **128 core tests pass**; `dart analyze` on the core is clean.
- Test files: normalizer, distance (via matching), matching_engine,
  recitation_controller, alignment, session_report, **sherpa_onnx_asr_seam**,
  **unattempted_scoring**, review, review_repository, plan_service.
- Recent test-backed fixes:
  - `unattempted_scoring_test.dart` (commit `5c0671c`): un-attempted words now
    get **confirmed forgets** injected via the controller's public funnel, so
    unread ayahs no longer score 100%. Good fix, done without core edits.
  - `sherpa_onnx_asr_seam_test.dart`: tests the alignment seam.
- **Gap:** the tests cover **pure-Dart logic only**. The Flutter-side ASR
  service, the isolate, the VAD segmentation, and the live constants have **no
  automated coverage** (inherent — they need a device). This is expected but
  means the riskiest current code is the least tested.

---

## 6. Findings & Risks (Prioritized)

### 6.1 🔴 P0 — `lib/firebase_options.dart` is tracked despite being a declared secret
`.gitignore` lists it under *"Secrets — NEVER commit"*, yet `git ls-files`
confirms it **is tracked**. (`android/app/google-services.json` is correctly
untracked.) Firebase web config isn't a password, but it contains project
identifiers/api keys the team explicitly chose to keep out of VCS.
- **Action:** `git rm --cached lib/firebase_options.dart`, rotate if warranted,
  and provide it via local generation (`flutterfire configure`) or CI secret.
  Confirm no other secret slipped in historically.

### 6.2 🔴 P1 — CI workflow likely fails (wrong project root)
`.github/workflows/dart.yml` runs `dart pub get` / `dart analyze` / `dart test`
**at the repo root**, which is a **Flutter** app (depends on the `flutter` SDK).
Plain `dart pub get` cannot resolve a `flutter:` sdk dependency, so the job
almost certainly errors before testing anything.
- **Action:** either `cd packages/quran_tasmee3_core` for a pure-Dart job, or use
  `subosito/flutter-action` + `flutter pub get` / `flutter test` for the app.
  Right now CI provides false assurance (red or vacuous). Verify the actual run
  status on the Actions tab.

### 6.3 🟡 P1 — Live ASR constants are unverified
`_kMaxSpeechDuration = 20.0` and `_kSegmentOverlap = 0.0` are active in the live
service but untested on device (the commit says so). A 20 s max segment risks
re-introducing the **long-decode SIGSEGV** the chunking was meant to avoid, and
overlap=0 removes boundary-word recovery.
- **Action:** run the device sweep from `RECOMMENDATIONS.md` §2.2/§4.3 and lock
  measured values; until then keep the `// UNVERIFIED` markers.

### 6.4 🟡 P1 — No graceful fallback when model assets are missing
The flag chain returns `SherpaOnnxAsrService()` unconditionally when
`kUseSherpaOnDeviceAsr` is true; if the three assets are absent, init fails
rather than falling back to `GroqAsrService`/`FakeAsrService`.
- **Action:** detect missing assets at startup and fall back (the old comment
  promised "falls back to GroqAsrService if absent" — that promise isn't coded
  for the Sherpa path).

### 6.5 🟡 P1 — Confidence is a hardcoded 0.85
Every accepted word reports 0.85, feeding low-confidence/pronunciation logic with
a constant. Better: derive from average CTC logprob.
- **Action:** expose a real confidence from sherpa (or compute from logprobs);
  marked UNVERIFIED already.

### 6.6 🟡 P2 — Encoding fragility (Arabic text)
History shows Arabic corruption: commit `738d499` *"fix(encoding): restore
recitation_screen.dart Arabic UI text"*, and a comment in the Sherpa service
contains a replacement-character artifact where an en-dash was mangled. Arabic
string literals in source are being damaged by some tool in the loop.
- **Action:** enforce UTF-8 everywhere; avoid editors that re-encode (the
  Notepad lesson); consider externalizing UI strings to asset/ARB files so source
  edits can't corrupt them.

### 6.7 🟡 P2 — Three ASR backends coexist
`tarteel_asr_service.dart` (Whisper, 537 LOC) + `sherpa_onnx_asr_service.dart`
(NeMo, 522) + `groq_asr_service.dart` (288). The Phase-2 plan calls for removing
the Whisper code once NeMo is proven.
- **Action:** after Gate 1 is green and Sherpa is validated, delete the Whisper
  service (and `lib/dev/tarteel_cmp.dart`) to cut maintenance load — keep Groq as
  the documented debug fallback only.

### 6.8 🟢 P2 — `fittingAlign` not yet adopted by the controller
The alignment backbone exists and is tested, but `matchUtterance` /
`findBestAnchor` still drive matching. This is consistent with the "don't rewrite
tested code" guardrail, but the value of Phase 1 isn't realized until the seam is
wired (diff-reviewed). Tracked in `RECOMMENDATIONS.md` §5.1.

---

## 7. What's Good (worth preserving)

- **Clean separation**: pure-Dart core with zero Flutter imports; all externals
  behind interfaces + single-line swap points. This made adding a whole new ASR
  backend a localized change.
- **Discipline markers**: pervasive `// UNVERIFIED` tagging means provisional
  values are honest, not hidden.
- **Background isolate + capture audit** carried into the new service — the
  hard-won audio lessons weren't lost.
- **Tests-first culture**: scoring and seam fixes shipped with tests; 128 green.
- **Throwaway harness** (`gate1_*`) keeps device experiments out of the app.

---

## 8. Immediate Action List (ordered)

1. **(P0)** Untrack `lib/firebase_options.dart`; audit for other committed
   secrets.
2. **(P1)** Fix the CI workflow to target the core package (or use Flutter), so
   green means something.
3. **(P1)** Run Gate 1 on device with the three assets in place; confirm a clean
   transcription (text + per-chunk RTF + `[ASR]`/`[GATE1]` logs).
4. **(P1)** With Gate 1 green, sweep and lock `_kMaxSpeechDuration` /
   `_kSegmentOverlap` / `_kChunkSamples`; remove the GATE TEST tags.
5. **(P1)** Add the missing-asset graceful fallback for the Sherpa path.
6. **(P1)** Replace hardcoded confidence with a logprob-derived value.
7. **(P2)** Remove the Whisper service + comparison dev tool once NeMo is proven.
8. **(P2)** Wire `fittingAlign` at the engine seam (diff-reviewed).
9. **(P2)** Harden Arabic-string encoding (externalize UI strings).

---

## 9. Verification Status

| Claim in this report | How verified |
|---|---|
| 128 core tests pass, analyze clean | ran `dart test` + `dart analyze` in the core package |
| LOC figures | `wc -l` over `lib/` and the core |
| Live ASR = Sherpa NeMo-CTC | read `providers.dart` flag chain (`kUseSherpaOnDeviceAsr = true`) |
| GATE TEST / UNVERIFIED constants | read `sherpa_onnx_asr_service.dart` + `grep` markers |
| `firebase_options.dart` tracked | `git ls-files` |
| CI targets repo root with `dart` | read `.github/workflows/dart.yml` |
| Assets absent | `ls assets/models/tarteel/` (only `.gitkeep`) |
| On-device ASR behavior, real RTF, Gate-1 cleanliness | ❌ **NOT verified** — requires the device of record (no mic/model/HF here) |
