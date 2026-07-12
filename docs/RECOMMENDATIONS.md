# Quran Tasmee3 — Engineering Recommendations (Full)

> Companion to `DEVELOPMENT_JOURNEY.md`. That file records **what went wrong and
> why**; this file is the **complete set of recommendations** — what to do next,
> the proposed fix for every open item, and the best-practice guardrails to keep
> us from regressing.
>
> Each recommendation has: **Priority** (P0 = blocking / do now, P1 = soon,
> P2 = nice-to-have), **What**, **Why**, **How**, and **Verification** (how we
> know it worked — on-device where required). Nothing here invents a constant;
> anything not yet measured is marked **UNVERIFIED — needs device test**.

### Table of Contents
1. [Priority Snapshot](#1-priority-snapshot)
2. [ASR Model & Pipeline](#2-asr-model--pipeline)
3. [Gate 1 → Phase 2 Path](#3-gate-1--phase-2-path)
4. [Audio Capture & VAD](#4-audio-capture--vad)
5. [Matching Engine & Classification](#5-matching-engine--classification)
6. [Mushaf Rendering](#6-mushaf-rendering)
7. [Fonts & Assets](#7-fonts--assets)
8. [Build / Tooling / Infrastructure](#8-build--tooling--infrastructure)
9. [Testing & Measurement Discipline](#9-testing--measurement-discipline)
10. [Process Guardrails](#10-process-guardrails)
11. [Suggested Roadmap (ordered)](#11-suggested-roadmap-ordered)

---

## 1. Priority Snapshot

| Priority | Item | Section |
|---|---|---|
| **P0** | Get a clean chunked Gate-1 transcription on device | [§3](#3-gate-1--phase-2-path) |
| **P0** | Decide streaming vs offline-chunked decode for the real pipeline | [§2.1](#21-streaming-vs-offline-chunked-the-key-architecture-call) |
| **P1** | Revert `_kMaxRecognizerThreads` 6 → 4 (measured regression) | [§4.1](#41-revert-thread-count) |
| **P1** | Run ASR on a background isolate, behind a flag | [§3.3](#33-sherpaonnxasrservice-design) |
| **P1** | Wire `fittingAlign` at the `matchUtterance`/`findBestAnchor` seam | [§5.1](#51-adopt-fittingalign-in-the-controller) |
| **P1** | Add RTF/latency probe (measured numbers, not guesses) | [§9.2](#92-build-the-measurement-probe-first) |
| **P2** | Tune chunk size / overlap on device | [§2.2](#22-chunking-parameters) |
| **P2** | Surah-banner polish; asset versioning | [§7.3](#73-asset-versioning) |

---

## 2. ASR Model & Pipeline

### 2.1 Streaming vs offline-chunked — the key architecture call
- **Priority:** P0
- **What:** Decide whether the production pipeline uses the **cache-aware
  streaming** model (`model_streaming_with_encoder.q8`, carrying
  `cache_last_channel`/`cache_last_time` + prev-token state across chunks) or the
  **offline model decoded in short chunks** (`model_int8.onnx`, fresh stream per
  chunk).
- **Why:** The whole reason we left Whisper was streaming latency. The offline
  model in 8 s chunks is simpler but reintroduces a per-chunk wait; the streaming
  model gives true live reveal but is more complex (seam state, duplicated
  letters if state isn't carried).
- **How (recommended):**
  1. First confirm the **offline-chunked** path works end-to-end at Gate 1 (it's
     the simpler baseline and proves the model+tokens+sherpa stack).
  2. Then prototype the **streaming** `OnlineRecognizer` path
     (`OnlineNemoCtcModelConfig`) and measure reveal latency per word on device.
  3. Choose streaming **only if** its measured live-reveal latency beats the
     chunked path enough to justify the seam-state complexity. Document the
     measured numbers in `DEVELOPMENT_JOURNEY.md`.
- **Verification:** side-by-side on-device measurement of (a) time-to-first-word
  and (b) per-word reveal lag for both paths, on the device of record.

### 2.2 Chunking parameters
- **Priority:** P2 (after Gate 1 green)
- **What:** Tune `_kChunkSamples` (currently `16000 * 8` = 8 s, **UNVERIFIED**)
  and the `_kSegmentOverlap` (0.6 s) for the chunked path.
- **Why:** 8 s was chosen to avoid the long-decode `SIGSEGV`, not measured for
  best latency/accuracy. Too small garbles (Whisper lesson — re-test for CTC);
  too large reintroduces lag and memory pressure.
- **How:** sweep {4, 6, 8} s on device, logging RTF, peak memory, and word
  accuracy vs the Gate-0 reference text. Keep the smallest size that stays stable
  and accurate.
- **Verification:** no `SIGSEGV`, RTF < 0.1, transcription matches Gate-0
  (alef-insensitive) across the sweep.

### 2.3 Keep the metadata/tokens tools in the model-prep flow
- **Priority:** P1
- **What:** Treat `tools/asr/fix_tokens_blank.py` as a **required** post-download
  step and `tools/asr/add_sherpa_metadata.py` as a documented fallback.
- **Why:** The model is re-downloadable; the missing `<blk>` will recur on every
  fresh download. Metadata is present today but a re-export could drop it.
- **How:** add a one-line model-prep README/script that runs the tokens fixer
  automatically after download; CI/dev-setup note in `CLAUDE.md` (already
  documented).
- **Verification:** running the prep step twice is a no-op (idempotent) and
  sherpa loads without complaint.

---

## 3. Gate 1 → Phase 2 Path

### 3.1 Get a clean chunked transcription (the gate)
- **Priority:** P0
- **What:** Run `flutter run -t lib/dev/gate1_main.dart` on device after
  `python3 tools/asr/fix_tokens_blank.py assets/models/tarteel/tokens.txt`.
- **Why:** Phase 2 must not start until the model proves it transcribes cleanly
  on hardware.
- **How / report back:** per-chunk text + RTF, and any `[GATE1]` logcat lines.
  Compare concatenated text to the Gate-0 PC output (alef-insensitive).
- **Verification:** chunked decode completes with no native crash and text
  matches Gate-0.

### 3.2 If it still crashes or degrades
- **Priority:** P0 (contingent)
- **Recommendation order:**
  1. If a **catchable** Dart error: the harness already falls back to a fresh
     recognizer per chunk — capture which variant worked.
  2. If a **native SIGSEGV** persists even at 8 s: drop chunk size to 4 s and
     retry; if still crashing, switch the Gate-1 probe to the **streaming
     `OnlineRecognizer`** path (which never does a long single-pass decode).
  3. Only if both fail: fall back to raw `onnxruntime` (last resort, reintroduces
     hand-written DSP risk — avoid unless forced).

### 3.3 `SherpaOnnxAsrService` design
- **Priority:** P1
- **What:** Implement the core `AsrService` contract (`start/pause/resume/
  flush/stop`) backed by sherpa, on a **persistent background isolate**.
- **Why:** Running ASR on the main isolate blocks the mic and the UI (a known
  prior bug). The contract already exists and is exercised by `FakeAsrService`.
- **How:**
  - Reuse the existing isolate/chunking architecture from
    `tarteel_asr_service.dart` (device-tuned — copy the pattern, don't re-derive
    the constants), swapping the Whisper recognizer for the NeMo-CTC recognizer.
  - Map sherpa results to `AsrResult(text, confidence)`; preserve the
    `isFailure` semantics (empty/whitespace or confidence 0 = silent non-result,
    must not reach the engine).
  - Honor the locked capture lessons: stop recorder before setting `_paused`;
    explicit final flush; 0.6 s overlap; skip <0.2 s segments; watchdog.
- **Verification:** mic stays responsive (no dropped frames), capture-audit
  counters show zero loss, and a scripted session matches expected words.

### 3.4 Provider wiring behind a flag
- **Priority:** P1
- **What:** Bind `SherpaOnnxAsrService` at the `asrServiceProvider` swap point,
  selected by a flag (extend `env.dart`), keeping `FakeAsrService` for tests and
  `GroqAsrService` as the debug fallback.
- **Why:** Tests must never touch the mic/model; flags let us A/B the backend.
- **How:** add e.g. `kAsrBackend` enum {fake, onDeviceNemo, cloudGroq}; default
  tests override the provider with the fake (existing pattern).
- **Verification:** all 112 core tests still pass; app boots with the fake when
  the model asset is absent.

---

## 4. Audio Capture & VAD

### 4.1 Revert thread count
- **Priority:** P1
- **What:** Set `_kMaxRecognizerThreads = 4` (currently 6).
- **Why:** 6 measurably regressed (1.4–2.6 s decode) due to big.LITTLE
  contention — documented in the journey.
- **How:** one-line change; **re-measure** decode time at 4 to confirm the win
  before locking it.
- **Verification:** on-device decode time at 4 < at 6, on the device of record.

### 4.2 Keep capture-audit counters in production (behind debug)
- **Priority:** P2
- **What:** Keep the `vadSamples` / segment counters available via a debug
  surface.
- **Why:** Audio-loss bugs are silent and brutal to diagnose after the fact.
- **How:** expose counters in a hidden debug screen or log line gated by
  `kDebugMode`.
- **Verification:** counters reconcile (captured == fed to VAD) across a session.

### 4.3 Re-test VAD constants for the CTC model
- **Priority:** P2
- **What:** Re-validate `_kMaxSpeechDuration`, `_kMinSilenceDuration`,
  `_kVadThreshold` against FastConformer-CTC (they were tuned for Whisper).
- **Why:** CTC's short-utterance tolerance differs from Whisper's; the 2 s
  garbling that forced 3.0 s may not apply.
- **How:** measurement tool + human runs; sweep and record accuracy/latency.
- **Verification:** **UNVERIFIED — needs device test**; keep current values until
  measured.

---

## 5. Matching Engine & Classification

### 5.1 Adopt `fittingAlign` in the controller
- **Priority:** P1
- **What:** Use `fittingAlign` as the alignment backbone at the existing
  `matchUtterance` / `findBestAnchor` seam — **show the diff at that seam before
  finalizing**.
- **Why:** Phase 1 added it as a pure, tested module precisely so the controller
  can adopt it without re-deriving alignment; it gives per-word matched/
  substituted/omitted/inserted + an index map.
- **How:**
  - Feed recognized words (normalized) + the expected-word scope into
    `fittingAlignScope`; map results onto the existing error taxonomy.
  - Preserve **all locked decisions**: longest-correct-prefix, context replay
    not an error, `forget` only from the controller, `asrLag` excluded.
  - Do **not** rewrite the tested `matchUtterance`/`findBestAnchor` wholesale —
    integrate at the seam and keep the 112 tests green.
- **Verification:** existing engine tests pass; add alignment-backed cases for
  the Gate-0 slips (e.g. فويت/فبهت, لم يتسنه/لم يتسم).

### 5.2 Replace `UniformForcedAligner` with real CTC Viterbi
- **Priority:** P2 (Phase 2+)
- **What:** Implement `ForcedAligner` over the model's per-frame CTC output
  (Viterbi), replacing the in-memory uniform fake.
- **Why:** Real per-word timing enables accurate reveal, GOP scoring, and
  pronunciation classification later.
- **How:** port the model card's `ctc_forced_align` to Dart; keep it behind the
  existing `ForcedAligner` interface so nothing upstream changes.
- **Verification:** spans are monotonic/non-overlapping and align with audible
  word boundaries on a known clip.

### 5.3 Prefer GOP-based classification where available
- **Priority:** P2 (Phase 4)
- **What:** When the GOP/pronunciation head is wired, prefer GOP-based
  classification over the attempt-ladder, keeping `asrLag` handling.
- **Why:** Locked direction in `CLAUDE.md`; more accurate pronunciation flags.
- **Verification:** pronunciation flags correlate with human judgement on a
  labeled set.

---

## 6. Mushaf Rendering

### 6.1 Keep Skia for text; revisit Impeller only with measurement
- **Priority:** P1 (keep current)
- **What:** Keep `EnableImpeller=false` (Skia) until Impeller text raster is
  measured faster on the device of record.
- **Why:** Skia dropped raster from 40–160 ms to ~30 ms; Impeller is deprecated-
  warned but the win is measured.
- **How:** if revisiting, A/B raster ms with `FrameTimingProbe` before switching.
- **Verification:** swipe raster stays ≤ ~30 ms/frame.

### 6.2 Keep QCF V2 + startup font preload
- **Priority:** P1 (keep current)
- **What:** Keep per-page QCF V2 fonts with `PageFontLoader.preloadAll` at
  startup; do **not** fall back to a single font.
- **Why:** Locked decision; PUA reuse per page makes per-page fonts necessary;
  preload removes the systemFonts storm.
- **How:** ensure preload covers the pages in range; precache ±2 around current.
- **Verification:** no font-ready rebuild storms; build time stays low on swipe.

### 6.3 Static read path stays single-Text-per-line
- **Priority:** P1 (keep current)
- **What:** Keep measuring each line as one `Text` in the non-interactive path.
- **Why:** Per-glyph `TextPainter` measurement was a primary build-bound cost.
- **Verification:** build-bound time stays well under the previous 500–900 ms.

---

## 7. Fonts & Assets

### 7.1 Validate fonts with HarfBuzz, never a naive preview
- **Priority:** P1 (process)
- **What:** Any future font check must use a HarfBuzz/raqm shaper.
- **Why:** The "dropped alef" was a preview-tool artifact; KFGQPC Uthman Taha
  Naskh is correct.
- **Verification:** zero `.notdef` on a representative ayah set.

### 7.2 Write PUA-bearing files via escapes
- **Priority:** P2 (process)
- **What:** When generating files containing PUA glyphs, write them as escapes
  (e.g. ``) via a script, not literal characters.
- **Why:** Literal PUA was stripped on write.
- **Verification:** round-trip the file and confirm the codepoint survives.

### 7.3 Asset versioning
- **Priority:** P2
- **What:** Add a lightweight version/manifest for bundled model + fonts + decor
  so updates are detectable and reproducible.
- **Why:** Model/fonts are gitignored and re-downloadable; without a manifest,
  drift is invisible.
- **How:** a small `assets/manifest.json` with file + sha256 + version, checked
  at startup in debug.
- **Verification:** mismatched/missing assets are reported, not silently fallen
  back.

---

## 8. Build / Tooling / Infrastructure

### 8.1 Automate model prep
- **Priority:** P1
- **What:** A single `tools/asr/prepare_model.sh` that (after the human
  downloads from HF) runs `fix_tokens_blank.py` and verifies metadata, failing
  loudly if either is wrong.
- **Why:** Removes the manual step that blocked Gate 1.
- **Verification:** idempotent; exits non-zero on a malformed tokens/model.

### 8.2 Document the firewall reality in onboarding
- **Priority:** P2
- **What:** Note in `README`/`CLAUDE.md` that HF is firewalled in the dev/CI
  sandbox, so model assets must be supplied by the human and gates run on device.
- **Why:** Prevents future sessions from assuming they can download the model.

### 8.3 Keep Gradle JVM caps
- **Priority:** P2 (keep current)
- **What:** Keep `-Xmx3G -XX:MaxMetaspaceSize=1G`; edit `gradle.properties` with
  a real editor (not Notepad).
- **Why:** Prevents Gradle OOM and the line-merge corruption.

---

## 9. Testing & Measurement Discipline

### 9.1 Tests first, keep the 112 green
- **Priority:** P0 (always)
- **What:** Write tests before implementation for every core change; never let
  the core suite regress.
- **How:** `dart test` in `packages/quran_tasmee3_core` must stay green; add
  cases drawn from real device output (Gate-0 slips).

### 9.2 Build the measurement probe first
- **Priority:** P1
- **What:** Before touching latency-sensitive code, ship a probe that logs
  **RTF per utterance**, time-to-first-word, and reveal lag, plus a counter
  surface.
- **Why:** We must never guess constants; the human is the sensor.
- **How:** extend `lib/app/perf.dart` (`FrameTimingProbe` pattern) with an ASR
  probe; emit one log line per utterance.
- **Verification:** numbers appear in logcat and inform every subsequent tuning.

### 9.3 Mark every unmeasured constant
- **Priority:** P0 (always)
- **What:** Any numeric not measured on device gets `// UNVERIFIED — needs device
  test`.
- **Why:** Prevents guessed values from masquerading as tuned ones.

---

## 10. Process Guardrails

These are the rules that, in hindsight, would have saved the most time:

1. **Architecture before tuning.** If a structural constraint (e.g. batch vs
   streaming) is the bottleneck, change the architecture; don't burn days on
   constants.
2. **The human is the sensor.** No mic/device/network in dev — write a tool, let
   the human run it, report numbers back.
3. **Don't rewrite working tested code.** Extend via pure layers and seams.
4. **Reproducible over manual.** Every asset/model fix is an idempotent script.
5. **Suspect the tool before the asset/font.** Verify with a correct renderer.
6. **Verify API surface against the installed package version**, not memory.
7. **Pre-call logging across FFI** — native faults are uncatchable; log before
   the call so the crash site is named in logcat.
8. **Measure each performance layer separately** (build-bound vs raster-bound).
9. **Confirm, don't predict.** (We predicted missing ONNX metadata; it was
   present. The harness that surfaced the real error verbatim was what helped.)

---

## 11. Suggested Roadmap (ordered)

1. **(P0)** Run `fix_tokens_blank.py`, get a clean chunked Gate-1 transcription
   on device; report text + RTF. → unblocks Phase 2.
2. **(P0)** Decide streaming vs offline-chunked from measured Gate-1 numbers.
3. **(P1)** Ship the ASR measurement probe (§9.2).
4. **(P1)** Build `SherpaOnnxAsrService` on a background isolate (§3.3); wire
   behind a flag (§3.4); keep 112 tests green.
5. **(P1)** Revert threads to 4 and re-measure (§4.1).
6. **(P1)** Adopt `fittingAlign` at the engine seam, diff-reviewed (§5.1).
7. **(P2)** Tune chunk size/overlap and VAD constants on device (§2.2, §4.3).
8. **(P2)** Real CTC Viterbi `ForcedAligner` (§5.2).
9. **(P2)** Asset versioning + model-prep automation (§7.3, §8.1).
10. **(P2/Phase 4)** GOP-based pronunciation classification (§5.3).
