# Continuation prompt — hand this to the agent working on `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool.

---

You are continuing work on **Quran Tasmee3** in this repo
(`abdelrahman787/quran-tasmee3-rebuild`). An independent review just verified
the current state of the repo against the master spec. Here is exactly where
things stand — trust this, don't re-derive it:

## Verified state (do not redo these)

- **Phase 0 (core package) — DONE.** `packages/quran_tasmee3_core/` was
  copied verbatim from `https://github.com/abdelrahman787/LASP` (branch
  `claude/peaceful-cannon-ktbz8d`) and confirmed byte-identical to the
  upstream source on spot-check. It has zero Flutter/ASR imports. Do not
  modify any file under this directory for any reason — if you think you
  need to, you're solving the problem in the wrong layer.
- **Phase 1 (Riverpod scaffold + swap points) — DONE.** `lib/app/providers.dart`
  has 6 correctly-structured swap points (`asrServiceProvider`,
  `sessionLoggerProvider`, `weakItemRepoProvider`, `planRepoProvider`,
  `reviewHistoryRepoProvider`, `settingsRepoProvider`), each currently bound
  to a Fake/InMemory implementation. `pubspec.yaml` correctly has **no**
  `sherpa_onnx` and **no** `onnxruntime` yet — that's expected, Phase 2
  hasn't started.
- **Phase 3 (UI) — DONE.** All 6 screens exist (home, mushaf, recitation,
  report, review, settings) and a widget test exercises real navigation.
- **Gradle — code is correct, but `PROGRESS.md`'s own documentation of it is
  WRONG.** The actual `android/build.gradle.kts` correctly uses
  `gradle.afterProject { extensions.findByType<com.android.build.api.dsl.LibraryExtension>()... }`
  (the AGP-9-safe, nullable-safe form). But `PROGRESS.md` quotes a *different*,
  broken, deprecated snippet using `com.android.build.gradle.BaseExtension`
  and `compileSdkVersion("android-35")`. **Fix `PROGRESS.md` to match the
  actual working code in `build.gradle.kts`** — do not touch
  `build.gradle.kts` itself, it's already correct.

## What is NOT done — this is your task now

**Phase 2: the real on-device streaming ASR pipeline.** Right now
`lib/services/fake_asr_service.dart` is a `Timer.periodic` returning
scripted words — no model, no mic, no inference. This is honestly
represented in `PROGRESS.md` already (good — keep it that way until it's
genuinely real).

Before writing a single line of Flutter/Dart ASR code, fetch and read the
full spec, section by section, from:
`https://raw.githubusercontent.com/abdelrahman787/LASP/claude/peaceful-cannon-ktbz8d/docs/MASTER_REBUILD_PROMPT.md`

Sections that matter most for what you're about to do: **§2.1, §2.1a, §2.2**
(the locked model + runtime decisions, and WHY every alternative was
rejected), **§3** (the full problem timeline — read every SIGSEGV/hallucination/
Gradle entry so you don't re-trigger a solved bug), **§4** (the exact, proven
architecture: tensor shapes, chunking, cache plumbing, energy VAD state
machine), **§9 Phase 2** (the gate sequence below).

### Do these in strict order — do not skip a gate

1. **Gate 0 (PC, Python, no Flutter):** Get
   `model_streaming_with_encoder.q8.onnx` (source: `Saboorhsn/quran-stt-onnx`
   on HuggingFace) running through plain `onnxruntime` in Python on a WAV
   file. Print recognized text + RTF. **Have a human confirm the transcribed
   text matches their own recitation before proceeding.** This is the
   cheapest place to catch a broken model/feature pipeline — do not skip it
   to save time.
2. **Wire the pipeline in Dart exactly per spec §4** — no sherpa_onnx, ever.
   Locked stack: `onnxruntime` Flutter package only, hand-rolled rolling
   cache (`cache_last_channel [1,17,70,512]`, `cache_last_time [1,17,512,8]`,
   `cache_last_channel_len [1]`), pure-Dart 80-dim log-mel + CMVN feature
   extraction, CTC greedy decode (blank id 1024), and a pure-Dart
   energy-based VAD (RMS thresholding with a lookback buffer — no Silero, no
   native VAD library). Run all of it on a background `Isolate`, never the
   UI isolate. Apply the Gradle checklist (spec §5) proactively — the
   `gradle.afterProject` compileSdk-35 fix is already in place, so once
   `onnxruntime` is added to `pubspec.yaml` this should build cleanly on the
   first try; if `checkDebugAarMetadata` still fails, re-read spec §3.14
   before improvising a new fix.
3. **Gate 1 (device, throwaway harness):** A dev-only screen that loads the
   model + tokenizer, feeds a bundled test WAV chunk-by-chunk with correct
   cache carry, prints recognized text + RTF to logcat. Confirm: no crash, no
   hallucination, RTF < 0.1.
4. **Gate 2 (device, live mic):** Wire the real mic stream through the energy
   VAD → chunked inference → CTC decode, with a dev screen showing live
   partial text, RTF, and an utterance log. **The energy VAD's RMS threshold
   must be tuned on-device** — add rate-limited debug logging of the raw RMS
   value (see spec §3.16/§4.3 for why a first guess is never right — mic
   gain varies by device) and ask the human to report real numbers from
   `adb logcat` while reciting normally and staying silent, so the threshold
   can be set from measurement, not a guess.
5. Only once Gate 2 passes cleanly (correct text, no hallucination during
   pauses, RTF < 0.1, confirmed by the human on real hardware) does Phase 2
   count as done. Then, and only then, flip the `asrServiceProvider` swap
   point in `providers.dart` from `FakeAsrServiceImpl` to the new real
   `StreamingAsrService` — keep the Fake available for tests.

### Constraints that are non-negotiable (from the spec's locked decisions)

- Do not add `sherpa_onnx` to `pubspec.yaml` for any reason (ASR, VAD, or
  otherwise) — it is incompatible with `onnxruntime` in the same APK
  (native `.so` ABI conflict, ~a full day was lost to this in the original
  project; see spec §3.11/§3.12 for the exact failure mode before you
  consider reintroducing it).
- Do not modify anything under `packages/quran_tasmee3_core/`.
- Do not reimplement or duplicate matching/scoring logic in the app layer —
  everything in spec §8 already lives in the core package; only consume it.
- Every ASR/audio constant you tune (VAD threshold, chunk size, silence
  duration) must be justified by an on-device measurement, not a guess left
  unverified. If you don't have a real device to test on, say so explicitly
  and stop at the point that needs device data — don't fabricate a "looks
  reasonable" number and call the phase done.

### Definition of done for this task

Report back with: what was built, the exact Gate-0/1/2 results (including
the human's confirmation of transcription accuracy), any deviation from the
spec and why, and the current state of all tests (`dart test` in the core
package must still be fully green — unchanged from before).
