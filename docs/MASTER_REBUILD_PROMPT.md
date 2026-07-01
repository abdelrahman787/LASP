# QURAN TASMEE3 — MASTER REBUILD PROMPT

> **What this file is:** a single, self-contained, load-bearing prompt/spec.
> Hand this entire file to a fresh AI coding session (or a new human developer)
> and they should be able to rebuild **Quran Tasmee3** from an empty repo
> without re-discovering any of the ~30 hard-won lessons below. It supersedes
> and consolidates `CLAUDE.md`, `docs/DEVELOPMENT_JOURNEY.md`, and
> `docs/REBUILD_BLUEPRINT.md` — plus everything learned in the Gate-2
> streaming-ASR session that happened *after* those documents were written.
>
> **Golden rule for whoever reads this next:** every "why" below cost real
> debugging hours (SIGSEGVs, silent hallucination, Gradle OOM, native `.so`
> ABI conflicts). Do not re-derive from first principles — read the reasoning,
> trust the locked decision, and only deviate with a measured on-device
> before/after.

---

## 0. How to use this document

1. Read section 1 (vision) and section 2 (locked stack) fully before writing
   any code.
2. Read section 3 (the full problem timeline) — it is long on purpose. Every
   entry prevents a specific multi-hour dead end.
3. Follow section 9 (phase-by-phase rebuild plan) in order. Do not skip Gate 0
   / Gate 1 / Gate 2 — they exist because skipping verification wasted the
   most time historically.
4. Treat section 8 ("things that will go wrong") as a pre-flight checklist
   before every ASR- or Gradle-related change.

---

## 1. Project vision

**One line:** Offline-first Flutter app for Quran memorization testing. A
student recites from memory; an **on-device, Quran-trained streaming ASR**
reveals words live and flags mistakes; a post-session report feeds an SM-2
spaced-repetition review planner.

**Why it's hard:**
- ASR must be **on-device** (offline-first is non-negotiable) — no cloud STT.
- ASR must be **streaming** (word-by-word reveal) — a batch model creates a
  multi-line reveal delay that makes the "live" UX feel broken, not just slow.
- ASR must be **Quran-trained** — generic Arabic STT lacks tashkeel/riwayah
  accuracy.
- The whole pipeline (mic → VAD → mel features → CTC model → decode → match →
  render) must run on a mid-range Android phone with acceptable latency and
  zero native crashes.
- Two independent, mature ONNX-adjacent ecosystems (`sherpa_onnx` and the
  `onnxruntime` Flutter package) turn out to be **mutually incompatible** in
  the same APK — this single fact drove the biggest architecture pivot of the
  whole project (see §3.9–§3.12).

---

## 2. Locked technical stack (do not substitute without explicit approval)

- Flutter ≥3.24.0, Dart SDK ≥3.5.0.
- State management: `flutter_riverpod` 2.x. All external deps (ASR, Quran
  data, Firestore) are injected via **SWAP POINTS** in `lib/app/providers.dart`
  — one line to swap a fake for a real implementation.
- Mic capture: `record` 7.x, PCM16, 16 kHz mono.
- Mushaf fonts: QCF V2 per-page fonts (Uthmani rasm). Non-commercial,
  charity-only distribution — respect KFGQPC font terms.
- Local DB: `sqflite` for session logs.
- Backend: Firebase Spark (Auth + Firestore) for sync/auth **only**. The app
  works fully offline; there is **no ASR cloud proxy** in scope.
- `packages/quran_tasmee3_core/` is **pure Dart** — no Flutter/Firebase/ASR
  imports, ever. It must run under plain `dart test`. As of this writing it
  has 120+ passing tests and is the single most valuable, least-risky asset
  in the repo. **Never modify it to work around an app-layer bug.**

### 2.1 The ASR model — LOCKED, do not substitute

We use a **Quran-trained FastConformer-CTC** model. NOT Whisper (non-streaming
→ reveal delay), NOT a generic Arabic model (lacks Quranic accuracy).

**Source (HuggingFace):** `Saboorhsn/quran-stt-onnx` (ONNX export of
`Muno459/fastconformer-quran`, trained on EveryAyah + tlog, Hafs riwayah, with
tashkeel).

**Two model variants exist in this export — both were tried, only one survives
on real hardware (see §3.9 for why):**

| File | Type | Verdict |
|---|---|---|
| `onnx/model_int8.onnx` | Offline (non-streaming), INT8 quantized | ❌ **Deterministic native SIGSEGV** on Android 16 inside sherpa-onnx's decode path. Do not use. |
| `model_streaming_with_encoder.q8.onnx` | Streaming, cache-aware, Q8 quantized | ✅ **Works.** Requires manual cache-tensor plumbing (no sherpa `OnlineRecognizer` support for this export shape) — run it via the `onnxruntime` Flutter package directly. |

Also bundle:
- `tokenizer.model` — SentencePiece BPE (vocab 1024).
- `tokens.txt` — token-id → text mapping. **Ships WITHOUT the CTC blank** (see
  §8.3).

