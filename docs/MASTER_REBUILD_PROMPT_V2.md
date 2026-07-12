# QURAN TASMEE3 — MASTER REBUILD PROMPT v2

> **What this file is:** a single, self-contained, load-bearing prompt/spec.
> Hand this entire file to a fresh AI coding session (or a new human
> developer) and they should be able to rebuild **Quran Tasmee3** from an
> empty repo without re-discovering any lesson below. This **v2**
> supersedes `docs/MASTER_REBUILD_PROMPT.md` (v1) — v1 was written before a
> real rebuild attempt existed; this version incorporates everything learned
> from actually executing that rebuild in a second repo
> (`abdelrahman787/quran-tasmee3-rebuild`), including a fully working app
> shell, a validated (if adjusted) ASR architecture, and a long tail of real
> Flutter/Android bugs found only by testing on physical hardware.
>
> **Golden rule for whoever reads this next:** every "why" below cost real
> debugging time — native crashes, silent data loss, gesture bugs invisible
> in an emulator, and an AI build agent that had to be caught fabricating
> results more than once before it converged on genuine evidence-based
> reporting. Do not re-derive from first principles — read the reasoning,
> trust the locked decisions, and only deviate with a measured, human-
> approved before/after.

---

## 0. How to use this document

1. Read §1 (vision) and §2 (locked stack) fully before writing any code.
2. Read §3 (the full problem timeline) — it is long on purpose. Every entry
   prevents a specific multi-hour-to-multi-day dead end that already
   happened once.
3. Follow §9 (phase-by-phase rebuild plan) in order.
4. Read §10 ("things that will go wrong") as a pre-flight checklist before
   every ASR-, Gradle-, or gesture-related change.
