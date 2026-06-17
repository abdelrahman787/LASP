# Quran data seeder (Mushaf viewer Phase 0)

One-time, **off-device** script: pulls Mushaf 1 (QCF V2) word-level data + chapter
metadata from the **Quran Foundation Content API v4** and builds
`assets/quran/quran_qcf_v2.sqlite` for the app to bundle. Optionally downloads the
QCF V2 page fonts.

> Run this on your machine/backend — NOT on the device, and NOT from the cloud
> dev sandbox (its network egress allowlist blocks `oauth2.quran.foundation` /
> `apis.quran.foundation`). The app only ever reads the bundled SQLite + fonts.

## Run

```bash
cd tools/seed
# No deps to install — uses Node's built-in node:sqlite (Node 22+), no native build.
cp .env.example .env        # then put your real QF_CLIENT_ID / QF_CLIENT_SECRET in .env
set -a; source .env; set +a # export the vars
npm run seed
```

Requires **Node 22+** (for `node:sqlite`). You'll see a harmless
`ExperimentalWarning: SQLite is an experimental feature` — that's expected.

Output: `assets/quran/quran_qcf_v2.sqlite` (+ `assets/quran/fonts/` if
`FONT_URL_TEMPLATE` is set). The script prints row counts and a page-1
(Al-Fatiha) verification sample at the end.

**Credentials** come only from the environment (`QF_CLIENT_ID`,
`QF_CLIENT_SECRET`) — never hard-code or commit them. `.env`, `node_modules`,
and the generated `*.sqlite` are gitignored.

## Verify (offline, no API/creds)

```bash
npm test        # feeds canned API-shaped data through the real node:sqlite builder
```
Asserts the exact schema, word ordering, ayah-end handling, the `pages`
derivation, and the page-1 scope query.

## Schema (consumed by the app + recitation engine)

- `surahs(id, name_ar, name_en, revelation_place, verses_count, start_page, bismillah_pre)`
- `pages(page_number, juz_number, hizb_number, line_count)`
- `words(id TEXT PRIMARY KEY "<surah>:<ayah>:<wordIndex>", surah, ayah, word_index,
  page_number, line_number, word_position_in_page, uthmani_text, code_v2, word_type)`
  — indexed on `(page_number, word_position_in_page)` and `(surah, ayah)`
- `ayah_markers(surah, ayah, page_number, line_number, glyph)`

The recitation scope is `SELECT … FROM words WHERE page_number=? AND
word_type='word' ORDER BY word_position_in_page` — `id` matches the engine's
`"<surah>:<ayah>:<wordIndex>"` contract exactly.

## Fonts

QCF V2 is one font per page (604 files). The canonical, Flutter-ready (**TTF**)
source is the King Fahd Complex set mirrored at `nuqayah/qpc-fonts`
(`mushaf-v2/QCF2NNN.ttf`, zero-padded). Download all 604 into
`assets/quran/fonts/p{n}.ttf` with:

```bash
SEED_FONTS_ONLY=1 \
FONT_URL_TEMPLATE="https://raw.githubusercontent.com/nuqayah/qpc-fonts/master/mushaf-v2/QCF2{page3}.ttf" \
npm run seed
```

- `{page3}` = zero-padded 3-digit page (`001`…`604`); `{page}` = raw number.
- `SEED_FONTS_ONLY=1` skips the API/DB and only fetches fonts (no creds needed),
  so you can run it after the DB is already built.
- TTF (not woff2) is what Flutter bundles on mobile.
- Respect the QCF V2 license (King Fahd Complex) and add the required
  attribution to the app's About screen.

The SQLite build is independent of fonts — fonts are only needed by the
pixel-faithful page renderer (Mushaf Phase 2). The recitation flow renders
`uthmani_text` directly and works without them.

## Wiring into the app (SWAP POINT 3)

After generating the DB + fonts:
1. Add `assets/quran/` to `flutter/assets` in `pubspec.yaml` and register the
   page fonts.
2. Implement a SQLite-backed `QuranRepository` + `AyahRangeResolver` (drift/
   sqflite) and swap them in at the two SWAP POINT 3 providers in
   `lib/app/providers.dart`, replacing `FakeQuranRepository` /
   `InMemoryAyahRangeResolver`.