**Hard technical facts (trust these, do not re-derive):**
- Input: 80-dim log-mel features, 16 kHz mono, 10 ms hop, 25 ms window
  (400 samples), FFT-512, Hann window. **The app extracts mel — the model does
  NOT take raw audio.**
- CTC head outputs logprobs `[1, T, 1025]`; blank id = **1024**.
- Streaming is cache-aware: carry `cache_last_channel [1,17,70,512]`,
  `cache_last_time [1,17,512,8]`, `cache_last_channel_len [1]` across chunks.
  Forgetting this causes duplicated letters at chunk seams.
- Output orthography is **imlaei**; mushaf display is **Uthmani rasm**.
  Reconcile with alef-insensitive normalization (`normalizer.dart`, already
  implemented and tested — do not reimplement).
- `subsampling_factor = 4` (NOT 8 — a natural-but-wrong guess).
- RTF on Android native ≈ 0.04–0.055 (very fast, confirmed on-device).
- Model metadata (`vocab_size=1025`, `model_type=EncDecCTCModelBPE`,
  `normalize_type=per_feature`, `model_author=nemo`) is **already present** in
  the ONNX export — no metadata injection needed for either variant.

### 2.2 ASR runtime — LOCKED: `onnxruntime` Flutter package, NOT `sherpa_onnx`

This is a **reversal** of an earlier locked decision (`DEVELOPMENT_JOURNEY.md`
§2.3 originally locked `sherpa_onnx`). The reversal happened because of two
independent, sequential blockers found only on real hardware:

1. `sherpa_onnx`'s `OfflineRecognizer` + the INT8 offline model **SIGSEGVs
   deterministically on Android 16** (§3.9).
2. `sherpa_onnx` has no clean `OnlineRecognizer` config for this specific
   streaming export's cache tensor shapes, and even when forced through
   `OfflineRecognizer` without cache, the model **hallucinates after the first
   word** because CTC-streaming models are stateless-per-call without their
   cache (§3.8).

The fix: run `model_streaming_with_encoder.q8.onnx` through the raw
`onnxruntime` Flutter package with **hand-rolled cache plumbing** (see §4 for
the full implementation pattern). This bypasses sherpa's native decode path
entirely — the SIGSEGV never triggers because sherpa's C++ decode function is
never called.

