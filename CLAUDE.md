# CLAUDE.md — Quran Tasmee3

> Read this file fully before touching any code. It encodes locked decisions
> and hard-won lessons from prior development sessions. Do not deviate from
> locked items without explicit human approval.

---

## PROJECT IN ONE LINE
Offline-first Flutter app for Quran memorization testing. Student recites from
memory; an **on-device, Quran-trained streaming ASR** reveals words live and
flags mistakes; a post-session report feeds an SM-2 review planner.

---

## THE ASR MODEL (CRITICAL — use exactly this, do not substitute)

We use a **Quran-trained FastConformer-CTC** model, NOT Whisper, NOT a generic
Arabic model. This decision is LOCKED. The reason: Whisper is non-streaming
(caused 3-line reveal delay in prior attempts) and generic Arabic models lack
Quranic accuracy. This model is streaming, Quran-trained, and ONNX-ready.

**Source repo (HuggingFace):** `Saboorhsn/quran-stt-onnx`
(ONNX export of `Muno459/fastconformer-quran`, trained on EveryAyah + tlog,
Hafs riwayah, with tashkeel.)

**Files to download and bundle (do NOT guess filenames):**
- `onnx/model_int8.onnx`  — INT8 model for on-device (~132 MB). Bundle this in the APK.
- `tokenizer.model`       — SentencePiece BPE (vocab 1024).
- `tokens.txt`            — token-id → text mapping.
- For live ASR + live tajweed in one pass, OPTIONALLY use
  `model_streaming_with_encoder.q8` instead of `model_int8.onnx`.
- Pronunciation/GOP head: `head/pronunciation_head.pt` (+ `tajweed/head_scorer.py`)
  — only if/when we wire GOP scoring (Phase 4).

