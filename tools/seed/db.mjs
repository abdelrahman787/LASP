// SQLite builder for the bundled Quran data (Mushaf viewer Phase 0).
// Pure DB logic — no network — so it's unit-testable with canned API data.

import Database from 'better-sqlite3';

/** Create the exact schema from the mushaf-viewer spec. */
export function createSchema(db) {
  db.pragma('journal_mode = WAL');
  db.exec(`
    DROP TABLE IF EXISTS surahs;
    DROP TABLE IF EXISTS pages;
    DROP TABLE IF EXISTS words;
    DROP TABLE IF EXISTS ayah_markers;

    CREATE TABLE surahs (
      id INTEGER PRIMARY KEY,
      name_ar TEXT,
      name_en TEXT,
      revelation_place TEXT,
      verses_count INTEGER,
      start_page INTEGER,
      bismillah_pre INTEGER
    );

    CREATE TABLE pages (
      page_number INTEGER PRIMARY KEY,
      juz_number INTEGER,
      hizb_number INTEGER,
      line_count INTEGER
    );

    CREATE TABLE words (
      id TEXT PRIMARY KEY,            -- "<surah>:<ayah>:<wordIndex>" for words
      surah INTEGER,
      ayah INTEGER,
      word_index INTEGER,
      page_number INTEGER,
      line_number INTEGER,
      word_position_in_page INTEGER,  -- 0-based reading order on the page
      uthmani_text TEXT,              -- display text WITH diacritics
      code_v2 TEXT,                   -- QCF V2 glyph code(s) for this page font
      word_type TEXT                  -- 'word' | 'ayah_end' | 'pause_mark' | ...
    );

    CREATE TABLE ayah_markers (
      surah INTEGER,
      ayah INTEGER,
      page_number INTEGER,
      line_number INTEGER,
      glyph TEXT
    );

    CREATE INDEX idx_words_page_pos ON words(page_number, word_position_in_page);
    CREATE INDEX idx_words_surah_ayah ON words(surah, ayah);
  `);
}

export function openDb(path) {
  return new Database(path);
}

/** Map the API's char_type_name to the schema's word_type. */
export function mapWordType(charType) {
  switch (charType) {
    case 'word':
      return 'word';
    case 'end':
      return 'ayah_end';
    case 'pause':
      return 'pause_mark';
    default:
      return charType || 'word';
  }
}

/** Insert chapter (surah) metadata from GET /chapters. */
export function insertSurahs(db, chapters) {
  const stmt = db.prepare(`
    INSERT OR REPLACE INTO surahs
      (id, name_ar, name_en, revelation_place, verses_count, start_page, bismillah_pre)
    VALUES (@id, @name_ar, @name_en, @revelation_place, @verses_count, @start_page, @bismillah_pre)
  `);
  const tx = db.transaction((rows) => {
    for (const c of rows) {
      const pages = Array.isArray(c.pages) ? c.pages : [];
      stmt.run({
        id: c.id,
        name_ar: c.name_arabic ?? null,
        name_en: c.name_simple ?? null,
        revelation_place: c.revelation_place ?? null,
        verses_count: c.verses_count ?? null,
        start_page: pages.length ? pages[0] : null,
        bismillah_pre: c.bismillah_pre ? 1 : 0,
      });
    }
  });
  tx(chapters);
}

/**
 * Insert one page's verses+words. `verses` is the API `verses` array from
 * GET /verses/by_page/{page}?words=true. Returns { words, markers }.
 * Also writes the `pages` row (juz/hizb/line_count).
 */
