# Quran Tasmee3 — Rebuild Blueprint

Comprehensive phase-by-phase documentation for rebuilding the app with a clean
slate, while preserving the battle-tested pure-Dart core.

## Table of Contents
1. [Overview & Principles](#1-overview--principles)
2. [Phase 0 — Preserve the Pure-Dart Core](#2-phase-0--preserve-the-pure-dart-core)
3. [Phase 1 — New Flutter Project & Infrastructure](#3-phase-1--new-flutter-project--infrastructure)
4. [Phase 2 — ASR Pipeline (On-Device Streaming)](#4-phase-2--asr-pipeline-on-device-streaming)
5. [Phase 3 — Application Features & UI](#5-phase-3--application-features--ui)
6. [Phase 4 — Cloud Services & Persistence](#6-phase-4--cloud-services--persistence)
7. [Phase 5 — Testing, CI/CD & Release](#7-phase-5--testing-cicd--release)
8. [Timeline & Milestones](#8-timeline--milestones)
9. [Risk Register](#9-risk-register)
- [Appendix A — Reconciliation with locked facts](#appendix-a--reconciliation-with-locked-facts-editorial)

---

## 1. Overview & Principles

**Goal:** Rebuild the Quran Tasmee3 Flutter application from the ground up,
leveraging the existing `quran_tasmee3_core` package as the unmodified, fully
tested engine. The result will be an offline-first Quran memorization companion
with live, streaming on-device speech recognition that is accurate,
maintainable, and ready for production.

### Core Principles
- **Offline-first:** All critical functionality (ASR, matching, review
  scheduling) works without internet. Cloud features are additive, not essential.
- **Streaming ASR from day one:** We will use a true streaming model
  (FastConformer-CTC with cache) and feed it via a proper stateful
  `OnlineRecognizer`. No batch hacks, no Variant-B chunking.
- **Preserve the core:** `packages/quran_tasmee3_core` remains untouched. Its
  128 tests and architecture (interfaces + swap points) are the unchangeable
  foundation.
- **Measure on real hardware:** Every performance constant (VAD thresholds,
  chunk sizes, RTF) is measured on the target device (Motorola Edge 50 Fusion
  arm64) and marked as `// VERIFIED` before locking. Nothing is guessed.
- **Clean code & secrets hygiene:** Secrets are never committed. UI strings are
  externalized. CI runs real tests.
- **Maintainable architecture:** Clear layer separation (presentation → domain →
  data), dependency injection via Riverpod, and isolated ASR on a background
  isolate.

---

## 2. Phase 0 — Preserve the Pure-Dart Core

**Objective:** Ensure the existing core library is isolated, well-tested, and
easily consumable by the new Flutter app.

### Tasks
- Move `packages/quran_tasmee3_core` to a standalone Git repository or keep it as
  a local package within the new monorepo. It must have zero dependencies on
  Flutter, Firebase, or any ASR library.
- Run full test suite: `dart test` → all 128 tests must pass. `dart analyze` must
  report no issues.
- Pin the version (e.g., `0.9.0`) and publish it as a local path dependency in
  the new app's `pubspec.yaml`.
- Document the public API: `AsrService` interface, `matchUtterance`,
  `findBestAnchor`, `fittingAlign`, normalizer, `RecitationController`, report
  generation, review planner. This document will guide the new integration.

### Do NOT
- Modify any core source files.
- Add or remove tests.
- Change the matching engine, scheduler, or alignment logic.

### Deliverables
- A stable core package with all tests passing.
- API reference for consumption by the new app.

---

## 3. Phase 1 — New Flutter Project & Infrastructure

**Objective:** Set up a clean Flutter project with proper tooling, dependency
injection, localization, and CI/CD from the start.

### Tasks
- Create a new Flutter project (`quran_tasmee3_app`) with a clear folder
  structure:

  ```
  lib/
    app/            # providers, routing, theme
    features/       # feature-based modules (mushaf, recitation, report, plans)
    shared/         # widgets, extensions, constants
    l10n/           # .arb files
  test/
  packages/
    quran_tasmee3_core/   # symlink or submodule
  ```

- **Dependency injection:** Set up Riverpod with code generation
  (`riverpod_annotation`). All external dependencies (ASR, databases, Firebase)
  are injected through providers that can be swapped for fakes in tests.
- **Secrets management:**
  - Add `lib/firebase_options.dart` and `android/app/google-services.json` to
    `.gitignore`.
  - Provide a script to generate them locally (`flutterfire configure`).
  - In CI, inject them as repository secrets.
- **Localization:**
  - Extract all Arabic (and future English) UI strings into `.arb` files
    (`lib/l10n/app_ar.arb`, `app_en.arb`).
  - Use Flutter's `flutter_localizations` and code generation. No hardcoded
    strings in widgets.
- **CI/CD:** Set up GitHub Actions:
  - Core job: `dart test` in `packages/quran_tasmee3_core` on push/PR.
  - Flutter job: `flutter analyze` and `flutter test` (when UI tests are added).
  - Add a job to build Android APK (debug) to verify compilation.
- **Version control:**
  - Initialize a fresh repository with an initial clean commit.
  - Add the core as a submodule (or copy it) — we do NOT carry forward any
    history of the old app's Flutter code.

### Deliverables
- A bootable, empty Flutter app with Riverpod, localization, and CI green.
- Secrets hygiene enforced.
- Core package integrated and tests passing.

---

## 4. Phase 2 — ASR Pipeline (On-Device Streaming)

**Objective:** Implement the definitive on-device ASR pipeline using a true
streaming FastConformer model, stateful decoding, and a finely tuned VAD. This is
the make-or-break phase.

### 4.1 Model Selection & Acquisition
- **Model:** `Muno459/fastconformer-quran-streaming` (or equivalent streaming
  export) with `cache_last_channel` / `cache_last_time` tensors.
- **Tokenizer:** `tokens.txt` with 1025 tokens (include `<blk>` at id 1024).
- **VAD:** Silero VAD (`silero_vad.onnx`).
- All assets must be included in the app bundle or downloaded on first launch
  with clear user feedback. The app must fall back gracefully (e.g., show an
  error screen with a retry/offline message) if assets are missing.

### 4.2 Streaming ASR Service
- Implement a new class `StreamingAsrService` that conforms to the core
  `AsrService` interface (word-by-word emission).
- **Architecture:**
  - Runs on a background isolate (`Isolate.spawn`) to avoid blocking the UI/mic
    thread.
  - Uses one persistent `OnlineRecognizer` from `sherpa_onnx` for the entire
    session.
  - The recognizer's `OnlineStream` is created once and fed sequential audio
    chunks, carrying cache state across chunks (as documented in `CLAUDE.md`).
  - No per-chunk recognizer recreation (no Variant B). The streaming model
    expects continuity; breaking it causes hallucination.
- **Decoding:** After feeding a chunk, call `decode()` and retrieve partial
  result. Use CTC greedy decoding with blank handling.
- **Word emission:** After VAD-determined end of speech, finalize the stream
  segment and push recognized words through the `AsrService` stream.

### 4.3 Audio Capture & VAD Tuning
- **Capture:** 16 kHz mono PCM, continuous stream, no per-file recording. Use
  `record` package with `AudioEncoder.pcm16bits`.
- **VAD:** Apply Silero VAD to the incoming PCM buffer. Segment at natural
  silences.
- **Tunable constants** (to be measured and locked):

  | Constant | Starting value | Rationale |
  |---|---|---|
  | `_kMaxSpeechDuration` | 3.0 s | Avoids long-decodes that caused SIGSEGV. |
  | `_kMinSilenceDuration` | 0.5 s | Short enough to cut at word boundaries, long enough to skip pauses. |
  | `_kVadThreshold` | 0.6 | Reduces false positives from noise. |
  | `_kSegmentOverlap` | 0.0 | No overlap; streaming model carries context internally. |
  | `_kChunkSamples` | 16000 * 3 (3 s) | Feed small chunks to maintain low latency. |
  | `_kNumThreads` | 2 | Keeps CPU usage moderate. |

- **Trailing silence removal:** Before feeding a speech segment to the
  recognizer, trim trailing low-energy frames to prevent CTC hallucination on
  silence.
- **Watchdog:** Implement a stuck-session detector (e.g., 12 s of no output) that
  triggers a soft reset (flush VAD/recognizer without stopping the mic).

### 4.4 Gate 1 — On-Device Verification
Before writing any UI, verify the streaming pipeline on the Motorola device:
- Place assets (`model_int8.onnx`, `tokens.txt`, `silero_vad.onnx`) in the
  correct directory.
- Run a test harness (throwaway screen) that streams from mic, prints recognized
  text and per-chunk RTF to logcat.
- Confirm transcription is clean, no hallucination, no SIGSEGV.
- Measure RTF (must be <0.1) and end-to-end latency (ideally <1 s).
- Lock all constants and mark them `// VERIFIED`.

### Deliverables
- A working, device-tested streaming ASR service.
- Documented, locked constants.
- All UNVERIFIED markers removed.

---

## 5. Phase 3 — Application Features & UI

**Objective:** Build the user-facing features on top of the stable core and ASR
service.

### 5.1 Mushaf Viewer (QCF V2)
- Use QCF V2 per-page fonts (604 fonts). Preload all fonts at app start to
  eliminate jank.
- Render pages using `TextPainter` with line-by-line measurement (no per-glyph
  layout).
- Smooth page swiping via `PageView` with lazy build and rasterization tuning
  (Skia vs Impeller).
- Surah banners and Basmala display.
- Reveal API for controlling word visibility.

### 5.2 Recitation Screen (Live Memorization Test)
- **Controller:** Wire `RecitationController` from the core to the UI via
  Riverpod.
- **ASR integration:** The `StreamingAsrService` feeds recognized words into
  `matchUtterance` / `fittingAlign`.
- **Live word coloring:** Green (correct), red (substitution), orange (order),
  grey (forget). No flash on `asrLag`.
- **Re-anchor recovery:** Use the core's `findBestAnchor` to recover from cursor
  stalls. Bound backward jumps.
- **Session flow:** Start → recite → pause/resume → finish → report.

### 5.3 Report & Review Plans
- Display session report with error breakdown (buckets), score, and per-word
  status.
- Generate SM-2 review plan using the core scheduler. Show due reviews, upcoming,
  and statistics.

### 5.4 Supporting Screens
- Dashboard (home)
- Settings (ASR thresholds, theme, data management)
- Bookmarks
- Authentication (optional, for cloud sync)

### 5.5 Performance & Polish
- Frame timing probes on critical pages.
- Graceful loading/error states everywhere.
- Offline detection and fallback UI.

### Deliverables
- Fully functional, polished app with all core user journeys.
- UI tested on target device (scrolling, ASR latency, rendering).

---

## 6. Phase 4 — Cloud Services & Persistence

**Objective:** Add Firebase Authentication and Firestore synchronization,
ensuring offline-first behavior.

### Tasks
- **Firebase Auth:** Email/password login (plus optional Google sign-in).
  Offline fallback: user can still use app as guest with local-only data.
- **Firestore:** Store user data (sessions, plans, bookmarks) under
  `users/{uid}/`. Use offline persistence and batched writes.
- **Sync logic:** On sign-in, merge local data with cloud using timestamps.
  Resolve conflicts with "last write wins" or user prompt.
- **Security rules:** Ensure only authenticated user can read/write their own
  data.
- **Asset updates:** Mechanism to download updated models/fonts from Firebase
  Storage or a CDN.

### Deliverables
- Cloud sync working without blocking offline usage.
- Robust conflict resolution.

---

## 7. Phase 5 — Testing, CI/CD & Release

**Objective:** Achieve production-level quality and prepare for store submission.

### 7.1 Testing
- **Core:** All 128 tests continue to pass.
- **Unit tests** for new Dart services: ASR text processing, VAD stream
  simulation, Riverpod providers.
- **Widget tests:** Key screens (recitation, mushaf) with fake ASR and core.
- **Integration tests:** (optional) on real device for critical flow: mic → ASR
  → matching → report.

### 7.2 CI/CD
- Expand GitHub Actions:
  - Run core tests and Flutter analyze on each commit.
  - Build signed Android APK/AAB.
  - Run widget tests (using `flutter test`).
  - If applicable, upload to Google Play Console on tags.

### 7.3 Release Preparation
- Privacy policy & data safety: Disclose on-device processing, optional cloud
  sync.
- Splash screen & app icon.
- Store listing (Arabic & English).
- Versioning: Use semantic versioning (`1.0.0`).

### Deliverables
- Signed release build.
- Submitted to Google Play for internal testing.

---

## 8. Timeline & Milestones

| Phase | Duration | Key Outcome |
|---|---|---|
| Phase 0 | 1 day | Core preserved, tests green |
| Phase 1 | 2–3 days | Flutter app booting, CI, locales |
| Phase 2 | 1–2 weeks | Streaming ASR device-verified, constants locked |
| Phase 3 | 2–3 weeks | Full feature set complete, UI polished |
| Phase 4 | 1 week | Cloud sync optional, offline-first intact |
| Phase 5 | 1 week | Testing, store readiness |
| **Total** | **6–8 weeks** | **Production-ready app** |

(Estimates assume one focused developer with prior knowledge of the core and ASR
domain.)

---

## 9. Risk Register

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Streaming model export missing cache tensors | Medium | High | Verify ONNX model metadata before integration; fallback to NVIDIA Hybrid RNNT |
| SIGSEGV on longer utterances | Medium | High | Start with 3 s max speech; increase only after extensive on-device testing |
| Silero VAD inconsistent across phones | Low | Medium | Test on multiple Android devices; expose threshold setting for power users |
| Firebase auth missing while offline | Low | Medium | Guest mode with clear upgrade path; local-only storage until online |
| QCF V2 font rendering performance | Low | Medium | Preload all fonts at startup; use Skia if Impeller deprecated; measure frame times |
| Arabic strings corruption | Low | Medium | Externalize all strings to `.arb` files; enforce UTF-8 in CI checks |

---

**Next Step:** Start Phase 0 immediately — extract and verify the core. Then
proceed to Phase 1 scaffolding. The ASR Phase 2 will be the definitive battle,
but with the correct streaming model and lessons learned, it is entirely
achievable.

*Document version 1.0 · Prepared for the Quran Tasmee3 rebuild initiative · Date: 2026-06-28*

---

## Appendix A — Reconciliation with locked facts (editorial)

> This appendix is **not part of the original blueprint**; it cross-checks the
> plan against the LOCKED facts in `CLAUDE.md` and the current branch state
> (`CODEBASE_ANALYSIS.md`, `DEVELOPMENT_JOURNEY.md`) so no hard-won lesson is
> lost in the rebuild. Resolve these before starting Phase 2.

1. **Streaming model vs the bundled offline model.** The blueprint's Phase 2
   mandates a true `OnlineRecognizer` with a streaming export
   (`fastconformer-quran-streaming`, cache tensors). But §4.4's asset list and
   the *current* verified asset are `model_int8.onnx` — the **offline**
   NeMo-CTC export. `CLAUDE.md` lists the streaming file
   (`model_streaming_with_encoder.q8`) as **OPTIONAL** and not yet verified.
   **Action:** treat "acquire + verify a streaming export with cache tensors" as
   an explicit Phase-2 gate (the Risk Register already flags this as
   Medium/High). If the streaming export proves unavailable/broken, the offline
   model + VAD-segmented decode is the proven fallback — do not delete that path
   until streaming is device-verified.

2. **`subsampling_factor = 4`, not 8.** The model's real metadata (verified on
   load) is `subsampling_factor=4`, `vocab_size=1025`, `model_type=
   EncDecCTCModelBPE`, `normalize_type=per_feature`. Any new metadata/setup code
   must use 4. (A natural guess of 8 is wrong here.)

3. **`tokens.txt` blank token.** The download ships 1024 lines; sherpa needs
   `<blk> 1024` appended. Reuse the idempotent `tools/asr/fix_tokens_blank.py`
   in the new model-prep flow (Phase 0/1), don't re-discover this.

4. **`normalize_type` is not Dart-settable.** `FeatureConfig` exposes only
   `{sampleRate, featureDim}`; `per_feature` is read from ONNX metadata by native
   C++. Don't plan a Dart knob for it.

5. **VAD starting constants conflict with the current live values.** The
   blueprint's starting points (`_kMaxSpeechDuration=3.0`, `_kVadThreshold=0.6`,
   `_kMinSilenceDuration=0.5`, `_kSegmentOverlap=0.0`) are sensible, but the
   *current* live service runs UNVERIFIED `maxSpeech=20.0` / `overlap=0.0`. Start
   the rebuild from the blueprint's conservative 3.0 s (it directly mitigates the
   SIGSEGV), and only raise after on-device measurement.

6. **Confidence proxy.** The current service hardcodes confidence `0.85`. The
   rebuild should derive confidence from the CTC average logprob so downstream
   pronunciation/low-confidence logic is meaningful.

7. **Carry forward, don't re-solve, the matching lessons.** dagger-alef → full
   alef (already in `normalizer.dart`), alef-insensitive matching, bounded order
   look-ahead, cross-bucket dedup, re-anchor forget logging, and un-attempted →
   confirmed-forget injection are all in the preserved core. Phase 3 must wire
   them, not reimplement them.

8. **Secrets & CI are pre-existing debts.** `lib/firebase_options.dart` is
   currently tracked despite being a declared secret, and the existing CI runs
   `dart` at a Flutter root (likely red). Phase 1's secrets/CI tasks should
   explicitly fix both, not just "set up CI" — see `CODEBASE_ANALYSIS.md` §6.1
   and §6.2.
