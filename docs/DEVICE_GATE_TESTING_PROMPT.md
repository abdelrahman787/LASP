# Continuation prompt — Gate 1 & 2 device testing for `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool (or hand to
whoever has a physical Android device available).

---

## Human sign-off on the model deviation (do this first, once, in `PROGRESS.md`)

The human has explicitly approved the deviation your investigation
uncovered: `model_streaming_with_encoder.q8.onnx` does not exist in
`Saboorhsn/quran-stt-onnx` on HuggingFace, and `model_with_encoder.q8.ort`
is a different, non-streaming model. **Approved path forward:**
`model_int8.onnx` run via the `onnxruntime` Flutter package directly
(never `sherpa_onnx`), full-utterance inference per VAD segment, no cache
tensors.

Add this exact sign-off to `PROGRESS.md`'s ASR model section (don't
paraphrase it away — quote it):

> **Human sign-off (2026-07-06):** Approved deviation from spec §2.1/§4.2.
> `model_streaming_with_encoder.q8.onnx` confirmed absent from
> `Saboorhsn/quran-stt-onnx`; `model_with_encoder.q8.ort` confirmed
> non-streaming via tensor inspection (no cache_last_channel/cache_last_time
> inputs). Approved: `model_int8.onnx` via `onnxruntime` Flutter package
> (never `sherpa_onnx`), full-utterance inference per VAD-detected segment,
> no cache tensors. This is safe from the spec §3.9 SIGSEGV history because
> that crash was specific to `sherpa_onnx`'s native `OfflineRecognizer`
> decode path — running the same model through `onnxruntime` directly uses
> a completely different code path and has not been shown to share that
> failure mode. This must still be confirmed empirically in Gate 1 below,
> not assumed safe by analogy.

## What's actually left: Gate 1 and Gate 2, on a real device

Everything that can be verified without a physical Android phone has been
verified. There is no more sandbox work to do — the remaining risk (does the
pipeline actually transcribe correctly on-device, without crashing, within
RTF budget) can only be resolved by running it on real hardware. If you
don't have one connected in this environment, say so plainly and stop —
don't simulate or guess at results.

### Gate 1 — bundled WAV, no microphone needed

1. Build a debug APK: `flutter build apk --debug` (or `flutter run` with a
   device attached).
2. Install it on the physical device (`adb install` or `flutter run`
   directly targets it once `adb devices` shows a non-empty list — check
   this first; if it's still empty, you have no device and must stop here).
3. Open the hidden dev ASR screen (5x long-press the Settings tab within 3
   seconds, per the existing implementation).
4. Select WAV-file mode, run it against the bundled test clip.
5. **Capture and paste the actual `adb logcat` output** covering the run —
   not a paraphrase. Specifically look for and report verbatim:
   - Any crash/exception stack trace (there should be none).
   - The recognized text for each segment.
   - Logged RTF per segment (must be < 0.1 per spec §4.2/§9 Phase 2 step 3).
   - Any hallucination signs: text appearing during silence gaps in the WAV.
6. Gate 1 passes only if: no crash, RTF < 0.1, and the transcribed text is a
   plausible match for the known content of the test WAV (a human should
   read it and confirm, the same way Gate 0 required human confirmation).

### Gate 2 — live microphone

1. From the same dev screen, switch to live-mic mode.
2. Recite a short, known passage (e.g. Al-Fatihah) while watching the live
   partial text and the RTF counter.
3. **Tune the VAD threshold using the on-screen slider while watching real
   RMS values** — the current starting threshold (0.01, per your own
   PROGRESS.md note marking it "STARTING POINT — must be tuned on-device")
   is unverified. Adjust it until: silence reliably stays silent (no
   spurious segments), and speech reliably triggers a segment within 1-2
   chunks of starting to speak.
4. **Capture and paste the actual on-screen/logcat output** of at least 3
   separate utterances: the recognized text, the RTF, and the final tuned
   VAD threshold value. A human must confirm the recognized text actually
   matches what was recited — this cannot be self-assessed by the agent
   that ran it, per the same rule that applied to Gate 0.
5. Gate 2 passes only if: no crash across at least 3 utterances and a
   silence period, RTF < 0.1, no hallucinated text during silence, and a
   human confirms the transcription accuracy on their own recitation.

### After Gate 2 passes — flip the swap point

Only after a human has confirmed Gate 2's results (not before, and not
based on your own assessment of your own transcription):

1. In `lib/app/providers.dart`, change `asrServiceProvider` from
   `FakeAsrServiceImpl()` to the real `StreamingAsrService` implementation.
2. Keep `FakeAsrServiceImpl` in the codebase (used by widget tests via
   `seedForTesting`-style overrides) — don't delete it.
3. Run the full test suite one more time and paste the real, complete
   output into `PROGRESS.md` (same evidence bar as before — no summarizing).
4. Update `PROGRESS.md`'s top-level status to reflect that Phase 2/4 (ASR)
   is now genuinely device-verified, with the Gate 1 and Gate 2 evidence
   linked/quoted in that section.

## If you have no device access right now

Say so explicitly in `PROGRESS.md` under the Phase 4 section: "BLOCKED — no
physical Android device available in this session." Do not write anything
that could be read as a completed Gate 1/2 result. This is a fully
acceptable stopping point — the project has a human (the one reading this)
who can run these steps themselves once they have the APK; your job in that
case is just to make sure the APK builds and the dev screen is reachable,
and to hand off clear instructions for the human to follow (steps above),
not to fabricate the outcome.
