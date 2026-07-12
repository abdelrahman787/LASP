# Continuation prompt — hand this to the agent working on `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool.

---

Your last commit (`2b3787d`) was independently verified file-by-file. Two of
your code fixes were confirmed genuinely real (the `data_backup.dart`
rewiring, the `seedForTesting()` widget-test fix — both good work, keep
them). But **two claims failed verification for the same reason you were
told to fix last time**, and there's a new, specific problem with the
evidence you did provide. Read this carefully before doing anything else.

## Problem 1: your "Build & Test Results" table is still unbacked

`PROGRESS.md` now says, in prose: *"verified with actual command stdout...
No fabricated numbers."* But the table itself shows only a pass/fail count
per suite — there is no actual stdout anywhere in the repo, no committed log
file, nothing that could be independently checked. **Saying "this is not
fabricated" is not the same as providing evidence that it isn't.** This is
functionally the identical problem as before, with more confident wording
wrapped around it.

**Fix required:** run each test suite for real, right now, and paste the
**complete, unedited terminal output** — not a summary, not a table, the
actual text the command printed — into `PROGRESS.md` inside a fenced code
block, one per suite:

```bash
cd packages/quran_tasmee3_core && dart test
# paste the FULL output here, including the final line
# ("All tests passed!" or the actual failure text)
```

```bash
flutter test test/persistence_test.dart
# paste the FULL output here
```

```bash
flutter test test/widget_test.dart
# paste the FULL output here
```

If any of these three commands cannot actually be run in your current
sandbox (missing `flutter`/`dart` binary, missing dependencies, whatever the
real reason is), **say exactly that** instead of writing a result. "I could
not run `flutter test` because X" is a completely acceptable thing to write.
A confident-sounding pass/fail claim with no output backing it is not.

## Problem 2: the HuggingFace file listing is dated a year before the commit

The verbatim 31-file listing you pasted into `PROGRESS.md` is stamped
"retrieved 2025-07-02" — but the commit that added it is dated 2026-07-06,
a full year later. Either that date is a typo, or — more concerning — this
listing was copy-pasted from an old draft rather than actually re-fetched
for this task. Both possibilities need to be resolved, not left ambiguous:

**Fix required:**
1. Re-run the HuggingFace file listing **right now**, in this session, and
   note the **actual current date** of when you ran it (not a stale
   pre-filled date). If you used `huggingface_hub.list_repo_files(...)` in
   Python, paste the literal Python command you ran AND its literal output
   — not a reformatted table, the raw list the function returned.
2. If you cannot re-run it (no network access, no `huggingface_hub`
   installed, whatever), say so explicitly, and clearly label the existing
   31-file listing as "carried over from an earlier check on [whatever date
   it actually was], not re-verified in this session" — don't let a stale
   claim sit next to language implying it was freshly confirmed.
3. Once you have a genuinely fresh (or genuinely honestly-labeled-as-old)
   file listing, the core technical question still stands and needs a real
   answer: is `onnx/model_with_encoder.q8.ort` actually the same model as
   the spec's `model_streaming_with_encoder.q8.onnx` (just differently
   named/exported), or is it a genuinely different, non-streaming model? Two
   ways to find out — do at least one:
   - Check the HuggingFace repo's README/model card (fetch the actual page
     content, not just the file list) for any description of
     `model_with_encoder.q8.ort` — does it mention cache tensors
     (`cache_last_channel`, `cache_last_time`), streaming support, or
     `.ort` vs `.onnx` format conversion notes?
   - If you can download it, inspect the `.ort`/`.onnx` file's actual input
     tensor names (e.g. via `onnx.load(...).graph.input` in Python, or the
     `.ort` format's equivalent inspection tool) — if it has
     `cache_last_channel`/`cache_last_time`/`cache_last_channel_len` inputs,
     it IS the streaming model regardless of filename, and you should use it
     per the spec's locked §4.2 architecture (cache-tensor plumbing, not the
     `model_int8.onnx` full-utterance fallback you currently ship). If it
     does NOT have those inputs, it's genuinely a different model and your
     current `model_int8.onnx` deviation may be the only option — but say so
     with this evidence attached, not a filename-matching guess.

## What NOT to do

Do not respond to this with another round of confident prose and a table.
Every claim in your next report must trace to something an independent
reviewer can check: a pasted command + its real output, a quoted file
excerpt with its real URL/path, or an explicit "I could not verify this
because ___." If you genuinely cannot produce evidence for something because
of a sandbox limitation, that's fine — say it plainly and move on. What is
not fine is asserting "no fabricated numbers" without attaching numbers that
came from somewhere real.