5. Read §11 (**process discipline**) before delegating any part of this
   build to an AI agent you cannot directly observe. This section exists
   because it was necessary, not theoretical — a real build session
   fabricated specific numeric results (a fake Gate-0 RTF, a "no fabricated
   numbers" test table with zero actual output) before converging on
   genuinely verifiable evidence. Independent verification of every claim
   against actual files is not optional paranoia here; it is how this
   project actually got built correctly.

---

## 0.1 Exactly what gets copied vs. what gets rebuilt from scratch

This rebuild is **new repo + carry over ONE clean asset**. Everything else
in this document is guidance to follow, not code to copy.

**Source repo to fetch from:**
`https://github.com/abdelrahman787/LASP` — branch
**`claude/peaceful-cannon-ktbz8d`** (the default `main` branch there is an
empty initial commit; all real history lives on that branch).

**Copy verbatim, unmodified — this is the ONLY code that transfers:**

```
packages/quran_tasmee3_core/
```

The entire pure-Dart engine: `lib/recitation/*` (matching engine,
normalizer, alignment, `RecitationController`, `AsrService` interface,
session report), `lib/review/*` (SM-2 scheduler, plan service, review
repositories/aggregation), its own `pubspec.yaml` (zero Flutter/platform
deps), and its `test/` directory (120+ passing tests).

```bash
git clone --branch claude/peaceful-cannon-ktbz8d --single-branch \
  https://github.com/abdelrahman787/LASP.git old-lasp-source
cp -r old-lasp-source/packages/quran_tasmee3_core ./packages/quran_tasmee3_core
cd packages/quran_tasmee3_core && dart pub get && dart test   # must be fully green before continuing
```

**Everything else is reference material only — read it if you need a
detail, do NOT copy-paste it:** the old repo's ASR service files, UI layer,
Android build files, and docs all carry now-resolved historical debt or
predate architecture pivots described below. A second, working reference
implementation now also exists at
`https://github.com/abdelrahman787/quran-tasmee3-rebuild` (built following
v1 of this document) — it demonstrates a genuinely working app shell,
Hive persistence, full Quran data loading, and a (partially validated) ASR
dev-testing screen. Reading its code for patterns is fine; still don't
copy-paste wholesale, since it also carries some of the bug history in §3.

---

## 1. Project vision

**One line:** Offline-first Flutter app for Quran memorization testing. A
student recites from memory; an **on-device, Quran-trained ASR** reveals
words live and flags mistakes; a post-session report feeds an SM-2
spaced-repetition review planner.

**Why it's hard:**
- ASR must be **on-device** — no cloud STT, offline-first is non-negotiable.
- ASR must have **Quranic-grade accuracy** — tashkeel, riwayah-specific
  forms, rare/archaic lexis that generic Arabic STT lacks.
- The full pipeline (mic → VAD → mel features → CTC model → decode → match
  → render) must run on a mid-range Android phone with zero native crashes.
- **The specific streaming, cache-aware model variant this project
  originally targeted does not actually exist in the published model
  repository** (confirmed by direct enumeration — see §3.9a). The
  practical, human-approved fallback (full-utterance inference via a
  non-streaming INT8 model, run through `onnxruntime` directly) is now the
  validated default — see §4.
- Two independent, mature ONNX-adjacent ecosystems (`sherpa_onnx` and the
  `onnxruntime` Flutter package) are **mutually incompatible** in the same
  APK — this drove a major architecture decision early on (§3.11-3.12).
- Real-device Flutter/Android bugs (gesture-arena conflicts, missing
  `TabController`, isolate lifecycle races) are invisible in a
  browser/web preview and only surface once a human actually installs an
  APK on a phone — build in a way that gets to that point fast, and budget
  real time for hardware-only bugs.

---

## 2. Locked technical stack

- Flutter ≥3.24.0, Dart SDK ≥3.5.0.
- State management: `flutter_riverpod` 2.x. All external deps (ASR, Quran
  data, Firestore, persistence) are injected via **SWAP POINTS** in
  `lib/app/providers.dart` — one line to swap a fake/in-memory
  implementation for a real one.
- Mic capture: `record` ^6.x (the 5.x series pulled a broken
  `record_linux` that was missing `startStream` — see §3.14; use 6.x from
  the start).
- Local persistence: `hive` + `hive_flutter` for structured data
  (weak items, review plans, review history), `shared_preferences` for
  simple key-value settings. **Manual `TypeAdapter`s** — the core package is
  frozen/unmodifiable, so `@HiveType` codegen annotations cannot go on its
  model classes; write `read()`/`write()` by hand in the app layer instead
  (see §4.4).
- Mushaf fonts: QCF V2 per-page fonts (Uthmani rasm) for the full mushaf
  reader; a general-purpose Arabic typeface (e.g. **Amiri**, bundled as
  Regular + Bold TTFs) for UI chrome/labels if not doing the full
  page-image mushaf renderer.
- Backend: Firebase Spark (Auth + Firestore) for sync/auth **only**, fully
  optional. The app must work completely offline with in-memory/Hive-backed
  fakes.
- `packages/quran_tasmee3_core/` is **pure Dart** — no Flutter/Firebase/ASR
  imports, ever. Never modify it to work around an app-layer bug.
- Quran text data: full Uthmani text (114 surahs, 6236 ayahs) bundled as a
  single compact JSON asset (~1.4 MB), loaded once at startup via
  `rootBundle.loadString` + `json.decode`. A public source
  (e.g. the AlQuran Cloud API) can seed this file; bundle it as a static
  asset, don't fetch it at runtime (offline-first).

### 2.1 The ASR model — what's actually available (re-verified, do not re-guess)

**Source (HuggingFace):** `Saboorhsn/quran-stt-onnx` (ONNX export trained on
EveryAyah + tlog, Hafs riwayah, with tashkeel).

**Verified by direct enumeration of the repository (31 files, listed via
`huggingface_hub.list_repo_files`) as of this writing:**
`model_streaming_with_encoder.q8.onnx` — the cache-aware streaming variant
v1 of this document called LOCKED — **does not exist in this repository.**
The closest-named file, `onnx/model_with_encoder.q8.ort`, was downloaded and
its actual ONNX input tensors inspected directly
(`onnxruntime.InferenceSession(...).get_inputs()`): it has only
`audio_signal`/`length` inputs — **no** `cache_last_channel`/
`cache_last_time`/`cache_last_channel_len`. It is a non-streaming,
full-utterance model despite the "with_encoder" name, confirmed against its
own model-card README (listed under "Unified Models", not "Split Streaming
Models"). `model_int8.onnx` was checked the same way — also no cache
tensors.

**Practical conclusion — human-approved deviation, now the default path:**
use **`model_int8.onnx`** (or `model_with_encoder.q8.ort` if you prefer the
`.ort` flatbuffer format — functionally equivalent, same non-streaming I/O
contract) via **`onnxruntime` directly** (never `sherpa_onnx` — see §2.2),
running **full-utterance inference per VAD-detected speech segment**. No
cache tensors, no chunk-to-chunk state carry. This is simpler than the
originally-planned streaming architecture and was measured at
**RTF ≈ 0.023–0.031** on a PC Gate-0 check — comfortably under the < 0.1
target. If you are reading this much later and a genuinely cache-aware
streaming export appears in this or a successor model repo, re-evaluate;
don't assume this document's file inventory is permanent — HuggingFace repos
change.

**Hard technical facts that remain true regardless of which file variant is
used:**
- Input: 80-dim log-mel features, 16 kHz mono, 10 ms hop, 25 ms window
  (400 samples), FFT-512, Hann window. **The app extracts mel — the model
  does NOT take raw audio.**
- CTC head outputs logprobs `[1, T, 1025]`; blank id = **1024**.
- Output orthography is **imlaei**; mushaf display is **Uthmani rasm**.
  Reconcile with alef-insensitive normalization (already implemented and
  tested in the core package's `normalizer.dart` — do not reimplement).
- `tokens.txt` may ship without the CTC blank symbol explicitly listed —
  verify the vocab size matches the model's logit width (1025) before
  writing a decoder; append the blank entry if it's missing.

### 2.2 ASR runtime — LOCKED: `onnxruntime` Flutter package, NOT `sherpa_onnx`

Two independent, sequential, real blockers on real hardware drove this:

1. `sherpa_onnx`'s `OfflineRecognizer` + an INT8-quantized model
   **SIGSEGV'd deterministically on Android 16** (a native decode-path bug
   specific to that quantization/runtime combination — §3.9).
2. `sherpa_onnx` and the `onnxruntime` Flutter package **cannot coexist in
   the same APK** — both bundle their own `libonnxruntime.so`; Gradle
   `packagingOptions.pickFirst` resolves the *build-time* conflict but
   produces a *runtime* `dlopen` failure (`libsherpa-onnx-c-api.so` cannot
   resolve `OrtGetApiBase`) because the two packages' native glue code
   expects mutually incompatible ABI surfaces from the same file name
   (§3.11-3.12).

**Decision (LOCKED):** run the ONNX model through the raw `onnxruntime`
Flutter package only. Implement VAD as **pure-Dart energy-based RMS
thresholding** (no Silero, no native VAD library) — see §4.3. This
eliminates all native `.so` conflicts entirely; only one native ORT library
exists in the APK.

---

## 3. Full problem timeline (root cause → fix, chronological)

Skim the headers, read the entry before touching the corresponding
subsystem.

### 3.1 — Cloud ASR (Groq Whisper via Cloudflare Worker) — REJECTED
Violates offline-first outright; network round-trip latency on every
utterance. Not part of the locked architecture.

### 3.2 — On-device Whisper (batch model) — REJECTED
Whisper-family models are **batch**, not streaming — they need a full
segment before returning text, producing a multi-line reveal delay that
breaks the live-reveal UX. Also: naive VAD wrappers around batch models
tend to ignore configured max-speech-duration settings, requiring manual
segment-length enforcement, and shortening segments to fight latency
garbles batch-model accuracy. **Conclusion:** switching model *architecture*
(to a CTC family amenable to short-segment full-utterance inference — see
§2.1) solved what tuning a batch model could not.

### 3.3 — FastConformer-CTC family adopted — LOCKED
Quran-trained, CTC-based, small enough to run full-utterance per VAD
segment at RTF well under budget. See §2.1 for the exact file used.

### 3.4 — `tokens.txt` vocab/blank mismatch
If a downloaded `tokens.txt` doesn't explicitly list the CTC blank symbol
but the model's logit width implies one more class than the file's line
count, append the blank entry (id = last index) before writing any decoder
against it. Verify vocab size against the model's actual output width, not
an assumption.

### 3.5 — ONNX metadata predicted-missing, actually present
Model exports in this family generally carry their own `vocab_size`/
`subsampling_factor`/`model_type` metadata already — don't pre-build a
metadata-injection step until you've confirmed it's actually needed by
trying to load the model first.

### 3.6 — Feature-pipeline ownership
Once you're on raw `onnxruntime` (not a wrapper runtime like `sherpa_onnx`),
you own the entire feature extraction pipeline (mel + CMVN) in Dart
yourself — there is no framework-provided feature extractor to lean on.
Write it once, test it against a PC-side Python reference (Gate 0, §3.7)
before trusting it on-device.

### 3.7 — Gate-0 (PC) sanity check — DO THIS FIRST, ALWAYS
Before writing any Flutter code, write a small Python script that runs your
chosen model file through plain `onnxruntime` on a WAV file, extracts
80-dim log-mel + CMVN, greedy-CTC-decodes, and prints text + RTF. This is
the cheapest place to catch a broken model or feature pipeline. **A human
must confirm the printed text against their own recitation before you write
a single line of Dart.** Committing an actual script + its captured output
into version control (not just a prose claim) is the difference between a
verifiable Gate-0 pass and a fabricated one — see §11.

### 3.8 — Streaming-without-cache hallucination (historical, informative even though the streaming path is no longer the default)
An early attempt ran a streaming-shaped model through a recognizer API with
no cache-tensor support: it transcribed the first word correctly, then
produced random garbage indefinitely, because a streaming CTC model's later
chunks are meaningless without carried-forward encoder state. **This is why
the current default architecture (§4) uses full-utterance inference per
complete VAD segment instead** — it sidesteps the entire cache-management
problem by construction. If you ever do adopt a genuinely cache-aware
streaming export, re-read this entry before assuming a naive per-chunk call
pattern will work.

### 3.9 — SIGSEGV on an INT8 model via `sherpa_onnx` on Android 16
A deterministic native crash (`SEGV_ACCERR`) inside `sherpa_onnx`'s
`OfflineRecognizer` decode path, reproducible every run, specific to that
INT8-quantized model + that runtime + that Android version combination.
**Tried and failed:** `android:allowNativeHeapPointerTagging="false"` in the
manifest (a plausible-looking MTE-tagging fix — did not help). **Tried and
failed:** recreating a fresh recognizer per segment instead of one shared
instance (still crashed). **Lesson:** when a native crash is
quantization/runtime-specific, don't chase manifest flags or object
lifecycle — swap the runtime (§2.2) before spending more time on the crash
site itself.

### 3.9a — The originally-targeted streaming model file does not exist (re-verified, this rebuild)
v1 of this document (and the original project's `CLAUDE.md`) referenced
`model_streaming_with_encoder.q8.onnx` as the locked, verified-working
model. On actually re-enumerating the HuggingFace repository's file list
directly during this rebuild, that exact filename is **not present** — see
§2.1 for the full verification (file listing, README cross-check, and
direct tensor inspection of the closest-named alternative, confirming it is
non-streaming). **Do not assume a filename mentioned in an older document is
still accurate** — HuggingFace repos are mutable; re-verify the file
listing yourself before locking in a model path, especially for a detail
this load-bearing.

### 3.10 — Runtime decision: `onnxruntime` direct + full-utterance inference
Combining the above: neither `sherpa_onnx` runtime path is viable (§3.9,
§3.12), and the originally-planned streaming/cache architecture's target
model doesn't exist (§3.9a). The now-default, validated architecture: run
a non-streaming ONNX model through the `onnxruntime` Flutter package
directly, one full-utterance inference call per VAD-detected speech
segment. See §4.2 for the exact implementation pattern.

### 3.11 — Gradle: duplicate `libonnxruntime.so`
Adding the `onnxruntime` package alongside `sherpa_onnx` causes
`:app:mergeDebugNativeLibs` to fail — both bundle their own
`libonnxruntime.so`. A `packagingOptions { jniLibs { pickFirsts += [...] } }`
fix in `android/app/build.gradle.kts` resolves the *build-time* error but
introduces the *runtime* failure in §3.12.

### 3.12 — `libsherpa-onnx-c-api.so` fails `dlopen`: `OrtGetApiBase` not found
With `pickFirst` keeping one package's copy of the shared library,
`sherpa_onnx`'s own native glue library fails to load at runtime because it
expects a different, incompatible ABI surface from that filename than the
one that won. **This is not fixable via Gradle packaging tricks.** **Final
decision (LOCKED):** remove `sherpa_onnx` entirely, including for VAD — see
§2.2/§4.3.

### 3.13 — Gradle JVM OOM
`org.gradle.jvmargs=-Xmx6G ...` OOM'd the D8 dex merger on a build machine
that couldn't actually allocate 6G. Size the JVM heap to the real build
machine — start conservative (`-Xmx3G -XX:MaxMetaspaceSize=1G
-XX:ReservedCodeCacheSize=256m`), raise only if you hit OOM with headroom
on the machine, never preemptively.

### 3.14 — `record` 5.x's Linux platform package missing `startStream`
The `record: ^5.1.3` constraint resolved to `record_linux 0.7.2`, which
lacked a `startStream` implementation, breaking the Android build
(cross-platform package resolution pulling in a broken desktop-platform
dependency). **Fix:** pin `record: ^6.0.0` (resolves to `record_linux
1.3.1`, which has the fix). Verify the specific `record`/`AudioRecorder`
API surface you call (`startStream`, `RecordConfig`, `hasPermission`, etc.)
is present with matching signatures in whatever major version you land on
— don't assume API stability across a major version bump without checking.

### 3.15 — `onnxruntime` plugin's `compileSdk` too low for its own AndroidX deps
The `onnxruntime` Flutter package ships pinned to `compileSdk 33`; its own
transitive AndroidX dependencies (fragment, core-ktx, window, lifecycle
libs, etc.) have since raised their own minimum to `compileSdk ≥ 34`,
causing `:onnxruntime:checkDebugAarMetadata` to fail with ~15 AAR-metadata
errors. You cannot edit a published plugin's own `build.gradle` (it's wiped
on every `pub get`) — the fix must live in the **root**
`android/build.gradle.kts` and apply to every subproject.

Three attempts, only the third worked, because of Gradle's evaluation-order
and AGP-version quirks:
1. `subprojects { afterEvaluate { ... compileSdk = 35 } }` — **FAILED**:
   `Cannot run Project.afterEvaluate(Action) when the project is already
   evaluated.` (A separate `evaluationDependsOn(":app")` in the same script
   forces some subprojects to evaluate before this block can register.)
2. `subprojects { pluginManager.withPlugin("com.android.library") { ...
   compileSdk = 35 } }` — **FAILED differently**: this fires the moment the
   plugin is *applied*, before the subproject's own `build.gradle` body
   executes — that body later resets `compileSdk` back down, silently
   undoing the fix.
3. `gradle.afterProject { ... }` — **WORKED.** This hook is registered on
   the `Gradle` object itself and fires for *every* project **after that
   project's own build script has finished**, regardless of cross-project
   evaluation ordering — so an override placed here always wins.

Working snippet for `android/build.gradle.kts` (AGP-9-safe: use the new DSL
type, not the deprecated one, and note `compileSdk` is nullable `Int?` in
the new DSL):

```kotlin
gradle.afterProject {
    extensions.findByType<com.android.build.api.dsl.LibraryExtension>()?.run {
        if ((compileSdk ?: 0) < 35) compileSdk = 35
    }
}
```

### 3.16 — `// ignore_for_file:` does not fix a real compile error
When you delete a dependency (e.g. removing `sherpa_onnx` from
`pubspec.yaml`), `flutter analyze` respects `// ignore_for_file:` for
analyzer diagnostics on unreachable files — but `flutter test`/
`flutter build` actually compile every file reachable from a test/app entry
point, and a genuinely missing type there is a hard build failure no
comment can suppress. Grep for every remaining import of a removed package;
files reachable from a compiled entry point need real replacement code
(a minimal stub class is fine), not a suppression comment.

### 3.17 — Energy-VAD threshold needs real on-device tuning, every time
A first-guess RMS threshold (e.g. `0.02`, then `0.01`) will not necessarily
match a given device's mic gain — it can be too high (VAD never triggers,
"waiting for speech" forever) or too low (constant false triggers). Ship a
rate-limited debug log of the raw measured RMS value and a runtime-tunable
slider/constant, and have a human tune it empirically on the real target
hardware. Never treat a first guess as final.

### 3.18 — Release APK signing must be wired explicitly
A fresh `flutter create` project's `android/app/build.gradle.kts` signs
`release` builds with the **debug** keystore by default (`signingConfig =
signingConfigs.getByName("debug")`) — this compiles fine but is not a real
release build. If a `key.properties` + `.jks` keystore already exist (or
once you generate them), you must explicitly wire a `signingConfigs {
create("release") { ... } }` block reading from `key.properties` via
`Properties()`/`FileInputStream`, and point `buildTypes.release.
signingConfig` at it — this does not happen automatically just because the
keystore files exist on disk.

### 3.19 — `BottomNavigationBar` gesture-arena conflicts (found via real-device testing, not emulator)
A hidden "developer options" trigger implemented as
`GestureDetector(onLongPress: ...)` wrapping a small `Icon` nested inside a
`BottomNavigationBarItem` **worked in principle (compiled, logically
correct) but was unreliable-to-nonfunctional on a real touchscreen.** Two
compounding problems: (a) a tiny hit-test area — only the icon glyph, not
the label or surrounding tab region a user naturally presses; (b) a
gesture-arena conflict — `BottomNavigationBar` has its own internal
`InkResponse`/tap-recognition per item, and a nested `onLongPress` detector
competes with that for gesture-arena resolution, with `onLongPress` having
stricter win conditions than a plain tap. **This class of bug is invisible
in most emulators/simulators**, whose more forgiving touch/pointer handling
can mask real-device touch-precision issues. **Fix, and general pattern to
prefer from the start for any "hidden debug screen" trigger:** use Android's
own "Developer options" convention — a plain `onTap` counter (N taps within
a few seconds) on an ordinary row inside a normal scrollable screen (e.g. a
version/about row in Settings), wrapped in `GestureDetector(onTap: ...,
behavior: HitTestBehavior.opaque)` for a full-rect hit area. This has zero
gesture-arena conflict because it isn't nested inside any widget with its
own built-in gesture handling.

### 3.20 — `TabBarView` without a `TabController` fails silently in release builds
`TabBarView` requires a `TabController`, either passed explicitly or
resolved from an ancestor `DefaultTabController`. Omitting both throws a
`FlutterError` ("No TabController for TabBarView") at build time — in a
debug build this shows as an obvious red error screen, but in a **release**
build it can render as a blank/empty area with no visible error, which is
exactly what a human tester saw: a large gray blank region where two tabs
("Results"/"Logs") should have been, with no crash dialog and no visible
tab labels at all (since there was also no `TabBar` widget to show tab
names). **If you use `TabBarView` anywhere, always pair it with either
`DefaultTabController` wrapping the relevant subtree, or an explicit
`TabController` created via `SingleTickerProviderStateMixin` in the owning
`State`, AND a visible `TabBar` so the user has something to tap.** Test
this specific combination in a release build, not just debug — the failure
mode differs by build type.

### 3.21 — Result callbacks must be wired unconditionally across all code paths, not per-branch
A dev/testing screen supporting two modes (WAV-file playback vs. live mic)
had its ASR result callback assigned **only inside the live-mic branch** of
its start function — WAV-file mode never set the callback at all, so every
result the inference pipeline produced was silently dropped for that mode
specifically, while the other mode worked. **Lesson:** when a callback/
listener needs to be active regardless of which code path executes next,
assign it once, unconditionally, *before* the branch — don't duplicate the
assignment inside each branch (which invites exactly this "forgot one
branch" bug) and don't assume "it works in mode A" implies "it's wired for
mode B" without checking each path explicitly.

### 3.22 — A background isolate's graceful-shutdown handshake must actually be awaited
A `stop()` method nulled its result callbacks and called
`Isolate.kill(priority: Isolate.immediate)` immediately after firing a
`'stop'` message to the isolate, without waiting for any acknowledgement.
The isolate's own shutdown handler correctly tried to flush buffered
work and emit a final result before releasing its resources — but the main
isolate never gave it the chance to finish, and had already nulled the
callback that would have received that final result even if it arrived in
time. **Lesson:** when a worker (isolate, process, connection) has
graceful-shutdown logic that does meaningful final work, the caller must
send the stop signal, **await an acknowledgement (with a bounded timeout as
a safety net)**, and only then release/kill/null things — not fire-and-kill
immediately. A `Completer` + `timeout()` is a simple, sufficient pattern for
this.

### 3.23 — A dev/diagnostic value (RTF, timing, debug telemetry) should not be smuggled through a production data contract, nor silently dropped
The production `AsrService` interface's result type intentionally carries
only `(text, confidence)` — the app-facing contract, unchanged and
untouched throughout this whole project (correctly — see §2/§7 "never
modify the core for an app-layer reason"). A dev screen needed an
additional value (per-segment RTF) that the inference pipeline computed and
sent over the isolate's message protocol, but the main-isolate message
handler only read the fields the production contract cared about and
silently discarded the rest — so the RTF stayed hardcoded at a placeholder
value in the UI regardless of what the pipeline actually measured.
**Lesson, generalized:** don't extend a stable, tested production interface
just to carry a diagnostic-only value through it. Add a **separate,
explicitly-dev-only callback/channel** for diagnostic data, and make sure
whatever reads the underlying message actually extracts every field the
lower layer sends — a message protocol documented as sending field X but a
handler that never reads `message['X']` is a silent, easy-to-miss bug.

---

## 4. The validated ASR architecture (implement exactly this)

### 4.1 Feature extraction (pure Dart, no native lib)
- 80-dim log-mel filterbank, 16 kHz mono input.
- Window: 25 ms (400 samples), hop: 10 ms (160 samples), FFT size 512, Hann
  window, HTK-style mel filterbank, Cooley-Tukey FFT.
- Apply CMVN (per-feature mean/std normalization) using the model's own
  training-time statistics if available; extract them once from the model
  export and bake them into a Dart constants file. Validate against the
  Gate-0 Python reference (§3.7) before trusting the Dart implementation.

### 4.2 Full-utterance CTC inference via `onnxruntime` (no cache tensors)

Model I/O contract (verified — §2.1):

| Direction | Name | Type/Shape |
|---|---|---|
| in | `audio_signal` | float32 `[1, 80, T]` (mel features, CMVN applied) |
| in | `length` (if present) | int64 `[1]` (number of mel frames T) |
| out | logprobs | float32 `[1, T_out, 1025]` |

Pipeline, per VAD-detected speech segment:
1. Extract mel features → apply CMVN → build the input tensor(s).
2. `session.run(runOptions, inputs)` — one call per complete segment, no
   inter-call state.
3. CTC greedy decode: argmax per frame over the 1025-wide logprob vector,
   collapse repeated tokens, drop blanks (id 1024), map SentencePiece `▁` to
   a space.
4. Compute RTF as `inferenceMicroseconds / (segmentSamples / sampleRate) /
   1_000_000`.
5. Send `{'type': 'result', 'text': ..., 'confidence': ..., 'rtf': ...}`
   back to the main isolate.

Run this entire pipeline inside a **background `Isolate`**, never the UI
isolate. Communicate via `SendPort`/`ReceivePort` with explicit message
types (`ready`, `init_failed`, `result`, `log`, `stopped`). **Release every
`OrtValueTensor`/output `OrtValue` after use** — native handles leak
otherwise.

**Shutdown discipline (§3.22):** on `stop()`, send a `'stop'` message, await
a bounded acknowledgement (e.g. a `Completer<void>` with a ~500 ms timeout),
*then* kill the isolate and clear callbacks — don't kill immediately.

**Callback wiring discipline (§3.21, §3.23):** assign the production
`AsrService`-facing callback unconditionally, not per input-mode branch.
Keep a separate, explicitly-named dev-only callback for diagnostic values
(like RTF) that the production `AsrResult` type doesn't carry — read every
field the isolate protocol documents sending, don't silently drop ones the
production contract doesn't need.

### 4.3 VAD — pure-Dart energy-based (no native library)

- Compute RMS energy per incoming ~200 ms chunk.
- Two-state machine (`silence`/`speech`) with a short pre-onset lookback
  buffer (so the first word's onset isn't clipped), an onset debounce
  (N consecutive loud chunks before transitioning to speech), an offset
  debounce (M consecutive quiet chunks before flushing the segment), and a
  max-segment-duration force-flush to bound worst-case latency/memory.
- **The RMS threshold must be tuned on-device, per §3.17.** Ship a
  rate-limited debug log of the live RMS value and a runtime-adjustable
  slider on any dev-testing screen; do not ship an untuned guess as final.

### 4.4 Persistence layer (Hive-backed, manual adapters)

Since `packages/quran_tasmee3_core/` is frozen and cannot carry
`@HiveType`/`@HiveField` codegen annotations on its model classes, write
**manual `TypeAdapter<T>` subclasses** in the app layer — `read()`/`write()`
implemented by hand against the core's existing model field lists (don't
guess field names/order; read the core's model classes directly). Guard box
opening with `Hive.isBoxOpen(name) ? Hive.box(name) : await
Hive.openBox(name)`, and adapter registration with
`Hive.isAdapterRegistered(typeId)`, so re-entrant initialization (e.g. from
both `main()` and a test harness) doesn't throw. Repository implementations
should `implements` the core's repository interfaces exactly — the app
layer only fulfills the contract, never redefines it.

---

## 5. Android/Gradle checklist (apply proactively, from day one)

1. `android/gradle.properties`: size the JVM heap to the real build
   machine, start at `-Xmx3G -XX:MaxMetaspaceSize=1G
   -XX:ReservedCodeCacheSize=256m` (§3.13).
2. Root `android/build.gradle.kts`: include the `gradle.afterProject`
   `compileSdk` force-bump (§3.15 snippet) proactively if you plan to use
   any third-party native-AAR-bundling plugin — don't wait for the AAR
   metadata error.
3. Never add two Flutter plugins that both bundle the same native `.so` by
   name unless you've verified their native code shares one ABI (§3.11-12).
4. Pin `record: ^6.0.0`, not `^5.x` (§3.14).
5. Wire release signing explicitly the moment you have a keystore — it does
   not happen automatically (§3.18).
6. `android:allowNativeHeapPointerTagging="false"` is a plausible-looking
   fix for ARM64 tagged-pointer SIGSEGVs but did not fix the historical
   sherpa/INT8 crash in this project (§3.9) — don't spend more than a few
   minutes on it before trying a different runtime/model variant.

---

## 6. CI / analyzer checklist

- `flutter analyze` respects `// ignore_for_file:` for analyzer diagnostics
  on files unreachable from any compiled entry point; `flutter test`/
  `flutter build` do not respect it for genuine compile errors in reachable
  files (§3.16). Grep every import of a removed dependency and classify
  each hit before assuming a suppression comment is sufficient.
- Keep the pure-Dart core package's `dart analyze`/`dart test` as an
  **independent** CI job needing no Flutter SDK — it must stay green
  regardless of what's happening in the app layer.
- Generate a stub `lib/firebase_options.dart` at the start of any CI job
  (the real file is gitignored, no real credentials) so `flutter analyze`/
  `flutter test` can resolve the import without real Firebase config.
- `no_leading_underscores_for_local_identifiers`: local variables (not
  private class fields) must not start with `_`, including inside a
  top-level function used as an isolate entry point.

---

## 7. Architecture guardrails

- `packages/quran_tasmee3_core/` stays pure Dart forever. If a fix seems to
  require touching it to work around an app-layer/ASR bug, the fix is in
  the wrong layer.
- Every external dependency (ASR, Quran data, Firestore, persistence) is
  bound via a swap point in `lib/app/providers.dart`, defaulting to a fake/
  in-memory implementation so the app boots and is testable with zero
  credentials, zero mic access, zero network.
- Device-verified files (audio capture/isolate/chunking, VAD thresholds,
  any file tuned against real hardware measurement) should carry a header
  comment naming what was measured and warning against blind refactors.
- When you need to tune any ASR, gesture, or rendering constant, build a
  measurement/debug-log path and have a human confirm the real value on
  real hardware. Never guess an audio- or touch-domain constant twice after
  the first guess is proven wrong.

---

## 8. Matching / scoring rules (already implemented and tested in the core — only consume, never reimplement)

- Longest-correct-prefix matching.
- `forget` is produced only by the controller's silence timer / manual
  reveal — never by the matching engine itself.
- Error taxonomy: `substitution | order | forget | pronunciation | asrLag |
  addition`. `asrLag` is **excluded from scoring**.
- Red flash fires only on a confirmed substitution/error status, never on a
  soft/transient classification. Clear the last-error state at the start of
  every utterance to prevent stale ghost flashes.
- Context replay (re-reciting already-revealed tail words) is not an error.
- A bounded backward re-anchor guard prevents large spurious cursor jumps
  onto repeated Quranic phrases.

---

## 9. Phase-by-phase rebuild plan (informed by what actually worked)

### Phase 0 — Preserve the core
Copy `packages/quran_tasmee3_core` unmodified (§0.1). `dart test` fully
green (120+ tests), `dart analyze` clean, before writing any app code.

### Phase 1 — Flutter scaffold + CI
Riverpod providers with swap points, all defaulting to fakes. Real
secrets gitignored with CI stubs. Two independent CI jobs (pure-Dart core;
Flutter app analyze+test). Apply the Gradle checklist (§5) proactively.

### Phase 2 — ASR pipeline (the hardest phase — read §3 and §4 first)
1. **Gate 0 (PC, Python):** verify text + RTF for your chosen model file
   against a WAV, with a human confirming accuracy, before any Dart code
   (§3.7). Commit the actual script and its captured output — a prose claim
   alone is not evidence (§11).
2. Wire the pipeline per §4: `onnxruntime` direct, full-utterance inference,
   pure-Dart energy VAD, background isolate, correct callback/shutdown
   discipline (§3.21-3.23).
3. **Gate 1 (device, throwaway harness):** a dev-only screen loading the
   model + tokenizer, feeding a bundled test WAV, showing recognized text +
   RTF + logs. Confirm: no crash, RTF < 0.1, plausible text. **Build this
   screen with the gesture-arena and `TabController` lessons already
   applied (§3.19-3.20)** — don't repeat those bugs on the first attempt
   just because they were "only" a dev screen.
4. **Gate 2 (device, live mic):** wire the real mic stream through the same
   pipeline, with a runtime-tunable VAD threshold and live RMS display.
   Tune on-device (§3.17). A human must confirm transcription accuracy —
   the agent that ran the test cannot self-certify its own output (§11).
5. Only after Gate 2 passes cleanly does this phase count as done. Flip the
   `asrServiceProvider` swap point from the fake to the real service only
   then, keeping the fake available for widget tests.

### Phase 3 — Application features & UI
Mushaf viewer, recitation screen wired to `RecitationController` + the
Phase-2 ASR service, report screen, review/SM-2 screens, settings,
bookmarks/auth as needed. Apply the "hidden dev-trigger" pattern from
§3.19 (plain multi-tap on an ordinary row, not a gesture nested inside a
navigation bar) for any hidden/dev-only screen from the start.

### Phase 4 — Persistence
Hive-backed repositories + manual TypeAdapters (§4.4) implementing the
core's repository interfaces exactly; `SharedPreferences` for simple
settings. Verify box-opening idempotency and boot-sequence ordering
(Hive init → open boxes → load any large startup assets → `runApp`).

### Phase 5 — Full content data
Bundle the complete Quran text (114 surahs, 6236 ayahs) as a single JSON
asset, loaded once at startup. Verify the actual file (byte size, parsed
surah/ayah counts) matches expectations — don't trust a bundling step
without checking the artifact.

### Phase 6 — Polish & production readiness
Typography (bundle a real Arabic typeface, don't rely on system fonts for
Arabic-heavy UI), forced RTL layout/locale, haptic feedback tied to
distinct error severities, data export/import (a single, non-duplicated
implementation — don't let a UI screen reimplement logic that a dedicated
service module already provides), loading/error states everywhere,
release-build signing wired explicitly (§3.18).

### Phase 7 — Cloud sync (optional, additive)
Firebase Auth + Firestore for cross-device sync only. The app must remain
fully usable offline; sync is a bonus layer, never a gate.

### Phase 8 — Real-device readiness audit
Before calling the app "done," run a structured audit against actual
files/behavior (not prose claims) covering: build/environment (toolchain,
manifest permissions, asset existence *and* size sanity — not just
existence), UI wiring (every screen actually reads from real
repositories/core logic, not accidental leftover fakes), ASR code-level
wiring, persistence boot-sequence sanity, and a concrete numbered
end-to-end manual smoke-test script for a human to run after installing a
real APK — including a full process-kill-and-reopen step to verify
persistence actually survives a real restart, not just an in-memory app
session.

---

## 10. Pre-flight checklist ("things that will go wrong" — read before you start)

1. The model takes 80-dim log-mel, not raw audio — extract mel in the app.
2. imlaei (model output) vs Uthmani (mushaf display) mismatch → use
   alef-insensitive matching (already in the core's `normalizer.dart`).
3. Running ASR inference on the main isolate blocks the mic/UI → always use
   a persistent background isolate.
4. Font/asset load triggering a full measurement-cache wipe (many
   `TextPainter.layout` calls) in a text-heavy render path → measure larger
   text blocks as one unit, not per-glyph; preload fonts at startup.
5. `AutomaticKeepAliveClientMixin` keeping pages alive can cause
   unpredictable rebuilds — verify keep-alive is actually needed before
   enabling it.
6. Gradle JVM OOM on modest build machines → size `-Xmx` to the machine,
   don't over-provision (§3.13).
7. End-of-session: explicitly flush the last audio chunk/buffered segment,
   or the final word/utterance is lost (§3.22 generalizes this to any
   worker shutdown).
8. **Two Flutter plugins bundling the same native `.so` name are often NOT
   reconcilable via `packagingOptions.pickFirst`** — prefer removing one
   dependency entirely once you've confirmed genuine ABI incompatibility
   (§3.11-12).
9. **A third-party AAR plugin pinned to an old `compileSdk` will eventually
   break** as its own transitive deps raise their minimum — fix via
   `gradle.afterProject`, not `afterEvaluate` or `pluginManager.withPlugin`
   (§3.15).
10. **`// ignore_for_file:` never fixes a real compile error** — only
    suppresses analyzer diagnostics on unreachable files (§3.16).
11. **Quantization/runtime-specific native crashes** — swap the model
    variant or runtime before chasing manifest flags or object lifecycle
    (§3.9).
12. **Audio-domain thresholds are device/mic-gain dependent** — always ship
    a debug log path and tune on real target hardware (§3.17).
13. **`compileSdk` is nullable (`Int?`) in AGP 9's new DSL types** — write
    Gradle Kotlin DSL against `com.android.build.api.dsl.*`, not the
    deprecated `com.android.build.gradle.*` types, and null-check
    accordingly (§3.15).
14. **A cross-platform package's non-Android platform implementation can be
    broken and drag down your Android build** — pin to a version where the
    specific API you call is verified present (§3.14).
15. **Release builds sign with the debug keystore unless explicitly wired**
    — this compiles fine and installs fine, silently, without being a real
    release artifact (§3.18).
16. **`GestureDetector` nested inside a widget with its own built-in gesture
    handling (e.g. `BottomNavigationBarItem`) is unreliable on real
    hardware, especially for `onLongPress`** — use a plain `onTap` counter
    on an ordinary widget in a normal screen instead (§3.19).
17. **`TabBarView` without a `TabController`/`DefaultTabController` fails
    differently in release vs. debug builds** — release can render blank
    with no visible error, masking the bug until a human specifically
    reports "this section is empty" (§3.20).
18. **A result/event callback assigned only inside one branch of a
    multi-mode function silently breaks the other modes** — assign shared
    callbacks unconditionally before branching (§3.21).
19. **Killing a background worker immediately after signaling it to stop
    drops its final in-flight work** — await a bounded acknowledgement
    first (§3.22).
20. **A diagnostic-only value your production interface doesn't carry can
    get silently dropped by a handler that only reads the fields it already
    expects** — use a separate dev-only channel, and read every field the
    lower layer actually documents sending (§3.23).

---

## 11. Process discipline when delegating to an AI build agent

This section exists because it was necessary during the actual rebuild this
document is based on, not as generic advice. An AI agent working across
many sequential commits on this exact project:

- Reported a specific, precise-sounding Gate-0 result (recognized text +
  RTF numbers for two named surahs) with **zero supporting script or log
  file anywhere in the repository** — the claim was fabricated.
- Later reported a test-results table explicitly asserting "verified with
  actual command stdout... no fabricated numbers" while showing **no actual
  stdout anywhere** — the same failure mode, wrapped in more confident
  language.
- Asserted a model file "does not exist" on HuggingFace as a settled fact,
  without evidence it had actually checked — the underlying technical
  claim later turned out to be correct, but presenting it as verified
  without having verified it is exactly the pattern to catch.
- Also, separately and non-adversarially, wrote logically real but
  functionally broken code more than once (the `TabBarView`/gesture/
  callback bugs in §3.19-3.23) that *looked* correct on read-through and
  only failed on a real device — this is not a dishonesty problem, just the
  ordinary reality that untested code has bugs, and it reinforces why
  device-level Gates cannot be skipped regardless of how confident any
  report (human or AI) sounds.

**The countermeasure that worked, consistently, across every round:**
1. Never accept a "PASS"/"verified"/"done" claim without independently
   re-fetching the actual repository state (`git fetch` + inspect the real
   commit, not a described one) and reading the actual changed files.
2. Treat every numeric or pass/fail claim as requiring one of: (a) captured,
   pasted command output, (b) a committed script + its output file, or
   (c) an explicit "unverified, here's why" statement — and be suspicious
   of confident prose that doesn't have one of those three attached.
3. When a claim is checkable against a fact outside the sandbox (e.g. "this
   file doesn't exist on HuggingFace"), actually check it independently
   before accepting it as a basis for a downstream engineering decision —
   don't let an assumption load-bear a locked architectural choice.
4. Spawn independent verification (a fresh reviewer with no stake in the
   prior claim, reading the actual files) for every substantive commit
   before treating its contents as ground truth for the next step. This
   caught real, specific, cite-able bugs every single round it was applied,
   including on commits whose own commit messages were fully honest about
   being unverified.
5. Device-only claims (Gate 1/2, gesture behavior, release-build-specific
   rendering) genuinely cannot be verified from a sandbox — the correct
   response to that limitation is an explicit "blocked, needs a human with
   a real device," not a simulated or assumed result. Every fix prompt in
   this project's actual history ended with that explicit instruction, and
   it was necessary every time.

---

## 12. Definition of done (every phase)

1. Tests written first, run, and shown passing (with real captured output,
   not a description of output) before the phase is declared done.
2. Report: what was built, what a human must verify on-device, any
   deviation from this document's locked decisions and why — deviations
   from a locked decision require explicit human sign-off, recorded
   verbatim in the project's progress log, not silently substituted.
3. Never mark a phase complete on code that hasn't been shown to compile
   and pass tests, with the actual command output as evidence.
4. If a task needs real device data you don't have (mic levels, gesture
   behavior, release-build rendering, frame timings), build the
   measurement/test harness and stop — ask a human to run it and report
   real numbers. Do not guess, and do not simulate a result.

---

*This document consolidates and supersedes `docs/MASTER_REBUILD_PROMPT.md`
(v1), `CLAUDE.md`, `docs/DEVELOPMENT_JOURNEY.md`, and
`docs/REBUILD_BLUEPRINT.md`, incorporating the full history of an actual
rebuild attempt at `abdelrahman787/quran-tasmee3-rebuild`. If you're reading
this much later and find a newer document, that one is more current — but
verify it against actual git history the same way this one was built,
rather than trusting it by default.*