export function insertPage(db, page, verses) {
  const wordStmt = db.prepare(`
    INSERT OR REPLACE INTO words
      (id, surah, ayah, word_index, page_number, line_number,
       word_position_in_page, uthmani_text, code_v2, word_type)
    VALUES (@id, @surah, @ayah, @word_index, @page_number, @line_number,
            @word_position_in_page, @uthmani_text, @code_v2, @word_type)
  `);
  const markerStmt = db.prepare(`
    INSERT INTO ayah_markers (surah, ayah, page_number, line_number, glyph)
    VALUES (@surah, @ayah, @page_number, @line_number, @glyph)
  `);
  const pageStmt = db.prepare(`
    INSERT OR REPLACE INTO pages (page_number, juz_number, hizb_number, line_count)
    VALUES (@page_number, @juz_number, @hizb_number, @line_count)
  `);

  let wordCount = 0;
  let markerCount = 0;

  const tx = db.transaction(() => {
    // Stable reading order: by verse number, then word position.
    const sortedVerses = [...verses].sort(
      (a, b) => verseNum(a.verse_key) - verseNum(b.verse_key),
    );

    let pos = 0;
    let maxLine = 0;
    let juz = null;
    let hizb = null;

    for (const v of sortedVerses) {
      if (juz == null && v.juz_number != null) juz = v.juz_number;
      if (hizb == null && v.hizb_number != null) hizb = v.hizb_number;
      const [surah, ayah] = String(v.verse_key).split(':').map(Number);

      const words = [...(v.words ?? [])].sort(
        (a, b) => (a.position ?? 0) - (b.position ?? 0),
      );

      for (const w of words) {
        const type = mapWordType(w.char_type_name);
        const line = w.line_number ?? null;
        if (line != null && line > maxLine) maxLine = line;

        // wordIndex from location "s:a:i" when available, else position.
        const loc = typeof w.location === 'string' ? w.location : null;
        const wordIndex = loc ? Number(loc.split(':')[2]) : (w.position ?? null);

        // Stable unique id: location for real words; synthesize for glyphs
        // (end/pause) so they never collide with a real word id.
        const id =
          type === 'word' && loc
            ? loc
            : `${v.verse_key}:${type}:${w.position ?? pos}`;

        wordStmt.run({
          id,
          surah,
          ayah,
          word_index: wordIndex,
          page_number: page,
          line_number: line,
          word_position_in_page: pos,
          uthmani_text: w.text_uthmani ?? null,
          code_v2: w.code_v2 ?? null,
          word_type: type,
        });
        wordCount++;
        pos++;

        if (type === 'ayah_end') {
          markerStmt.run({
            surah,
            ayah,
            page_number: page,
            line_number: line,
            glyph: w.code_v2 ?? null,
          });
          markerCount++;
        }
      }
    }

    pageStmt.run({
      page_number: page,
      juz_number: juz,
      hizb_number: hizb,
      line_count: maxLine,
    });
  });
  tx();

  return { words: wordCount, markers: markerCount };
}

function verseNum(verseKey) {
  // "2:255" → 255 (within-page ordering only needs the ayah component, but we
  // also fold in surah so multi-surah pages order correctly).
  const [s, a] = String(verseKey).split(':').map(Number);
  return s * 1000 + a;
}

/** Summary counts + a page-1 verification sample. */
export function report(db) {
  const count = (sql) => db.prepare(sql).get().n;
  const surahs = count('SELECT COUNT(*) n FROM surahs');
  const pages = count('SELECT COUNT(*) n FROM pages');
  const wordsAll = count('SELECT COUNT(*) n FROM words');
  const wordsReal = count("SELECT COUNT(*) n FROM words WHERE word_type='word'");
  const ayat = count(
    "SELECT COUNT(*) n FROM (SELECT DISTINCT surah, ayah FROM words WHERE word_type='word')",
  );
  const markers = count('SELECT COUNT(*) n FROM ayah_markers');
  const page1 = db
    .prepare(
      `SELECT id, uthmani_text FROM words
       WHERE page_number=1 AND word_type='word'
       ORDER BY word_position_in_page LIMIT 10`,
    )
    .all();
  return { surahs, pages, wordsAll, wordsReal, ayat, markers, page1 };
}