**Corollary (LOCKED, expensive lesson — §3.12):** `sherpa_onnx` and
`onnxruntime` **cannot coexist in the same APK**, even with `pickFirst`
packaging tricks. Both bundle their own `libonnxruntime.so`; whichever one
`pickFirst` keeps, the *other* package's native glue code (`libsherpa-onnx-c-
api.so` expects symbols from sherpa's own ORT build) fails
`dlopen`/`OrtGetApiBase`. **Decision: if you need direct onnxruntime cache
control, remove `sherpa_onnx` entirely** — including VAD. Replace Silero VAD
with a pure-Dart energy-based VAD (RMS thresholding, see §4.3). This is a
clean, dependency-free solution once you accept that Silero's accuracy
improvement wasn't worth a fundamentally fragile packaging story.

---

## 3. Full problem timeline (root cause → fix, chronological)

This section is deliberately exhaustive. Skim the table of contents, but read
the entry before you touch the corresponding subsystem.

### 3.1 — Cloud ASR (Groq Whisper via Cloudflare Worker) — REJECTED
Violates offline-first outright; network round-trip latency on every
utterance. Kept only as a debug fallback behind a flag; out of scope for
production. **Do not resurrect as the primary path.**

### 3.2 — On-device Whisper (sherpa-onnx Whisper + Silero VAD) — REJECTED
Whisper is a **batch** model — it needs a full segment before it returns text.
Result: a ~3-line reveal delay (the student is 3 lines ahead of what the app
has revealed). This is fatal for a *live* reveal UX, not a tuning nuisance.
Also: sherpa's Silero VAD **ignored `maxSpeechDuration`** — segments came out
4–6 s despite a 2–3 s setting; had to manually force-cut via
`vad.isDetected()` + `vad.flush()`. Shortening segments to fight latency
**garbled Whisper's accuracy** (e.g. «ومن سخ» instead of «ما ننسخ»). More
threads (4→6) made decode *slower* due to big.LITTLE core contention.
**Conclusion that mattered:** no amount of tuning removes a structural batch
constraint. Switch the model, don't keep tuning the wrong one.

### 3.3 — FastConformer-CTC adopted (see §2.1) — LOCKED
Streaming + Quran-trained + ONNX-ready. This is the correct model family;
everything downstream (§3.4 onward) is about **how to run it safely**, not
whether to use it.

### 3.4 — `tokens.txt` missing the CTC blank
Downloaded `tokens.txt` has 1024 lines (ids 0–1023) but `vocab_size=1025`; the
blank token (id 1024) is omitted. sherpa refuses to load it: *"We expect that
tokens.txt contains the symbol `<blk>`... and its ID."* **Fix:** an idempotent
script appends `<blk> 1024` (`tools/asr/fix_tokens_blank.py`). Re-run after
every re-download. If you write your own CTC greedy decoder (as the final
architecture does, §4.2), you don't strictly need this fix for the decoder
itself, but keep it for any sherpa-based tooling/back-compat.

### 3.5 — ONNX metadata predicted-missing, actually present
Expected to need `add_sherpa_metadata.py` to inject `vocab_size` /
`subsampling_factor`; the export already carries them. Verified on load:
`subsampling_factor=4`, `vocab_size=1025`, `model_type=EncDecCTCModelBPE`,
`normalize_type=per_feature`, `model_author=nemo`. Don't guess `subsampling_
factor=8` — it's 4.

### 3.6 — `normalize_type` is not Dart-settable
`sherpa_onnx`'s `FeatureConfig` exposes only `{sampleRate, featureDim}` — no
`normalize_type` field. It's read from ONNX metadata by native C++. Not
relevant once you're on raw `onnxruntime` (§2.2) — you own the entire feature
pipeline in Dart and must implement CMVN yourself (see §4.1).

### 3.7 — Gate-0 (PC) passed
A Python script (`tools/asr/gate0_verify.py`) ran `model_int8.onnx` via plain
onnxruntime, extracted 80-dim log-mel, greedy-CTC-decoded, and printed text +
RTF. Confirmed accurate transcription at RTF ≈ 0.055 on the human's own voice.
**Always do this PC-side sanity gate before writing any Flutter code** — it's
the cheapest place to catch a broken model or feature pipeline.

### 3.8 — Streaming model without cache hallucinates after the first word
First device attempt ran `model_streaming_with_encoder.q8.onnx` through
sherpa's `OfflineRecognizer` (no cache support in that API). Result: the
first word transcribed correctly, then the model produced random garbage
text indefinitely. **Root cause:** a streaming CTC model's later chunks are
meaningless without the encoder's carried-forward cache state — treating each
chunk as an independent offline utterance breaks the model's assumptions.
**Fix path:** stop using `OfflineRecognizer` for this model; move to manual
cache-tensor plumbing via raw `onnxruntime` (§4.2).

### 3.9 — SIGSEGV on `model_int8.onnx` via sherpa on Android 16
As a fallback while investigating §3.8, we tried the **offline** INT8 model
through sherpa's `OfflineRecognizer` (no cache needed, so no hallucination
risk). Result: a **deterministic native SIGSEGV** at
`SherpaOnnxDecodeOfflineStream+68` (`SEGV_ACCERR`), reproducible every run,
fault address landing on a tagged pointer (`0xb400...`).
- **Tried and failed:** `android:allowNativeHeapPointerTagging="false"` in
  `AndroidManifest.xml` — did not fix it (MTE tagging control bit stayed `0x1`
  even after the manifest change; this is a red herring, not the real cause).
- **Tried and failed:** "Variant B" — fresh `OfflineRecognizer` per VAD
  segment instead of one shared recognizer across the whole session. Still
  crashed.
- **Actual root cause (best evidence):** the INT8 quantization of this
  specific export triggers a native decode-path bug in sherpa-onnx on Android
  16 specifically. The **Q8** streaming variant does **not** crash under the
  same harness.
- **Lesson:** when a native crash is INT8-specific and quantization-specific,
  don't chase manifest flags or recognizer lifecycle — **swap the model
  variant** and re-test before spending more time on the crash site.

### 3.10 — Decision: onnxruntime direct + Q8 streaming model + rolling cache
Combining §3.8 and §3.9: neither sherpa API variant is viable for this
model family on this device. The fix that actually worked: run
`model_streaming_with_encoder.q8.onnx` through the `onnxruntime` Flutter
package directly, feeding it 200 ms chunks and manually carrying
`cache_last_channel` / `cache_last_time` / `cache_last_channel_len` between
`session.run()` calls (see §4.2 for the exact tensor shapes and I/O
contract). This entirely bypasses sherpa's native decode path — the SIGSEGV
cannot trigger because that code is never called.

### 3.11 — Gradle: duplicate `libonnxruntime.so`
Adding the `onnxruntime` package alongside `sherpa_onnx` (still needed for
VAD at the time) caused `:app:mergeDebugNativeLibs` to fail — both packages
bundle their own `libonnxruntime.so`. **First attempted fix:**
`packagingOptions { jniLibs { pickFirsts += [...] } }` in
`android/app/build.gradle.kts`, picking sherpa's (newer, 1.19.x) copy on the
theory that the ONNX Runtime C API is ABI-stable across versions. **This
fix compiled and built, but broke at runtime** — see §3.12.

### 3.12 — `libsherpa-onnx-c-api.so` fails `dlopen`: `OrtGetApiBase` not found
With `pickFirst` keeping the onnxruntime package's `.so` copy (Gradle
resolves `pickFirst` per-conflict, not per-package, so the "wrong" one for
sherpa's needs can win), `sherpa_onnx`'s own native glue library failed to
load at runtime:
```
Failed to load dynamic library 'libsherpa-onnx-c-api.so': dlopen failed:
cannot locate symbol "OrtGetApiBase" referenced by
".../libsherpa-onnx-c-api.so"
```
**Root cause:** `pickFirst` is a build-time file-selection hack; it cannot
reconcile two native libraries that expect *different, incompatible* ABI
surfaces from the same shared library name. **This is not fixable via Gradle
packaging.** **Final decision (LOCKED, §2.2):** remove `sherpa_onnx` from
`pubspec.yaml` entirely. Only `onnxruntime` remains as a native ORT
dependency → zero conflict, zero `pickFirst` needed. Silero VAD is replaced
by a pure-Dart energy-based VAD (§4.3) — no native library required for VAD
at all.

### 3.13 — Gradle JVM OOM (`-Xmx6G` too high for the build machine)
`android/gradle.properties` had `org.gradle.jvmargs=-Xmx6G ...`; the D8 dex
merger OOM'd (`java.lang.OutOfMemoryError: Java heap space`) because the
build machine couldn't allocate 6G. **Fix:** reduce to
`-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m`. Always size
JVM heap to the actual build machine, not a generous guess — an
over-provisioned request fails harder than a conservative one that merely
runs a bit slower.

### 3.14 — `onnxruntime` plugin's `compileSdk` too low for its own AndroidX deps
Once `onnxruntime` was reintroduced (post §3.12), a *different* Gradle error
appeared: `:onnxruntime:checkDebugAarMetadata` failed with 15 errors, all of
the shape *"Dependency 'androidx.X:Y:Z' requires compileSdk ≥ 34; :onnxruntime
is currently compiled against android-33."* The plugin ships pinned to
`compileSdk 33`; its transitive AndroidX deps (fragment 1.7.1, core-ktx
1.13.1, window 1.2.0, etc.) have since bumped their own minimum. **You cannot
edit the published plugin's `build.gradle` inside `pub-cache`** (it gets
wiped on every `pub get`), so the fix must live in the **root**
`android/build.gradle.kts` and apply to *every* subproject, not just `:app`.

Three fix attempts, in order of what actually worked:

1. **`subprojects { afterEvaluate { ... compileSdk = 35 } }`** — **FAILED**:
   `Cannot run Project.afterEvaluate(Action) when the project is already
   evaluated.` Root cause: the root script has
   `subprojects { project.evaluationDependsOn(":app") }`, which forces `:app`
   (and, transitively, some plugin subprojects) to evaluate *before* our
   `afterEvaluate` block gets a chance to register.
2. **`subprojects { pluginManager.withPlugin("com.android.library") { ... compileSdk = 35 } } }`**
   — **FAILED differently**: this callback fires the moment the
   `com.android.library` plugin is *applied*, which happens **before** the
   subproject's own `build.gradle` body executes. The plugin's own script
   later sets `compileSdk = 33` again, silently overwriting our value — the
   error persisted because our fix ran too early, not too late.
3. **`gradle.afterProject { ... }`** — **WORKED**. This is a hook registered
   on the `Gradle` object itself (not on any one `Project`), and it fires for
   *every* project **after that project's own build script has finished
   executing**, regardless of cross-project `evaluationDependsOn` ordering.
   Because it runs strictly after the subproject sets its own `compileSdk`,
   our override always wins.

Final working snippet for `android/build.gradle.kts`:
```kotlin
// Force every android-library subproject to compileSdk 35 so third-party
// plugins pinned to an older compileSdk don't fail AndroidX AAR metadata
// checks. gradle.afterProject fires AFTER each project's own build script,
// so this always wins regardless of evaluation order.
gradle.afterProject {
    extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.run {
        if ((compileSdk ?: 0) < 35) compileSdk = 35
    }
}
```
Two more traps inside this one fix, both AGP-9-specific:
- **Wrong type import.** `com.android.build.gradle.LibraryExtension` (the old
  DSL type) is deprecated in AGP 9 and is **not** the type Kotlin resolves
  against when `android.newDsl` defaults to true — use
  `com.android.build.api.dsl.LibraryExtension` instead. Using the old type
  produces a "class is deprecated... replaced by..." warning that is actually
  masking a real type mismatch.
- **`compileSdk` is `Int?` in the new DSL**, not `Int`. `if (compileSdk < 35)`
  fails to compile ("Operator call is prohibited on a nullable receiver").
  Use `if ((compileSdk ?: 0) < 35)`.

### 3.15 — `// ignore_for_file:` does not suppress compiler errors
After removing `sherpa_onnx` from `pubspec.yaml` (§3.12), four files still
imported `package:sherpa_onnx/sherpa_onnx.dart`. Adding
`// ignore_for_file: uri_does_not_exist, depend_on_referenced_packages` made
`flutter analyze` pass (these are analyzer diagnostics, and `ignore_for_file`
genuinely suppresses them) — **but `flutter test` still failed** with hard
Dart compiler errors: `'OfflineRecognizer' isn't a type`, `Method not found:
'initBindings'`, etc.
**The distinction that matters:** `flutter analyze` is pure static analysis
and respects `ignore_for_file` for any diagnostic code. `flutter test` /
`flutter build` actually **compile** the code reachable from the test/app
entry point (via the Common Front End) — a genuinely missing type is a hard
build failure there, and no comment can suppress it. Two of the four files
(`sherpa_onnx_asr_service.dart`, `tarteel_asr_service.dart`) were directly
`import`-ed by `providers.dart`, which is reachable from every widget test —
so these **had to be rewritten as real, compiling code** (minimal stub
classes implementing the same interface, throwing `UnsupportedError` at
runtime call sites, since production code no longer uses them). The other
two files (`gate1_asr_check.dart`, `tarteel_cmp.dart`) are dev-only
entry points never imported by anything else — for those, `ignore_for_file`
alone was sufficient because `flutter analyze` still visits every file in
`lib/` even if nothing imports it, but `flutter test`'s compiler never
reaches them.
**Lesson, generalized:** when you delete a dependency, grep for every file
that imports it and classify each import site as (a) reachable from a
compiled entry point → must be replaced with real compiling code, or (b) a
dead/unreachable dev script → `ignore_for_file` is sufficient. Don't assume
one fix covers both cases.

