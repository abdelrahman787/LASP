# Report — Closed PR #1 (the branch we closed)

> Detailed report on **PR #1**, the only pull request ever opened in this repo,
> which was **closed without merging**. All facts here are pulled from the GitHub
> API and git history, not memory.

---

## 1. At a Glance

| Field | Value |
|---|---|
| **PR** | #1 — *"Pure-Dart cores: recitation matching engine + review-plan scheduler"* |
| **State** | **Closed** · **Draft** · **NOT merged** (`merged: false`) |
| **Head branch** | `claude/peaceful-cannon-ktbz8d` (our current working branch) |
| **Head SHA at close** | `949a963` |
| **Base branch** | `main` (SHA `48e20cf` — *"Initial empty commit"*) |
| **Opened** | 2026-06-13 |
| **Closed** | 2026-06-21 (open ~8 days) |
| **Commits** | **48** |
| **Files changed** | **180** |
| **Additions** | **+16,514 lines** |
| **Review comments / reviews** | **0** (closed with no discussion) |

### The single most important fact
**Nothing from PR #1 was ever merged.** `main` is still the empty initial
commit. The entire ~16.5k-line build lives **only** on the branch
`claude/peaceful-cannon-ktbz8d` — which we are **still working on today** (the
branch continued past the PR's close SHA `949a963` up to the current tip).

---

## 2. Scope Drift — What It Was vs What It Became

PR #1 was **opened as a draft for a narrow slice**: the two pure-Dart cores
(matching engine + review scheduler), ~30 tests, no Flutter. Its description
still reflects only that.

But because it was a long-lived draft against `main`, the branch **kept
accumulating every subsequent commit** for 8 days. By the time it closed it
contained the **entire application build** — 48 commits, 180 files — far beyond
its stated scope. So the PR title undersells it by an order of magnitude: it was
effectively "the whole project so far," not just the cores.

This scope drift is the likely reason it was closed rather than merged: a 180-
file / 16.5k-line draft PR is not reviewable or mergeable as one unit, and `main`
was never intended to take it wholesale.

---

## 3. What the Closed PR Contained (by subsystem)

Reconstructed from the 48 commits:

1. **Pure-Dart core — recitation engine** (the PR's stated scope): normalizer,
   Levenshtein/levRatio, mode thresholds, stateless `matchUtterance`
   (context-replay absorption, longest-correct-prefix, substitution/order/
   addition + pronunciation flags), `RecitationController` state machine
   (silence timers, attempt ladder, reveal APIs), `findBestAnchor` re-anchor
   recovery, `buildSessionReport` (5 Arabic buckets + score), cross-bucket dedup.
2. **Pure-Dart core — review planner**: domain models, weak-ayah aggregation
   with recency weighting, SM-2-lite `generatePlan`/`reschedule`, contiguous-ayah
   merge, `PlanService` (custom plans by surah/juz/page/range), `UserSettings`.
3. **Flutter app shell**: Riverpod DI with SWAP POINTs, all externals faked;
   dashboard, recitation, report, plans, settings, bookmarks, stats, home shell
   + drawer, bottom nav.
4. **ASR (cloud path)**: `GroqAsrService` over a Cloudflare Worker; continuous
   PCM streaming with overlapping windows; the ASR-only Worker (Firebase token
   verification → Groq whisper-large-v3).
5. **Firebase**: Auth (email/password) + Firestore repos under `users/<uid>/…`
   + offline persistence + security rules (SWAP POINT 2).
6. **Mushaf viewer**: Quran Foundation seeder (QCF V2 → SQLite), SQLite-backed
   repo (SWAP POINT 3), real QCF V2 per-page font renderer (15 lines
   edge-to-edge), reveal API, reader screen, index, surah banner/Basmala.
7. **Design system**: Stitch "Liquid Glass" theme (glass cards, liquid progress,
   donut score gauge), bundled IBM Plex Sans Arabic (offline-first).
8. **Many device-feedback rounds**: overflow fixes, IA overhaul, font/dagger-alef
   match fix, pause/resume, re-anchor forget logging, code-review fixes.

Test count grew across the PR from **30 → ~91** core tests, `dart analyze`/
`flutter analyze` reported clean throughout, with a recurring honest caveat that
**visual/GPU and on-device behavior were UNVERIFIED** from the sandbox.

---

## 4. Timeline (48 commits, grouped)

| Dates | Theme |
|---|---|
| 06-13 | Cores (engine + scheduler), controller, report, settings, Flutter scaffold, Groq ASR, Firebase |
| 06-14 | Android build fix (record 7.x), ASR-only Worker |
| 06-15 | Continuous PCM streaming; dagger-alef match fix; truthful error log |
| 06-16 | Re-anchor recovery + skipped-range forget logging; report dedup |
| 06-17 | Quran seeder (QCF V2 → SQLite), SWAP POINT 3, Mushaf renderer, Review Plans phases 3–4, Stitch export |
| 06-18 | Liquid Glass design, bundled fonts, GlassCard fix, two device-fix rounds, code-review fixes + pause/resume |
| 06-19–21 | IA overhaul (home/drawer/stats), reader full-screen + surah banner; final commits to close SHA `949a963` |

(After close, the **same branch** continued: Phase-2 NeMo-CTC ASR, gate-1
harness, scoring fix, CI, and the docs — these are **not** part of PR #1.)

---

## 5. Problems & Fixes (across the experiment)

Reconstructed from the commit history — the concrete bugs we hit and how each
was resolved. Split into "inside PR #1" and "after close (the ASR model
experiment)".

### 5.1 Inside PR #1 (the app build)

| # | Problem (symptom) | Root cause | Fix |
|---|---|---|---|
| 1 | Android `assembleDebug` fails to compile | `record` 5.x pulled an inconsistent federated plugin set | Bump `record` → `^7.1.0` (self-consistent 2.x set) |
| 2 | Last word of ayah unrecognized; next ayah "dead" after Reveal Next Word; MediaCodec churn (`0 chunks`, `MPEG4Writer Stop`) | File-per-chunk recorder stopped/restarted every ~3 s → mic OFF during upload, words cut at boundaries | Rewrite to **one continuous 16 kHz PCM stream** + overlapping windows (3 s window / 2 s emit, 1 s overlap) + RMS silence gate |
| 3 | Cursor stuck at `مالك` (false substitution, 0 accepted) | Normalizer **stripped** dagger-alef U+0670 (`مَٰلِك`→`ملك`) while Whisper output full alef (`مالك`) → levRatio 0.25 > 0.20 | Map U+0670 → full alef (0627) in unification instead of stripping; regression test |
| 4 | A clean utterance showed a non-null error in the debug log | `lastError` was never cleared, surfaced the last error *ever* | Clear `_lastError` at the start of each utterance (report data was never actually corrupted) |
| 5 | Cursor gets stuck, needed manual Reveal Full Ayah | No automatic recovery | **Re-anchor recovery**: `findBestAnchor` scans the whole scope; jump after N stuck utterances |
| 6 | Re-anchor jump left skipped words shown as "nothing wrong" | Only a generic skip marker was logged | Log a **forget** for every word in the skipped `[oldCursor, anchor)` range |
| 7 | One word appeared in 3 contradictory buckets (substitution + order + forget) | Every ladder entry routed to a bucket | **Cross-bucket dedup**: pick the last-logged error per word as the single display winner |
| 8 | Seeder won't build on Windows/Node 24 | `better-sqlite3` needs a C++ toolchain | Switch to built-in `node:sqlite` (zero native deps) |
| 9 | QCF V2 fonts 404 for all pages | `{page}` not zero-padded (files are `QCF2001..604`) | `{page3}` zero-padded placeholder + self-diagnosing URL print |
| 10 | "ListTile background/ink may be invisible" assertion in glass cards | Glass fill painted by a Container between Material and child | Paint glass fill + border via the inner `Material` itself; InkWell child |
| 11 | Mushaf line horizontal `RenderFlex` overflow | Fixed font size didn't fit dense lines | Measure each line (`TextPainter`), shrink font to fit (×0.97 safety), reserve cursor border, `TextScaler.noScaling` |
| 12 | Reader frozen on page 1 | `ref.read` of repo once in `initState` froze the 1-page fallback in a race | Watch `quranDataProvider` (`AsyncValue`) in `build`; build PageView from resolved 604 pages |
| 13 | Common word recurring far later misclassified as `order` not `substitution` | Unbounded order look-ahead over a full-page scope | Bound order look-ahead to an 8-word window; regression test |
| 14 | `ingestSession` wrote `0:0:0` garbage; N gets + N upserts | No id validation; per-item writes | Validate via `parseWordId`; batched `getMany` + `upsertAll` (WriteBatch, 30/req) |
| 15 | Worker ASR call could hang | No timeout | 15 s hard timeout → treated as ASR failure (empty result) |

### 5.2 After close — the ASR model experiment (current branch)

| # | Problem | Root cause | Fix / status |
|---|---|---|---|
| 16 | Whisper batch latency (3-line reveal delay) + 2 s garbling + 6-thread regression | Whisper is **non-streaming**; tuning can't fix the structural batch constraint | **Switch model** to FastConformer-CTC (`Saboorhsn/quran-stt-onnx`), streaming + Quran-trained (LOCKED) |
| 17 | sherpa refuses to load: needs `<blk>`/`<eps>`/`<blank>` | `tokens.txt` ships 1024 lines but `vocab_size = 1025` (blank id 1024 omitted) | Idempotent `tools/asr/fix_tokens_blank.py` appends `<blk> 1024` |
| 18 | Predicted: missing ONNX metadata | (prediction was wrong) | Metadata **already present** (`subsampling_factor=4`, `vocab_size=1025`, `normalize_type=per_feature`); `add_sherpa_metadata.py` kept as unused fallback |
| 19 | `SIGSEGV` decoding the full 104 s clip in one pass (arm64) | Long single-pass offline decode overruns phone memory | **Chunked decode** (8 s windows) + **Variant B** (fresh recognizer/stream per chunk, freed after each) |
| 20 | Unread ayahs scored 100% | Un-attempted words recorded nothing | Inject **confirmed forgets** for remaining scope via the controller's public reveal funnel; 2 tests |
| 21 | Arabic UI text corrupted in source | An editor/tool re-encoded the file | Restore commit; ongoing encoding-fragility risk (see `CODEBASE_ANALYSIS.md` §6.6) |

---

## 6. Latest State Reached in the Experiment

Where the ASR experiment stands **right now** on the branch:

- **Live ASR path = `SherpaOnnxAsrService`** (NeMo FastConformer-CTC int8),
  selected by `kUseSherpaOnDeviceAsr = true` in `providers.dart`. It runs on a
  **background isolate**, is **VAD-segmented** (Silero), uses **Variant B**
  per-chunk decode, carries the capture-audit + flush discipline, and **logs RTF
  per chunk** with the `[ASR]` tag.
- **Gate 0 (PC): PASSED** — accurate Quran transcription at **RTF ≈ 0.055**.
- **Gate 1 (device): partially through** —
  - ✅ model loads (metadata present),
  - ✅ tokens blocker fixed (`fix_tokens_blank.py`),
  - ✅ long-decode `SIGSEGV` mitigated via chunking/Variant B,
  - 🔴 **a clean end-to-end on-device transcription has not been reported back
    yet** — this is the immediate next step.
- **Live but UNVERIFIED constants** (the "GATE TEST" values): `_kMaxSpeechDuration
  = 20.0` (was 3.0), `_kSegmentOverlap = 0.0` (was 0.6), `_kChunkSamples = 8 s`,
  and **confidence hardcoded to 0.85**. These need an on-device sweep before
  locking.
- **Tests:** 128 core tests pass; core `dart analyze` clean. (The Flutter ASR
  service / isolate / VAD have no automated coverage — they need a device.)
- **Known open risks** (from `CODEBASE_ANALYSIS.md`): CI likely broken (`dart` at
  a Flutter root), `lib/firebase_options.dart` tracked as a secret, no graceful
  fallback when model assets are missing, and three coexisting ASR backends.

**One-line status:** the on-device NeMo-CTC pipeline is **built and wired**, the
two hard blockers (tokens + SIGSEGV) are **solved**, and we are waiting on **one
clean Gate-1 transcription run on the Motorola** before tuning the provisional
constants and starting to remove the old Whisper path.

---

## 7. Why It Was Closed (interpretation)

No comment or review was recorded, so the reason isn't documented in the PR. The
evidence points to:
- It was a **draft** (never marked ready), so it was never intended to merge
  as-is.
- It had **grown to 180 files / 16.5k lines** — unreviewable as one unit and far
  past its title scope.
- `main` was deliberately kept as an **empty baseline**; the team is iterating on
  the long-lived feature branch instead of merging to `main`.

Net: closing it was a cleanup of a stale, over-grown draft — **not** a rejection
of the work (the work continues on the branch).

---

## 8. Implications & Recommendations

### Implications
- **`main` is empty and unprotected by history.** Everything of value is on one
  feature branch. If that branch is lost, the project is lost — there is no
  merged baseline.
- The closed PR is **not recoverable as a merge**; it's a historical record only.

### Recommendations
1. **(P1) Establish a real baseline on `main`.** Once the current branch is in a
   known-good state (core green, CI fixed, secrets handled — see
   `CODEBASE_ANALYSIS.md`), open a **fresh, scoped PR** and merge it, so `main`
   stops being empty. Do this only when you ask — per the standing instruction I
   did not reopen or open a PR.
2. **(P1) Scope future PRs.** Avoid another 180-file draft. Land work in
   reviewable slices (e.g. "core alignment", "on-device ASR", "docs") so each can
   actually be reviewed and merged.
3. **(P2) Treat the branch as precious until `main` has a baseline.** It is the
   only copy of 16.5k lines; ensure it's pushed (it is) and consider a backup
   tag.
4. **(P2) Don't reopen PR #1.** It's a stale draft; a fresh scoped PR from the
   current tip is cleaner than resurrecting a 180-file draft.

---

## 9. Verification Status

| Claim | How verified |
|---|---|
| PR #1 closed, draft, not merged | GitHub API `pull_request_read get` (`merged:false`, `state:closed`, `draft:true`) |
| 48 commits / 180 files / +16,514 | same API response |
| 0 comments/reviews | API `get_comments` returned `[]` |
| Commit themes/timeline | API `get_commits` (full list) |
| `main` is empty initial commit | `git for-each-ref` / `git log main` (`48e20cf Initial empty commit`) |
| Branch continued after close | local git: tip is past head SHA `949a963` |
