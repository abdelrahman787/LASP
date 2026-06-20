# Decorative art assets

## Surah-name banner frame

`make_surah_banner.py` authors the single shared banner frame used at the start
of every surah:

```
python3 tools/art/make_surah_banner.py
# -> assets/decor/surah_banner_frame.webp  (1200x300, ~18 KB, lossless WebP)
```

It is **committed** (not gitignored) and reused for all 114 surahs — the surah
name is drawn on top at runtime by `lib/features/mushaf/surah_banner.dart`, so
no text is ever baked into the image.

### Why authored, not sourced
The ready-made banner we evaluated was an auto-traced bitmap (673 KB / 1098
SVG paths) whose Arabic text rendered garbled, and stock-site PNGs had murky
licensing. This self-made frame is clean-licensed, tiny, crisp at any DPR, and
has transparent margins so it floats on the cream page.

## Surah name + Basmala text: KFGQPC glyph upgrade (off-device)

`SurahBanner` renders the name with the bundled **IBM Plex Sans Arabic** today
(always crisp/correct). It also accepts an optional KFGQPC surah-header glyph
+ font family — when supplied, the authentic mushaf glyph is used instead.

To light that up (same off-device pattern as the page fonts, which are
gitignored and built off-device):

1. **Fonts** — add the KFGQPC surah-header font (`QCF*_QBSML`) and Basmala
   glyph to `assets/quran/fonts/` and register a loader mirroring
   `page_font_loader.dart`. Subject to the King Fahd Complex copyright policy
   (same as the page fonts already used).
2. **Data** — extend the seed (`tools/seed`) to import the per-surah
   `surah_header` glyph + its `bismillah` glyph from the Quran Foundation
   content API (they arrive as page "words" with `type: surah_header` /
   `bismillah` and a `code_v2` PUA code point — no hand-maintained 1–114
   code-point table needed).
3. **Wire** — pass the glyph + loaded font family into `SurahBanner(...)` and
   render the Basmala glyph in place of the current Unicode text.

Until then the IBM Plex fallback is the active path (verified by
`test/surah_banner_test.dart`).