### 3.16 — Energy-VAD threshold needed on-device tuning
After the sherpa removal (§3.12), the pure-Dart energy VAD's initial RMS
threshold (`0.02`, a guess) never triggered on the test device's mic gain —
the UI stayed on "waiting for speech" indefinitely even while reciting aloud.
**Fix:** lowered the starting threshold to `0.005` (still **UNVERIFIED** —
mic gain varies by device) and added rate-limited debug logging
(`dlog('[ASR-vad] RMS=... state=... thresh=...')`, throttled to every 10th
chunk) so the actual RMS levels could be read from `adb logcat` and the
threshold tuned empirically rather than guessed twice. **Lesson repeated from
CLAUDE.md:** *the human is the sensor* — build the measurement/log path and
ask the human to report real numbers; never guess an audio-domain constant a
second time after the first guess is proven wrong.

---

## 4. The final, proven ASR architecture (implement exactly this)

### 4.1 Feature extraction (pure Dart, no native lib)
- 80-dim log-mel filterbank, 16 kHz mono input.
- Window: 25 ms (400 samples), hop: 10 ms (160 samples), FFT size 512, Hann
  window, HTK-style mel filterbank, Cooley-Tukey FFT.
- Apply CMVN (per-feature mean/std normalization) using the model's own
  `clean_mean` / `clean_std` stats — extract these once from the model
  export's `streaming_global_cmvn.npz` (or equivalent) and bake them into a
  Dart constants file (`cmvn_data.dart`). Do **not** compute CMVN stats at
  runtime from the current utterance — the model was trained against the
  export's fixed global stats.