**Hard technical facts about this model (do not re-derive, trust these):**
- Input: 80-dim log-mel features, 16 kHz mono, 10 ms hop. The APP extracts mel; the model does NOT take raw audio.
- CTC head outputs logprobs [T, 1025]; blank id = 1024.
- Streaming is cache-aware: carry `cache_last_channel` / `cache_last_time` across chunks, and carry the prev-token state across chunks or you get duplicated letters at chunk seams.
- Output orthography is **imlaei**, while the mushaf displays **Uthmani rasm**. Reconcile in matching with **alef-insensitive normalization** (already implemented in `normalizer.dart`).
- RTF on Android native ≈ 0.04 (very fast). Streaming adds ~1.6 s latency per chunk — this is expected and acceptable, NOT a bug.
- **tokens.txt ships WITHOUT the CTC blank.** The downloaded `tokens.txt` has
  1024 lines (ids 0–1023) but the model's `vocab_size = 1025`; the blank token
  (id 1024) is omitted. sherpa-onnx refuses to load it ("We expect that
  tokens.txt contains the symbol `<blk>` or `<eps>` or `<blank>` and its ID").
  FIX: append `<blk> 1024` — run `python tools/asr/fix_tokens_blank.py
  assets/models/tarteel/tokens.txt` (idempotent). Re-run after any re-download.
- **The model already carries sherpa's required ONNX metadata** — no metadata
  injection needed. sherpa logs on load: `subsampling_factor=4`,
  `vocab_size=1025`, `model_type=EncDecCTCModelBPE`, `normalize_type=per_feature`,
  `model_author=nemo`. (Note `subsampling_factor=4`, NOT 8.) So
  `tools/asr/add_sherpa_metadata.py` is a fallback that is NOT required for this
  export.

**Runtime:** This model was exported for `onnxruntime`, not necessarily for the
`sherpa_onnx` package. Before building the ASR pipeline, RESEARCH and DECIDE
whether to run it via the `onnxruntime` Flutter package directly or via
`sherpa_onnx`. State your choice and reasoning before writing pipeline code.

**Reference implementation (read it, don't reinvent):**
The HuggingFace model card for `Saboorhsn/quran-stt-onnx` contains a full
runnable pipeline: log-mel extraction, ONNX inference, CTC greedy decode,
`fitting_align` (Needleman-Wunsch), `ctc_forced_align` (Viterbi), and GOP
scoring. Port this logic; do not write your own from scratch.
The companion app `github.com/HsnSaboor/Mualim-Quran` is a live reference.

---

## GATE 0 — VERIFY THE MODEL BEFORE ANY FLUTTER CODE
Before Phase 1, produce a Python script that runs `model_int8.onnx` on a WAV
file and prints the recognized text + RTF. The HUMAN tests accuracy on their
own voice/mic. Do not proceed to Flutter until the human confirms accuracy is
acceptable. This is the most important gate — do not skip it.

---

## LOCKED TECH STACK (do not substitute)
- Flutter ≥3.24.0, Dart SDK ≥3.5.0
- State: `flutter_riverpod` 2.x
- ASR runtime: `onnxruntime` (decision pending Phase 2 research) — NOT cloud
- Mic: `record` 7.x (PCM 16 kHz mono Int16)
- Mushaf fonts: QCF V2 per-page fonts (Uthmani rasm). App is NON-COMMERCIAL,
  free/charity only — KFGQPC font terms must be respected.
- Local DB: `sqflite` for session logs
- Backend: Firebase Spark (Auth + Firestore) for sync/auth ONLY. App works
  fully offline. NO ASR proxy needed (ASR is on-device now — the old
  Cloudflare Worker ASR proxy is REMOVED from scope).

---

## DEVICE-VERIFIED FILES — DO NOT REFACTOR WITHOUT ON-DEVICE MEASUREMENT
These contain values/architecture tuned on a real device (Motorola Edge 50
Fusion, Android 16). "Improving" them blindly will reintroduce solved bugs.
Change only with a measured before/after.
- `lib/features/recitation/asr_service.dart` (audio capture, isolate, chunking)
- `lib/features/mushaf/mushaf_page_widget.dart` (dual render paths)
- `lib/features/mushaf/page_font_loader.dart` (font cache behavior)

When you need to tune ASR or rendering numbers: WRITE A MEASUREMENT TOOL and
ask the human to run it on-device and report results. Do NOT guess constants.
You cannot run the phone or hear the mic — the human is your sensor.

---

## ARCHITECTURE GUARDRAILS
- `packages/quran_tasmee3_core/` is PURE DART. Never add Flutter/Firebase/ASR
  imports to it. It must run under plain `dart test`.
- All external deps are bound via `lib/app/providers.dart` SWAP POINTS. Keep
  that pattern. The 69 existing core tests must keep passing.
- Build on top of existing code (matching engine, scheduler, report). Do not
  rewrite working tested code.

---

## MATCHING / SCORING DECISIONS (LOCKED)
- Longest-correct-prefix matching (Rule D dropped). Context replay is NOT an error.
- `forget` comes from the silence timer / manual reveal, never from the engine.
- Error classification: substitution / order / forget / pronunciation / asrLag.
  `asrLag` is excluded from scoring (it's ASR delay, not a user mistake).
- Red flash fires ONLY on confirmed `wrong` status. Clear `lastError` at the
  start of every utterance (stale value caused ghost flashes before).
- Prefer GOP-based classification (Phase 4) over the old attempt-ladder where
  GOP is available; keep `asrLag` handling from the old system.

---

## THINGS THAT WILL GO WRONG (from prior sessions — save yourself hours)
1. Model takes log-mel, not raw audio. Extract 80-dim mel in the app.
2. Forgetting to carry CTC cache + prev-token state across chunks → duplicated letters at seams.
3. imlaei (model) vs Uthmani (display) mismatch → use alef-insensitive matching.
4. Running ASR on the main isolate blocks the mic → use a persistent background isolate.
5. `pause()` before setting the `_paused` flag loses samples → stop recorder first, then set flag.
6. Font load triggers a full measurement-cache wipe (150 TextPainter.layout calls) → in the static path, measure the whole line as ONE text.
7. `AutomaticKeepAliveClientMixin` keeps pages alive → font-ready rebuilds fire unpredictably.
8. Page swipe stutter from font decompression on UI thread → deferred page build during swipe (cream placeholder, build on settle).
9. Gradle JVM OOM on low-RAM machines → `-Xmx3G -XX:MaxMetaspaceSize=1G`.
10. Windows Notepad merges lines in gradle.properties → use a real editor.
11. End-of-session: explicitly flush the last audio chunk or the last word is lost.

---

## PER-PHASE DEFINITION OF DONE
For every phase:
1. Write the tests FIRST, run them, and show they pass before claiming done.
2. Report: what was built, what the human must test on-device, any deviation from this file.
3. Never mark a phase complete on code that hasn't been shown to compile/pass tests.
4. If a task needs device data you don't have, build the measurement tool and stop — ask the human to run it.
