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

## 5. Why It Was Closed (interpretation)

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

## 6. Implications & Recommendations

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

## 7. Verification Status

| Claim | How verified |
|---|---|
| PR #1 closed, draft, not merged | GitHub API `pull_request_read get` (`merged:false`, `state:closed`, `draft:true`) |
| 48 commits / 180 files / +16,514 | same API response |
| 0 comments/reviews | API `get_comments` returned `[]` |
| Commit themes/timeline | API `get_commits` (full list) |
| `main` is empty initial commit | `git for-each-ref` / `git log main` (`48e20cf Initial empty commit`) |
| Branch continued after close | local git: tip is past head SHA `949a963` |