### 4.2 Streaming CTC inference with rolling cache (`onnxruntime` package)

Model I/O contract for `model_streaming_with_encoder.q8.onnx`:

| Direction | Name | Type/Shape |
|---|---|---|
| in | `audio_signal` | float32 `[1, 80, T]` (mel features, CMVN applied) |
| in | `length` | int64 `[1]` (number of mel frames T) |
| in | `cache_last_channel` | float32 `[1, 17, 70, 512]` — zero-init, carried forward |
| in | `cache_last_time` | float32 `[1, 17, 512, 8]` — zero-init, carried forward |
| in | `cache_last_channel_len` | int64 `[1]` — zero-init, carried forward |
| out | `[0]` logprobs | float32 `[1, T_out, 1025]` |
| out | `[1]` encoder_output | (ignored) |
| out | `[2]` encoded_lengths | (ignored) |
| out | `[3]` cache_last_channel_next | float32 `[1, 17, 70, 512]` |
| out | `[4]` cache_last_time_next | float32 `[1, 17, 512, 8]` |
| out | `[5]` cache_last_channel_next_len | int64 `[1]` |

Pipeline, per VAD-detected speech segment:
1. Reset the three cache tensors to zero at the start of every new segment
   (cache state does **not** persist across segments — only across chunks
   *within* one segment).
2. Append ~400 ms of trailing silence to the segment so the CTC head closes
   any open tokens at the tail (without this, the last word is frequently
   truncated/incomplete).
3. Slice the segment into 200 ms chunks (3200 samples @16 kHz).
4. For each chunk: extract mel → apply CMVN → build the 5 input tensors →
   `session.run(OrtRunOptions(), inputs)` → append the returned logprobs to a
   running buffer → copy outputs `[3][4][5]` back into the rolling cache
   variables for the next chunk → **release every `OrtValueTensor` and output
   `OrtValue`** (native handles leak otherwise).
5. After each chunk, optionally run a partial CTC greedy decode over the
   logprobs accumulated so far and emit a live partial-text update.
6. At segment end, run the final CTC greedy decode over the full logprob
   buffer and emit the segment's final text + `audioSec` + `inferMs` (for
   RTF logging).

