// One-time off-device seeder (Mushaf viewer Phase 0).
//
// Fetches Mushaf 1 (QCF V2) word-level data + chapter metadata from the Quran
// Foundation Content API v4 and builds `quran_qcf_v2.sqlite`. Optionally
// downloads the QCF V2 per-page fonts.
//
// Credentials come from the environment (NEVER hard-code / commit them):
//   QF_CLIENT_ID, QF_CLIENT_SECRET
// Optional overrides:
//   QF_OAUTH_URL   (default https://oauth2.quran.foundation/oauth2/token)
//   QF_API_BASE    (default https://apis.quran.foundation/content/api/v4)
//   OUT_DIR        (default ../../assets/quran  relative to this file)
//   FONT_URL_TEMPLATE  e.g. https://.../p{page}.woff2  (fonts skipped if unset)
//   MUSHAF         (default 1 = QCF V2)
//
// Usage:
//   cd tools/seed && npm install
//   QF_CLIENT_ID=... QF_CLIENT_SECRET=... npm run seed

import { mkdir, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { createSchema, insertPage, insertSurahs, openDb, report } from './db.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

const FONTS_ONLY = process.env.SEED_FONTS_ONLY === '1';
// Creds are only needed to hit the API; fonts-only mode skips that.
const CLIENT_ID = FONTS_ONLY ? '' : requireEnv('QF_CLIENT_ID');
const CLIENT_SECRET = FONTS_ONLY ? '' : requireEnv('QF_CLIENT_SECRET');
const OAUTH_URL =
  process.env.QF_OAUTH_URL || 'https://oauth2.quran.foundation/oauth2/token';
const API_BASE =
  process.env.QF_API_BASE || 'https://apis.quran.foundation/content/api/v4';
const MUSHAF = Number(process.env.MUSHAF || 1);
const OUT_DIR = process.env.OUT_DIR || resolve(__dirname, '../../assets/quran');
const DB_PATH = join(OUT_DIR, 'quran_qcf_v2.sqlite');
const FONT_DIR = join(OUT_DIR, 'fonts');
const FONT_URL_TEMPLATE = process.env.FONT_URL_TEMPLATE || '';
const TOTAL_PAGES = 604;

function requireEnv(name) {
  const v = process.env[name];
  if (!v) {
    console.error(`Missing required env var ${name}`);
    process.exit(1);
  }
  return v;
}

let _token = null;
async function getToken() {
  const basic = Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64');
  const res = await fetch(OAUTH_URL, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: 'grant_type=client_credentials&scope=content',
  });
  if (!res.ok) {
    throw new Error(`OAuth failed: ${res.status} ${await res.text()}`);
  }
  const json = await res.json();
  if (!json.access_token) throw new Error('OAuth: no access_token in response');
  return json.access_token;
}

async function apiGet(path, { retry = true } = {}) {
  if (!_token) _token = await getToken();
  const url = path.startsWith('http') ? path : `${API_BASE}${path}`;
  let res = await fetch(url, {
    headers: { 'x-auth-token': _token, 'x-client-id': CLIENT_ID },
  });
  if (res.status === 401 && retry) {
    _token = await getToken(); // refresh once
    res = await fetch(url, {
      headers: { 'x-auth-token': _token, 'x-client-id': CLIENT_ID },
    });
  }
  if (!res.ok) {
    throw new Error(`GET ${url} → ${res.status} ${await res.text()}`);
  }
  return res.json();
}

async function fetchChapters() {
  const json = await apiGet('/chapters?language=ar');
  return json.chapters ?? [];
}

