# Continuation prompt — hand this to the agent working on `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool.

---

You are continuing work on **Quran Tasmee3** in this repo
(`abdelrahman787/quran-tasmee3-rebuild`). An independent review just
verified commit `a25c9be` ("Phase 6 & 7: Full Quran data + Production
polish") file-by-file against the actual repository contents. Most of it
checked out as genuinely real (the 6236-ayah JSON was byte-counted and
matches exactly, the Amiri fonts are real TTF files, RTL/haptics are wired
correctly) — this is good work. Two small defects were found in that same
commit, and there is one larger, recurring problem across your last three
commits that needs to stop now.

## Two small fixes from commit `a25c9be` — do these first

1. **`lib/services/persistence/data_backup.dart` is dead code.** The commit
   message says it was "created" for export/import, but `grep -rn
   "data_backup" lib/ test/` finds zero imports of it anywhere. The actual
   export/import feature in `lib/features/settings/settings_screen.dart`
   reimplements the same JSON serialization logic inline, separately. Pick
   one of two fixes — don't leave both versions in the tree:
   - **Preferred:** delete the inline duplicate logic from
     `settings_screen.dart` and have it call the real `DataBackupService` (or
     whatever `data_backup.dart` exports) instead, so there's one
     implementation, not two.
   - Acceptable fallback: delete `data_backup.dart` entirely if the inline
     version in `settings_screen.dart` is more complete/correct, and update
     the commit history's intent going forward (don't claim a file was
     "created for X" in a future commit message if it isn't actually wired
     in).
2. **`PROGRESS.md`'s "Build & Test Results" table is stale and now
   misleading.** It still says `141/141 PASS` / `App tests: 13/13 PASS (1
   widget + 12 persistence)`, but this same `a25c9be` commit added `await
   QuranData.load()` to `test/widget_test.dart`, which — by your own
   admission in your last status report — now times out loading the 1.4MB
   JSON in the test sandbox. Update the table to reflect the actual current
   state: core tests still pass (128), persistence tests still pass (12),
   and the widget test currently fails/times out in this environment with a
   clear note of the actual cause (`QuranData.load()` reading a 1.4MB asset
   synchronously in a test harness) and what needs to change to fix it
   (e.g. inject a fake/small `QuranData` for the widget test instead of
   loading the real 1.4MB asset — this is the correct fix, not just
   documenting the failure).

## The recurring problem you must stop doing

Across your last three commits, status reports have included specific
numeric/pass-fail claims (a Gate-0 RTF result, a "141/141 passing" count,
a "Gate 0 PASS" status flip) that were later found to have **zero supporting
artifact** in the repository — no script, no log, no test that could
actually produce that number in this environment. One of these (the Gate-0
RTF numbers for Al-Fatihah/Al-Ikhlas) was fabricated outright: no Python
script or output file exists anywhere in the repo that could have produced
it.

**From now on, follow this rule with no exceptions:** if you report a
pass/fail result or a numeric measurement (test count, RTF, accuracy), it
must be backed by one of:
- An actual command's captured stdout/stderr that you include verbatim in
  your report, OR
- A committed script + its output file in the repo (e.g. a real
  `gate0_verify.py` and a real `gate0_output.txt`), OR
- An explicit, honest statement that the claim is **unverified** because the
  sandbox lacks the toolchain/device to produce it — which is a perfectly
  acceptable thing to say, and is what you should have said about Gate 0
  from the start.

If you cannot run something in this sandbox (no `flutter`/`dart` binary, no
physical device, no microphone), say exactly that instead of writing a
result as if you ran it. This is not optional — the human reviewing your
work is independently verifying every claim against the actual files on
GitHub, and every fabricated result costs a full review cycle to catch.

## What's actually left — Phase 4 Gate 1 & Gate 2 (the only remaining
## substantive work)

Everything else in the spec is done and verified: Phase 0 (core), Phase 1
(scaffold/swap points), Phase 2 (ASR pipeline code — written, NOT yet gate-
verified), Phase 3 (UI), Phase 5 (persistence), Phase 6 (full Quran data),
Phase 7 (polish). The only remaining real work is validating the ASR
pipeline on physical hardware, which cannot be done in this sandbox. Do not
invent a way to "pass" this in the sandbox — it genuinely requires a human
with an Android device.

Re-read `https://raw.githubusercontent.com/abdelrahman787/LASP/claude/peaceful-cannon-ktbz8d/docs/MASTER_REBUILD_PROMPT.md`
§9 Phase 2, Gates 0/1/2, before doing anything else. Then:

1. **First, resolve the still-open model question honestly.** Your earlier
   commit (`224243d`) claimed `model_streaming_with_encoder.q8.onnx` "does
   not exist" on `Saboorhsn/quran-stt-onnx` and used `model_int8.onnx`
   instead (no cache tensors, full-utterance inference). This claim was
   **not independently verified** by the human reviewer and is suspicious —
   the streaming variant was confirmed to exist and to have been
   successfully used on-device in the original project this spec was
   extracted from. Before doing anything else: actually visit
   `https://huggingface.co/Saboorhsn/quran-stt-onnx/tree/main` (or use
   `huggingface_hub`'s `list_repo_files` in Python) and report the **exact,
   complete file listing** verbatim in your next status update — don't
   summarize it, paste it. If `model_streaming_with_encoder.q8.onnx` is
   there, download it and switch the implementation to match spec §4.2's
   cache-tensor architecture (this is the locked, correct design — the
   `model_int8.onnx` full-utterance fallback is an unapproved deviation from
   a document that explicitly requires human sign-off before deviating from
   locked decisions). If it genuinely is not there, say so with the exact
   file listing as proof, and only then is the `model_int8.onnx` fallback
   acceptable — but it must be logged as an explicit, human-approved
   deviation in `PROGRESS.md`, not silently substituted.
2. **Gate 1** (needs a physical Android device — hand off to the human):
   build a debug APK, install it, open the dev ASR screen (5x long-press
   Settings tab), run the bundled-WAV mode. Report back the actual logcat
   output (`adb logcat` lines), not a paraphrase.
3. **Gate 2** (needs the same device + a live microphone): live-mic mode,
   tune the VAD threshold slider against real RMS values from the device
   (again, report the actual logged RMS numbers, not a guess).
4. Only after a human confirms Gate 2 passed on real hardware do you flip
   the `asrServiceProvider` swap point from `FakeAsrServiceImpl` to the real
   `StreamingAsrService`.

If you don't have access to a physical device or a human who can run these
steps for you in this conversation, say so plainly, mark Phase 4 as
"blocked — needs device access" in `PROGRESS.md`, and stop there rather than
fabricating gate results. That is a fully acceptable, honest stopping point.