Run this entire pipeline inside a **background `Isolate`** — never on the UI
isolate. Communicate with the main isolate via `SendPort`/`ReceivePort` with
message types: `ready`, `init_failed`, `partial`, `result`. Copy the raw mic
`Uint8List` PCM16 buffer to the isolate as-is; convert to `Float32List`
inside the worker.

CTC greedy decode: blank id = 1024, argmax per frame over the 1025-wide
logprob vector, collapse repeats, drop blanks, map SentencePiece `▁` to a
space. Load the id→token mapping from `tokens.txt`.

### 4.3 VAD — pure-Dart energy-based (no native library)

Do **not** use Silero VAD / `sherpa_onnx` for VAD (see §3.12 for why they
can't coexist with `onnxruntime` in the same APK). Instead:

- Compute RMS energy per incoming 200 ms chunk:
  `rms = sqrt(mean(sample^2))` over the float32 `[-1, 1]` samples.
- State machine with two states, `silence` and `speech`:
  - In `silence`: maintain a short lookback ring buffer (last ~2 chunks).
    When `voiceOnChunks` (e.g. 2) consecutive chunks exceed the RMS
    threshold, transition to `speech`, and prepend the lookback buffer to the
    speech accumulator (prevents clipping the onset transient of the first
    word).
  - In `speech`: keep accumulating chunks. When `silenceChunks` (e.g. 6)
    consecutive chunks fall below threshold, flush the accumulated buffer as
    one segment and reset to `silence`. Also force-flush if the accumulated
    segment exceeds a max duration (e.g. 5 s) even mid-speech, to bound
    worst-case decode latency and memory.
- **The RMS threshold is device- and mic-gain-dependent and must be tuned
  on-device.** Start conservatively low (e.g. `0.005`), add rate-limited
  debug logging of the live RMS value, and have a human adjust it while
  watching `adb logcat` reciting normally and staying silent, to find a
  threshold that separates the two reliably. Do not ship a guessed value as
  final without at least one on-device confirmation.

### 4.4 Why this specific split (sherpa nowhere, onnxruntime only)

- **No SIGSEGV risk**: sherpa's native decode path (the actual crash site) is
  never invoked.
- **No native `.so` conflicts**: only one package (`onnxruntime`) ships a
  native ORT library; no `pickFirst`, no ABI mismatch possible.
- **Full control over cache plumbing**: the streaming model's cache tensors
  are exactly what caused the hallucination bug when abstracted behind
  `OfflineRecognizer` — owning the tensors directly in Dart makes the
  contract explicit and inspectable.
- **Trade-off accepted**: you lose Silero VAD's noise robustness and must
  hand-tune an energy threshold per device class. This is a real regression
  in VAD quality — if it becomes a problem, consider a small on-device VAD
  model run *through the same onnxruntime session infra* (same package, same
  native lib, no conflict) rather than reintroducing sherpa.

---

## 5. Android/Gradle checklist (apply all of these from day one)

1. `android/gradle.properties`: JVM heap sized to the actual build machine —
   start at `-Xmx3G -XX:MaxMetaspaceSize=1G -XX:ReservedCodeCacheSize=256m`,
   raise only if you hit OOM with room on the machine, not preemptively.
2. Root `android/build.gradle.kts`: include the `gradle.afterProject`
   `compileSdk` force-bump (§3.14 snippet) proactively if you plan to use any
   third-party native-AAR-bundling plugin (ASR runtimes, ML inference, etc.)
   — don't wait for the AAR metadata error to appear.
3. Never add two Flutter plugins that both bundle the same native `.so` by
   name (`libonnxruntime.so`, `libc++_shared.so`, etc.) unless you have
   verified their native code shares one ABI. `packagingOptions.pickFirst`
   silences the *build* error but can produce a *runtime* `dlopen` failure
   that only appears when the picked/dropped library is actually invoked —
   test the full runtime path, not just a successful `assembleDebug`.
4. `AndroidManifest.xml`: `android:allowNativeHeapPointerTagging="false"` is
   a plausible-looking fix for ARM64 tagged-pointer SIGSEGVs but **did not
   fix** the sherpa/INT8 crash in this project — don't spend more than a
   few minutes on it before trying a different model variant or runtime.
5. On Windows dev machines: never edit `gradle.properties` in Notepad (it can
   merge lines); use a real editor.

---

## 6. CI / analyzer checklist

- `flutter analyze --no-fatal-infos` respects `// ignore_for_file:` for
  analyzer diagnostics (`uri_does_not_exist`, `depend_on_referenced_
  packages`, `argument_type_not_assignable`, etc.) on files that are **not**
  reachable from any compiled entry point.
- `flutter test` / `flutter build` do **not** respect `ignore_for_file` for
  genuine compile errors (missing types, methods) in files reachable from the
  test/app import graph. If you remove a package, grep every remaining
  `import` of it and classify each hit: reachable-from-compiled-entry-point
  → rewrite as real compiling code (stub class throwing at runtime is fine);
  dead dev script → `ignore_for_file` is enough.
- `no_leading_underscores_for_local_identifiers`: local variables (not
  private class fields) must not start with `_` — this is a lint the analyzer
  enforces even inside a top-level function body used as an isolate entry
  point.
- CI needs a stub `lib/firebase_options.dart` generated at the start of the
  Flutter job (the real file is gitignored, contains no real credentials) so
  `flutter analyze`/`flutter test` can resolve the import without real
  Firebase config.
- Keep `dart analyze` + `dart test` for `packages/quran_tasmee3_core` as an
  **independent** CI job — it needs no Flutter SDK and must stay green
  regardless of what's happening in the app layer.

---

## 7. Architecture guardrails

- `packages/quran_tasmee3_core/` stays pure Dart forever. If a fix seems to
  require touching it to work around an app-layer/ASR bug, the fix is in the
  wrong layer — put it in the app.
- All external dependencies are bound via swap points in
  `lib/app/providers.dart`. Every provider must have a Fake implementation
  usable in tests without touching mic/network/Firebase.
- Device-verified files (tuned on real hardware) must carry a header comment
  naming the device and warning against blind refactors:
  - `lib/features/recitation/asr_service.dart` (or `streaming_asr_service.
    dart`) — audio capture, isolate, chunking, VAD thresholds.
  - `lib/features/mushaf/mushaf_page_widget.dart` — dual render paths.
  - `lib/features/mushaf/page_font_loader.dart` — font cache behavior.
- When you need to tune any ASR or rendering constant, **write a measurement
  tool and ask the human to run it on-device**. Never guess a number twice.

---

## 8. Matching / scoring rules (LOCKED — implemented and tested in core)

- Longest-correct-prefix matching (an earlier "Rule D" alternative was
  dropped as unnecessarily complex).
- `forget` is produced only by the controller's silence timer / manual
  reveal — **never** by the matching engine itself.
- Error taxonomy: `substitution | order | forget | pronunciation | asrLag |
  addition`. `asrLag` is **excluded from scoring** — it represents ASR
  processing delay, not a user mistake.
- Red flash fires **only** on a confirmed `wrong`/substitution status, never
  on a `soft`/transient classification. Clear `lastError` at the start of
  every utterance to prevent stale ghost flashes.
- Context replay (re-reciting already-revealed tail words) is **not** an
  error.
- A bounded backward re-anchor guard (`kMaxBackwardReanchor`) prevents large
  spurious cursor jumps onto repeated Quranic phrases.
- Prefer GOP-based (pronunciation-scoring) classification over the older
  attempt-ladder heuristic once GOP scoring is available (a later phase);
  keep `asrLag` handling regardless.

---

## 9. Phase-by-phase rebuild plan

### Phase 0 — Preserve the core
- Copy `packages/quran_tasmee3_core` unmodified. Run `dart test` — must be
  fully green (120+ tests) and `dart analyze` clean before writing any app
  code.
- Document its public API (`AsrService` interface, `matchUtterance`,
  `fittingAlign`, `RecitationController`, `SessionReport`, SM-2 scheduler) so
  the app layer only *consumes* it.

### Phase 1 — Flutter scaffold + CI
- New Flutter project wired to the core via a path dependency.
- Riverpod providers with swap points; fakes for ASR/Quran-data/Firestore by
  default so the app boots and is testable with zero credentials.
- `.gitignore` real secrets (`firebase_options.dart`,
  `google-services.json`); CI generates stub versions.
- Two independent GitHub Actions jobs: pure-Dart core (`dart test`), Flutter
  app (`flutter analyze` + `flutter test`).
- Apply the Gradle checklist (§5) proactively, before adding any native
  ML/ASR plugin.

### Phase 2 — ASR pipeline (the hardest phase — follow §3 and §4 exactly)
1. **Gate 0 (PC, Python):** run both model variants
   (`model_int8.onnx` and `model_streaming_with_encoder.q8.onnx`) through
   plain onnxruntime on a WAV file; confirm accurate text + RTF for at least
   one. Do this before writing any Dart.
2. **Decide the runtime up front:** given §3.9–§3.12, go straight to
   `onnxruntime` Flutter package + hand-rolled cache plumbing + pure-Dart
   energy VAD (§4). Do not re-attempt the sherpa `OfflineRecognizer`/
   `OnlineRecognizer` paths for this model family unless a newer sherpa
   release specifically documents cache-tensor support for arbitrary NeMo
   streaming exports.
3. **Gate 1 (device, throwaway harness):** load the model + tokenizer, feed
   a bundled test WAV chunk-by-chunk with correct cache carry, print
   recognized text + RTF to logcat. Confirm no crash, no hallucination,
   RTF < 0.1.
4. **Gate 2 (device, live mic):** wire the mic stream through the energy VAD
   → chunked inference → CTC decode, with a dev screen showing live partial
   text, RTF, and an utterance log. Tune the VAD threshold on-device using
   the RMS debug log (§4.3) until silence reliably stays silent and speech
   reliably triggers within ~1–2 chunks.
5. Only after Gate 2 passes cleanly (correct text, no hallucination during
   pauses, RTF < 0.1) does this phase count as done.

### Phase 3 — Application features & UI
- Mushaf viewer (QCF V2 per-page fonts, preloaded at startup, Skia
  rasterizer not Impeller — see `CLAUDE.md` items on font/render jank).
- Recitation screen wired to `RecitationController` + the ASR service from
  Phase 2, live word coloring per the matching rules in §8.
- Report screen + SM-2 review plan screens from the core's aggregation/
  scheduler modules.
- Settings, bookmarks, auth screens.

### Phase 4 — Cloud sync (optional, additive)
- Firebase Auth + Firestore for cross-device sync only. The app must remain
  fully usable offline/guest-only; sync is a bonus layer, never a gate.

### Phase 5 — Testing, CI hardening, release prep
- Widget tests for key screens using fakes (no real mic/Firebase).
- Signed release build; store listing; privacy disclosure of on-device
  processing.

---

## 10. Pre-flight checklist ("things that will go wrong" — read before you start)

1. The model takes 80-dim log-mel, not raw audio — extract mel in the app.
2. Forgetting to carry the CTC cache + prev-token state across streaming
   chunks → duplicated letters at chunk seams.
3. imlaei (model output) vs Uthmani (mushaf display) mismatch → use
   alef-insensitive matching (already in `normalizer.dart`).
4. Running ASR inference on the main isolate blocks the mic → always use a
   persistent background isolate.
5. Calling `pause()` before setting the `_paused` flag loses in-flight
   samples → stop the recorder first, then set the flag.
6. Font load triggering a full measurement-cache wipe (150+
   `TextPainter.layout` calls) → in the static mushaf render path, measure
   each line as ONE text block, not per-glyph.
7. `AutomaticKeepAliveClientMixin` keeps mushaf pages alive → font-ready
   rebuilds fire unpredictably; turn keep-alive off.
8. Page-swipe stutter from font decompression on the UI thread → defer page
   build during swipe (placeholder, build on settle).
9. Gradle JVM OOM on modest build machines → size `-Xmx` to the machine
   (start at 3G), don't over-provision.
10. Windows Notepad merges lines in `gradle.properties` → use a real editor.
11. End-of-session: explicitly flush the last audio chunk, or the final word
    is lost.
12. **Two Flutter plugins bundling the same native `.so` name are often NOT
    reconcilable via `packagingOptions.pickFirst`** — if their native glue
    code expects different, incompatible symbol sets from that shared
    library, the build succeeds but a runtime `dlopen` fails. Prefer
    removing one dependency entirely over a packaging workaround, once you've
    confirmed (as here) that the two ecosystems are truly incompatible, not
    just accidentally colliding on a file name.
13. **A third-party AAR plugin pinned to an old `compileSdk` will eventually
    break** as its own transitive AndroidX deps raise their minimum. Fix in
    the root `android/build.gradle.kts` via `gradle.afterProject` (not
    `afterEvaluate`, not `pluginManager.withPlugin`) — see §3.14 for the
    exact reasoning and working snippet.
14. **`// ignore_for_file:` never fixes a real compile error** — it only
    suppresses analyzer diagnostics. If deleted-package code is still
    imported by something reachable from `flutter test`/`flutter build`, you
    must delete it or replace it with real, compiling code.
15. **INT8-quantized ONNX models can trigger native crashes that Q8/FP
    variants of the same architecture do not** on specific Android versions
    — if a native SIGSEGV is quantization-specific, swap the model variant
    before spending more time on manifest flags or recognizer lifecycle
    changes.
16. **Audio-domain thresholds (VAD RMS, silence duration, etc.) are
    device/mic-gain dependent** — always ship a debug log path for the raw
    measured value and have a human tune it on the real target hardware; a
    first guess is never the final value.
17. AGP 9's new DSL types are different classes from the old ones
    (`com.android.build.api.dsl.LibraryExtension` vs the deprecated
    `com.android.build.gradle.LibraryExtension`) and some properties that
    used to be non-null (`compileSdk`) are now nullable (`Int?`) — write
    Gradle Kotlin DSL code against the new-DSL types and null-check
    accordingly.

---

## 11. Definition of done (every phase)

1. Tests written first, run, and shown passing before the phase is declared
   done.
2. Report: what was built, what the human must verify on-device, any
   deviation from this document and why.
3. Never mark a phase complete on code that hasn't been shown to compile and
   pass tests in CI.
4. If a task needs real device data you don't have (mic levels, frame
   timings, RTF), build the measurement tool and stop — ask the human to run
   it and report numbers. Do not guess.

---

*This document consolidates and supersedes the reasoning in `CLAUDE.md`,
`docs/DEVELOPMENT_JOURNEY.md`, and `docs/REBUILD_BLUEPRINT.md` as of the
Gate-2 streaming-ASR session. If those documents and this one disagree, this
one is more current — but check git history for anything newer still.*