async function fetchPageVerses(page) {
  const wordFields = [
    'text_uthmani',
    'code_v2',
    'location',
    'line_number',
    'page_number',
    'char_type_name',
    'position',
  ].join(',');
  const params = new URLSearchParams({
    words: 'true',
    word_fields: wordFields,
    fields: 'page_number,juz_number,hizb_number,verse_key',
    mushaf: String(MUSHAF),
    per_page: '300',
  });
  const verses = [];
  let p = 1;
  // Pages have few verses, but page through defensively.
  for (;;) {
    params.set('page', String(p));
    const json = await apiGet(`/verses/by_page/${page}?${params}`);
    verses.push(...(json.verses ?? []));
    const total = json.pagination?.total_pages ?? 1;
    if (p >= total) break;
    p++;
  }
  return verses;
}

async function downloadFonts() {
  if (!FONT_URL_TEMPLATE) {
    console.log(
      '\nFONT_URL_TEMPLATE not set → skipping font download. Recommended QCF V2 set:\n' +
        '  FONT_URL_TEMPLATE="https://raw.githubusercontent.com/nuqayah/qpc-fonts/master/mushaf-v2/QCF2{page3}.ttf"\n' +
        '({page3} = zero-padded 3-digit page; TTF is what Flutter bundles.)',
    );
    return 0;
  }
  await mkdir(FONT_DIR, { recursive: true });
  let ok = 0;
  for (let p = 1; p <= TOTAL_PAGES; p++) {
    const url = FONT_URL_TEMPLATE.replaceAll('{page3}', String(p).padStart(3, '0'))
      .replaceAll('{page}', String(p));
    const ext = url.split('.').pop().split('?')[0];
    try {
      const res = await fetch(url);
      if (!res.ok) throw new Error(`${res.status}`);
      const buf = Buffer.from(await res.arrayBuffer());
      await writeFile(join(FONT_DIR, `p${p}.${ext}`), buf);
      ok++;
    } catch (e) {
      console.warn(`  font p${p} failed: ${e.message}`);
    }
    if (p % 50 === 0) console.log(`  fonts ${p}/${TOTAL_PAGES}`);
  }
  return ok;
}

async function main() {
  await mkdir(OUT_DIR, { recursive: true });

  // Fonts-only mode: reuse the existing DB, just (re)download the page fonts.
  if (process.env.SEED_FONTS_ONLY === '1') {
    const fonts = await downloadFonts();
    console.log(`\nFonts saved: ${fonts}/${TOTAL_PAGES} → ${FONT_DIR}`);
    return;
  }

  const db = openDb(DB_PATH);
  createSchema(db);

  console.log('Fetching chapters…');
  const chapters = await fetchChapters();
  insertSurahs(db, chapters);
  console.log(`  ${chapters.length} surahs`);

  console.log(`Fetching ${TOTAL_PAGES} pages (Mushaf ${MUSHAF})…`);
  let totalWords = 0;
  let totalMarkers = 0;
  for (let page = 1; page <= TOTAL_PAGES; page++) {
    const verses = await fetchPageVerses(page);
    const { words, markers } = insertPage(db, page, verses);
    totalWords += words;
    totalMarkers += markers;
    if (page % 25 === 0 || page === TOTAL_PAGES) {
      console.log(`  page ${page}/${TOTAL_PAGES} (words so far: ${totalWords})`);
    }
  }

  const fonts = await downloadFonts();

  const r = report(db);
  db.close();

  console.log('\n==================== SEED COMPLETE ====================');
  console.log(`DB: ${DB_PATH}`);
  console.log(`surahs:        ${r.surahs}   (expect 114)`);
  console.log(`pages:         ${r.pages}    (expect 604)`);
  console.log(`words (all):   ${r.wordsAll}`);
  console.log(`words (word):  ${r.wordsReal}  (~77k expected)`);
  console.log(`distinct ayat: ${r.ayat}     (expect ~6236)`);
  console.log(`ayah_markers:  ${r.markers}`);
  if (FONT_URL_TEMPLATE) console.log(`fonts saved:   ${fonts}/${TOTAL_PAGES}`);
  console.log('\nPage 1 verification (Al-Fatiha, in order):');
  for (const w of r.page1) console.log(`  ${w.id}  ${w.uthmani_text}`);
  console.log('======================================================');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
