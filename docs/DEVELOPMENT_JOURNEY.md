# Quran Tasmee3 — Development Journey: Problems, Models, and Hard-Won Lessons

> A comprehensive engineering log of **every significant problem** we hit while
> building the app, the **root cause** of each, the **fix** we landed on, and
> the **ASR models we tried** (and why we kept or dropped each one).
>
> Purpose: so that nobody — including a future development session — ever
> re-discovers these issues the hard way. `CLAUDE.md` records the *locked
> decisions*; this file records the **reasoning and the failures behind them**.
>
> Device of record for all on-device measurements: **Motorola Edge 50 Fusion,
> Android 16, arm64**. Numbers here came from that device unless noted. Anything
> not yet measured on-device is marked **UNVERIFIED**.

### Table of Contents
1. [Project Overview](#1-project-overview)
2. [The ASR Model Journey (the most important decision)](#2-the-asr-model-journey-the-most-important-decision)
3. [ASR Runtime Problems](#3-asr-runtime-problems)
4. [Audio Capture & VAD Problems](#4-audio-capture--vad-problems)
5. [Matching Engine & Classification Problems](#5-matching-engine--classification-problems)
6. [Mushaf Rendering Problems](#6-mushaf-rendering-problems)
7. [Fonts & Assets Problems](#7-fonts--assets-problems)
8. [Build / Tooling / Infrastructure Problems](#8-build--tooling--infrastructure-problems)
9. [Verification Gates (0 and 1)](#9-verification-gates-0-and-1)
10. [Lessons Learned (Summary)](#10-lessons-learned-summary)
11. [Current Status & What Remains](#11-current-status--what-remains)

---

## 1. Project Overview

**Quran Tasmee3** is an **offline-first Flutter app** for Quran memorization
testing. The student recites from memory; an **on-device ASR** model reveals
words live and flags mistakes; after the session a report feeds an **SM-2**
review planner.

Architecture:
- `packages/quran_tasmee3_core/` — **pure Dart** (no Flutter/Firebase/ASR
  imports). Contains the matching engine, the SM-2 scheduler, the report
  aggregation, and the new `fittingAlign`. Runs under plain `dart test` — **112
  tests** currently pass.
- The Flutter app (repo root) wires the core into Riverpod providers through
  **SWAP POINTS** in `lib/app/providers.dart` — each external dependency (ASR,
  Quran data, Firestore) is behind an interface, bound to a fake by default and
  swapped to a real implementation with a single line.

The single hardest, most time-consuming area was the **ASR model**, covered
first below.

---

## 2. The ASR Model Journey (the most important decision)

We went through three distinct ASR paths. The summary table, then the detail:

| # | Model / Path | Type | Verdict | Reason |
|---|---|---|---|---|
| 1 | **Groq Whisper via Cloudflare Worker** (`GroqAsrService`) | Cloud | ❌ Dropped as primary | Breaks offline-first; network latency; needs connectivity |
| 2 | **On-device Whisper** (`sherpa-onnx` Whisper + Silero VAD) | Local, **batch** | ❌ Dropped | Whisper is non-streaming → 3-line reveal delay; short chunks garble |
| 3 | **FastConformer-CTC** (`Saboorhsn/quran-stt-onnx`) | Local, **streaming**, Quran-trained | ✅ Adopted (LOCKED) | Streaming + Quranic accuracy + ONNX-ready |

### 2.1 Path 1 — Groq Whisper via Cloudflare Worker
- Initial design: the app uploaded captured audio to a Cloudflare Worker
  (`GroqAsrService`) that proxied to Groq's hosted Whisper.
- **Core problem:** it violates the **offline-first** principle entirely and
  adds round-trip network latency on every utterance.
- **Decision:** removed from scope as the primary ASR. It is kept **only as a
  debugging fallback** behind the `kUseRealAsr` flag in `providers.dart`
  (selected when `kUseOnDeviceAsr == false`). The old Worker-based ASR proxy is
  otherwise out of scope.

### 2.2 Path 2 — On-device Whisper (sherpa-onnx) — the "batch" trap
This is where we spent the most time *trying to fix* before concluding the model
itself was the wrong tool. Each problem below is real and was hit in sequence:

- **Whisper is not streaming (batch).** It consumes a full segment and returns
  text. This produced a **~3-line reveal delay**: the student would be three
  lines ahead while the app was still revealing earlier words. For a *live*
  reveal UX this is fatal, not cosmetic.
- **sherpa ignores `maxSpeechDuration`.** We discovered sherpa's Silero VAD does
  **not** honor `maxSpeechDuration` — segments came out **4–6 s** despite the
  value being set to 2–3 s. Fix: a **manual segment cap** — watch
  `vad.isDetected()` and force-cut with `vad.flush()` once detected speech
  exceeds the cap (`maxSegmentSamples = _kMaxSpeechDuration * 16000`).
- **Short segments destroy accuracy.** Dropping segment length to 2 s to reduce
  latency made Whisper garble (e.g. it produced «ومن سخ» instead of «ما ننسخ»).
  We had to raise `_kMaxSpeechDuration` back to **3.0 s** — a **hard,
  unavoidable latency-vs-accuracy tradeoff inherent to a batch model**.
- **More threads did not help.** We raised `_kMaxRecognizerThreads` from 4 → 6
  to speed up decode. Result was **worse** (decode 1.4–2.6 s) due to
  big.LITTLE core contention. Recommendation: revert to 4. (The file currently
  still reads `_kMaxRecognizerThreads = 6` — an open cleanup item.)

**Conclusion:** no amount of tuning removes the structural batch constraint. This
drove the strategic decision to switch to a streaming model.

### 2.3 Path 3 — FastConformer-CTC (adopted, LOCKED)
- **Source:** `Saboorhsn/quran-stt-onnx` (ONNX export of
  `Muno459/fastconformer-quran`; trained on EveryAyah + tlog; Hafs riwayah; with
  tashkeel).
- **Why locked:** it is **streaming** (breaks the batch constraint),
  **Quran-trained** (high Quranic accuracy), and **ONNX-ready**.
- **Hard technical facts** (do not re-derive — from `CLAUDE.md`, confirmed at
  the gates):
  - **Input is 80-dim log-mel, 16 kHz mono, 10 ms hop. The model does NOT take
    raw audio** — features must be extracted.
  - CTC head outputs logprobs `[T, 1025]`; **blank id = 1024**.
  - Streaming is **cache-aware**: you must carry `cache_last_channel` /
    `cache_last_time` **and** the previous-token state across chunks, or you get
    **duplicated letters at chunk seams**.
  - Output orthography is **imlaei**; the mushaf displays **Uthmani rasm** →
    reconcile with **alef-insensitive normalization** (`normalizer.dart`).
  - **`subsampling_factor = 4`** (NOT 8 — a natural-but-wrong guess).
  - RTF on Android ≈ **0.04–0.055** (very fast).
- **Runtime decision (locked): `sherpa_onnx`, not raw `onnxruntime`.** Rationale:
  sherpa does feature extraction (80-dim log-mel), CMVN, and CTC decoding in C++
  matching the model's training, which removes the single highest-risk piece —
  hand-written numeric DSP code. Raw `onnxruntime` is the fallback only if
  sherpa proves incompatible.

### 2.4 Ideas rejected early
- **Generic Arabic ASR models** — rejected: they lack Quranic accuracy
  (tashkeel, riwayah-specific forms, rare/archaic lexis).

---

## 3. ASR Runtime Problems

1. **Model takes log-mel, not raw audio.** A recurring source of failure if
   forgotten — 80-dim mel must be produced (by sherpa's C++ in our chosen
   runtime).
2. **Duplicated letters at chunk seams.** Caused by forgetting to carry the CTC
   cache + previous-token state across streaming chunks. Solution lives in the
   streaming pipeline design (Phase 2+).
3. **Recognition latency made correct words look wrong.** In the old batch
   model, the corrector picked up the "current" word late, so on-time correct
   recitation appeared to be flagged. This was a primary driver of the model
   switch, not just a tuning nuisance.

---

## 4. Audio Capture & VAD Problems

> `lib/app/data/tarteel_asr_service.dart` is **device-tuned**. Do not refactor it
> without a measured before/after on the device of record.

1. **Guarantee zero audio loss.** Added **capture-audit counters** (e.g.
   `vadSamples`) so we can prove every captured sample reached the VAD.
2. **`pause()` was dropping samples.** Setting the `_paused` flag *before*
   stopping the recorder lost in-flight samples. Fix: **stop the recorder first,
   then set the flag.**
3. **Words cut at segment boundaries.** Added a **~0.6 s overlap**
   (`_kSegmentOverlap = 0.6`) at VAD segment boundaries so a word on the seam
   appears whole in at least one of the two adjacent recognizer calls. The
   duplicated overlap text is harmless — the matching engine treats it as a
   context replay, not an error.
4. **Silent freeze / stall.** The session could stall with no indicator. Added a
   **watchdog** (`_kVadWatchdogSeconds = 12.0`) plus a `silentStall` event and a
   `requestAsrReset` event. Recovery uses `flush()` to reset ASR/VAD/decoder
   state **without stopping the mic and without dropping audio**.
5. **sherpa ignoring `maxSpeechDuration`** — see §2.2; manual cap via
   `vad.isDetected()` + `vad.flush()`.
6. **Last word lost at end of session.** Must **explicitly flush** the final
   audio chunk or the last word is dropped.
7. **Junk from tiny segments.** Segments shorter than **0.2 s** are skipped —
   decoding them is wasted work and yields a garbage partial result.

Key device-tuned constants (current values):
- `_kMaxSpeechDuration = 3.0` (2 s was fast but garbled)
- `_kMinSilenceDuration = 0.35`
- `_kVadThreshold = 0.5`
- `_kSegmentOverlap = 0.6`
- `_kVadWatchdogSeconds = 12.0`
- `_kMaxRecognizerThreads = 6` (**should likely be 4** — 6 regressed)
- `_kAsrProvider = 'cpu'`

---

## 5. Matching Engine & Classification Problems

Error taxonomy (`ErrorType`): `forget | substitution | order | pronunciation |
addition | asrLag`. **`asrLag` is excluded from scoring** (it's ASR delay, not a
user mistake).

1. **`asrLag` was masking real substitutions.** Re-anchoring swept substituted
   words into `asrLag` (which is excluded from scoring), hiding genuine
   mistakes. Fix: track `_substitutedWords` and never mask them.
2. **A single substitution never showed in the report.** It was logged as
   `transient` from attempt 1 and disappeared. Fix: log substitution from
   attempt 1 as `soft` so it survives into the report.
3. **False red flash on correctly-said words.** Two causes: (a) a stale
   `_lastError` not cleared on the ASR-failure early returns, and (b) flashing
   on `soft`. Fix: **clear `lastError` at the top of every utterance**, and
   flash **only on a `confirmed` substitution**.
4. **Backward re-anchor jump.** The cursor jumped from index 83 → 15 onto a
   repeated phrase. Fix: a `kMaxBackwardReanchor = 4` guard rejects backward
   jumps larger than the threshold.
5. **Locked matching decisions** (the *why* behind them):
   - **Longest-correct-prefix** matching (Rule D dropped) — simpler, robust.
   - **Context replay is not an error** — re-reciting tail words is normal.
   - **`forget` is produced by the controller's silence timer / manual reveal,
     never by the engine.**
   - **`asrLag` is excluded from scoring**; prefer GOP-based classification
     (later phase) where available.

Tunables (`recitation_config.dart`): `levThreshold` — easy `0.30` / normal
`0.20` / strict `0.10`. Controller thresholds:
`kAsrUnclearThreshold = 3`, `kSilentStallThreshold = 5`,
`kAsrResetStuckMultiplier = 2`, `kMaxBackwardReanchor = 4`.

### 5.1 New alignment layer (`fittingAlign`)
- Added `fittingAlign` (Needleman-Wunsch with a free prefix/suffix gap) as a
  **new pure module** in `packages/quran_tasmee3_core/lib/recitation/
  alignment.dart`, plus a `ForcedAligner` seam (interface + in-memory
  `UniformForcedAligner` fake) for the future CTC Viterbi step.
- **Deviation honored:** it was added **without rewriting** the tested
  `matchUtterance` / `findBestAnchor` (CLAUDE.md: "do not rewrite working tested
  code"). Controller adoption is deferred to Phase 2.
- **A subtle bug found and fixed during development:** a **tie in the free-suffix
  selection** discarded a real trailing match (e.g. "...رب omitted, العالمين
  matched" tied with "insert العالمين + free-skip the rest"). Fixed by favoring
  the **larger end-row on ties**. The gap cost (`_kGapCost = 0.6`) is tuned so
  genuine slips align as substitutions while true garbage is rejected (free-skip
  + inserted) rather than fabricating a spurious aligned span.

---

## 6. Mushaf Rendering Problems

> `lib/features/mushaf/mushaf_page_widget.dart` and `page_font_loader.dart` are
> device-tuned. Do not refactor without measurement.

1. **Page-swipe jank — solved in two layers**, each diagnosed with real
   before/after numbers:
   - **First it was build-bound (500–900 ms/build).** Causes:
     `AutomaticKeepAliveClientMixin` kept pages alive and fired font-ready
     rebuilds unpredictably; a `systemFonts` "storm" (a global re-layout on every
     `FontLoader.load`, ~150 `TextPainter.layout` calls); per-glyph
     `TextPainter` measurement. Fixes: turn keep-alive **off**; measure each
     line as **one single Text** in the static read path
     (`_lineSum10`/`_measureText`/`_staticLine`); **preload all page fonts at
     startup** (`PageFontLoader.preloadAll`, called from `app.dart`).
   - **Then it became raster-bound (~40–160 ms/frame).** Fix: switch the text
     rasterizer from **Impeller to Skia** (`EnableImpeller=false` in
     `AndroidManifest.xml`). Raster dropped to **~30 ms**. (An Impeller
     deprecation warning appears but it works.)
2. **Why each page has its own font (QCF V2).** QCF V2 uses PUA codepoints that
   are **reused per page**, so each page needs its own `QCF_P{page}` font. We
   evaluated unifying to a single font; the **decision was to keep QCF V2** and
   solve performance by preloading all fonts at startup — **not** to fall back to
   a single font.
3. **Garbled glyphs during swipe.** The first `FutureBuilder` frame rendered PUA
   in a fallback font before the correct page font was ready. Fix: a synchronous
   `isLoaded(page)` check that skips rendering the garbled frame.
4. **Swipe stutter from font decompression on the UI thread.** Page build is
   deferred during the swipe (a cream placeholder is shown, the real page builds
   on settle).
5. **Unpredictable rebuilds** from `AutomaticKeepAliveClientMixin` keeping pages
   alive — resolved by `wantKeepAlive = false` plus a deferred-content
   placeholder and a `FrameTimingProbe` (`lib/app/perf.dart`).

---

## 7. Fonts & Assets Problems

1. **"The font is dropping the alef" — it wasn't the font.** The bug was in the
   **preview tool** (`arabic_reshaper`/PIL), not the font. Using a HarfBuzz/raqm
   engine proved **KFGQPC Uthman Taha Naskh is correct** (zero `.notdef`).
   **Lesson:** never judge an Arabic font from a preview tool that doesn't do
   proper shaping.
2. **woff2 → TTF conversion** via fonttools produced
   `UthmanTahaNaskh-Regular.ttf` / `-Bold.ttf`.
3. **A literal PUA character was stripped on write.** Writing a file containing a
   raw PUA glyph dropped it; fix was to write it as an escape (e.g. ``) via
   Python.
4. **Real surah-frame assets wired:** `fatiha_baqarah_frame.webp` (full-page,
   Case B) and `surah_transition_banner.webp` (Case A); ayah-count label
   formatted «وهي ﴿N﴾ آية» using the ornate brackets U+FD3E/U+FD3F and Eastern
   Arabic-Indic numerals, with correct آية/آيات grammar.

---

## 8. Build / Tooling / Infrastructure Problems

1. **`tokens.txt` ships WITHOUT the CTC blank.** The downloaded `tokens.txt` has
   **1024 lines (ids 0–1023)** but the model's `vocab_size = 1025`; the blank
   token (id 1024) is omitted. sherpa refuses to load it: *"We expect that
   tokens.txt contains the symbol `<blk>` or `<eps>` or `<blank>` and its ID."*
   Fix: the **idempotent** tool `tools/asr/fix_tokens_blank.py` appends
   `<blk> 1024` (preserving UTF-8 and the `token id` format), safe to re-run
   after re-downloading. **This was the actual Gate-1 blocker.**
2. **ONNX metadata — we predicted missing, it was already present.** We expected
   sherpa to reject the model for missing `vocab_size` / `subsampling_factor`,
   but the export **already carries the required metadata**: sherpa logs on load
   `subsampling_factor=4`, `vocab_size=1025`, `model_type=EncDecCTCModelBPE`,
   `normalize_type=per_feature`, `model_author=nemo`. So
   `tools/asr/add_sherpa_metadata.py` exists but is a **fallback that is NOT
   needed** for this export.
3. **`normalize_type` is not settable from Dart.** Verified against sherpa_onnx
   1.13.3: `FeatureConfig` has only `{sampleRate, featureDim}` — there is **no**
   `normalize_type` field. The native C++ reads `per_feature` from ONNX
   metadata; Dart cannot (and need not) set it.
4. **HuggingFace is firewalled in the dev sandbox (403).** We cannot download the
   model or read the model card from the build environment. Therefore the Gate-0
   and Gate-1 scripts were written from `CLAUDE.md` specs + standard NeMo
   patterns, and the **human runs them on real hardware**.
5. **Gradle JVM OOM** on low-RAM machines → `-Xmx3G -XX:MaxMetaspaceSize=1G`.
6. **Windows Notepad merges lines** in `gradle.properties` → use a real editor.

---

## 9. Verification Gates (0 and 1)

The project mandates verification gates before committing to the Flutter ASR
pipeline.

### Gate 0 (on PC) — PASSED
- `tools/asr/gate0_verify.py` loads `model_int8.onnx` via onnxruntime, extracts
  80-dim NeMo-style log-mel, greedy-CTC-decodes (blank=1024), detokenizes, and
  prints text + RTF.
- Result: **the model transcribes Quran accurately at RTF ≈ 0.055** (confirmed
  by the human on their own voice).

### Gate 1 (on device) — in progress
- `lib/dev/gate1_main.dart` → `lib/dev/gate1_asr_check.dart`: a throwaway Flutter
  screen that loads the model + tokens in sherpa and transcribes the bundled
  `assets/test_audio/ayah16k.wav`, printing text + RTF or the **verbatim** error.
- Findings so far:
  1. **Model loads** (metadata present, see §8.2).
  2. **First blocker:** missing CTC blank in `tokens.txt` (see §8.1) — fixed by
     `fix_tokens_blank.py`.
  3. **Second problem: `SIGSEGV` on a long single-pass offline decode.** After
     fixing tokens, decoding the **full 104 s clip in one pass** crashed inside
     `SherpaOnnxDecodeOfflineStream` on arm64. The buffer was exonerated
     (sherpa's own `readWave` parsed it cleanly with sane amplitude).
     **Hypothesis:** a long single-pass offline decode overruns phone memory;
     these FastConformer models are tuned for short utterances, and our real
     design streams short chunks anyway.
     **Mitigation in the harness:** probe the **first 8 s**
     (`_kChunkSamples = 16000 * 8`, **UNVERIFIED** chunk size, to be tuned in
     Phase 3); if it transcribes cleanly, loop over the full clip in 8 s
     windows, reusing one recognizer with a fresh stream per chunk, with an
     **automatic fallback** to a fresh recognizer per chunk if a *catchable* Dart
     error occurs.
     **FFI caveat:** a native `SIGSEGV` kills the process before Dart can catch
     it, so the `print('[GATE1] …')` lines emitted *before* each `decode()` are
     the surviving diagnostic in `adb logcat`.
- **Next step:** run the chunked harness on device, report per-chunk text + RTF
  and any `[GATE1]` logcat lines. A clean chunked transcription = Gate 1 passed.

---

## 10. Lessons Learned (Summary)

- **The right model beats tuning.** We tuned a batch model (Whisper) for a long
  time; the structural constraint never yielded. Switching to a streaming model
  (FastConformer-CTC) solved what tuning could not. Architecture > constants.
- **The human is the sensor.** The dev environment has no mic, no device, and no
  HuggingFace/network access. Every latency/RTF/jank number must be **measured on
  device** — we write a measurement tool and the human runs it; we never guess
  constants. Unverified numbers are marked **UNVERIFIED**.
- **Don't rewrite working, tested code.** New capability (`fittingAlign`) was
  added as a pure layer rather than touching the tested matcher.
- **Make operations reproducible.** Model files are re-downloadable, so any fix
  to them must be an **idempotent script**, never a hand edit.
- **Suspect the preview tool before the asset.** The "dropped alef" was a
  preview-rendering artifact, not a font defect.
- **Performance problems have layers.** Swipe jank was build-bound first; after
  fixing that it was raster-bound. Each layer needs its own measured diagnosis.
- **Verify API surface against the installed package.** sherpa field names
  (`feat`, `nemoCtc`) and the absence of a Dart `normalize_type` were confirmed
  by reading the installed `sherpa_onnx 1.13.3` source, not from memory.
- **Native FFI faults are uncatchable.** Pre-call logging is the only diagnostic
  that survives a `SIGSEGV` across the FFI boundary.

---

## 11. Current Status & What Remains

**Done:**
- Pure-Dart core (Phase 1): `fittingAlign` + `ForcedAligner` seam; **112 tests
  passing**.
- Gate 0: passed on PC (accuracy + RTF ≈ 0.055).
- Gate 1: harness + `tokens.txt` fixer + documentation in place; long-decode
  `SIGSEGV` mitigated with chunked decode. Awaiting a clean on-device run.

**Remaining (Phase 2, after Gate 1 passes):**
- Build the real `SherpaOnnxAsrService` (implementing the core `AsrService`
  contract) running on a **background isolate** (never the UI thread).
- Wire it into `providers.dart` at the `asrServiceProvider` swap point, **behind
  a flag** so the fake ASR still works for tests.
- Measurement tooling: log **RTF per utterance** and expose a probe/counter —
  measured, not guessed.
- Connect recognized words to the Phase-1 `fittingAlign` at the existing
  `matchUtterance` / `findBestAnchor` seam (show the diff before finalizing).
- Replace `UniformForcedAligner` with a real CTC Viterbi over model frames;
  remove the Whisper code.

**Open (non-blocking):**
- Revert `_kMaxRecognizerThreads` to **4** (6 regressed).
- Tune the chunk size (`_kChunkSamples`) on device once Gate 1 is green.
- Surah-banner visual polish; an asset versioning/update mechanism.
