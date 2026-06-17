// Offline verification of the DB builder (no network). Feeds canned API-shaped
// data through the same insert functions the live seeder uses, then asserts the
// schema, counts, ordering, and page-1 verification query.

import assert from 'node:assert';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createSchema, insertPage, insertSurahs, openDb, report } from './db.mjs';

const chapters = [
  {
    id: 1,
    name_arabic: 'الفاتحة',
    name_simple: 'Al-Fatihah',
    revelation_place: 'makkah',
    verses_count: 7,
    pages: [1, 1],
    bismillah_pre: false,
  },
];

// Page 1: two verses with words + an ayah-end glyph, API v4 shape.
const page1Verses = [
  {
    verse_key: '1:1',
    page_number: 1,
    juz_number: 1,
    hizb_number: 1,
    words: [
      { position: 1, char_type_name: 'word', location: '1:1:1', line_number: 2, text_uthmani: 'بِسْمِ', code_v2: '' },
      { position: 2, char_type_name: 'word', location: '1:1:2', line_number: 2, text_uthmani: 'ٱللَّهِ', code_v2: '' },
      { position: 3, char_type_name: 'word', location: '1:1:3', line_number: 2, text_uthmani: 'ٱلرَّحْمَٰنِ', code_v2: '' },
      { position: 4, char_type_name: 'word', location: '1:1:4', line_number: 2, text_uthmani: 'ٱلرَّحِيمِ', code_v2: '' },
      { position: 5, char_type_name: 'end', location: '1:1:5', line_number: 2, text_uthmani: '١', code_v2: '' },
    ],
  },
  {
    verse_key: '1:2',
    page_number: 1,
    juz_number: 1,
    hizb_number: 1,
    words: [
      { position: 1, char_type_name: 'word', location: '1:2:1', line_number: 3, text_uthmani: 'ٱلْحَمْدُ', code_v2: '' },
      { position: 2, char_type_name: 'word', location: '1:2:2', line_number: 3, text_uthmani: 'لِلَّهِ', code_v2: '' },
      { position: 3, char_type_name: 'end', location: '1:2:3', line_number: 3, text_uthmani: '٢', code_v2: '' },
    ],
  },
];

const dbPath = join(tmpdir(), `seed_test_${Date.now()}.sqlite`);
const db = openDb(dbPath);
createSchema(db);
insertSurahs(db, chapters);
const counts = insertPage(db, 1, page1Verses);

const r = report(db);

// --- assertions ---
assert.equal(r.surahs, 1, 'surah inserted');
assert.equal(r.pages, 1, 'page row written');
assert.equal(r.wordsReal, 6, 'six real words (4 + 2)');
assert.equal(r.markers, 2, 'two ayah-end markers');
assert.equal(counts.words, 8, 'all glyphs inserted (6 words + 2 ends)');

// page row derived from verses
const pageRow = db.prepare('SELECT * FROM pages WHERE page_number=1').get();
assert.equal(pageRow.juz_number, 1);
assert.equal(pageRow.hizb_number, 1);
assert.equal(pageRow.line_count, 3, 'max line_number on page');

// surah metadata
const surah = db.prepare('SELECT * FROM surahs WHERE id=1').get();
assert.equal(surah.name_ar, 'الفاتحة');
assert.equal(surah.start_page, 1);
assert.equal(surah.verses_count, 7);

// page-1 verification query: words in reading order with correct ids
const ids = r.page1.map((w) => w.id);
assert.deepEqual(
  ids,
  ['1:1:1', '1:1:2', '1:1:3', '1:1:4', '1:2:1', '1:2:2'],
  'page 1 words in order, end-markers excluded from word scope',
);

// word_position_in_page is contiguous across the whole page (incl. glyphs)
const positions = db
  .prepare('SELECT word_position_in_page p FROM words WHERE page_number=1 ORDER BY p')
  .all()
  .map((x) => x.p);
assert.deepEqual(positions, [0, 1, 2, 3, 4, 5, 6, 7], 'contiguous positions');

db.close();
console.log('All seed-builder tests passed.');
console.log('Sample page-1 scope:', ids.join(', '));
