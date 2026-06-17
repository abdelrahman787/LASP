import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart' show AyahMeta;

/// The mushaf data contract the recitation flow consumes: an ordered list of
/// [ExpectedWord]s per page (the recitation "scope"), with stable
/// `wordId = "<surah>:<ayah>:<wordIndex>"`.
///
/// The real implementation (SWAP POINT 3) reads the bundled `quran_qcf_v2.sqlite`
/// produced by the off-device seeding script. [FakeQuranRepository] below
/// supplies Al-Fatiha so the app runs end-to-end with no Quran API/DB.
abstract class QuranRepository {
  /// Pages available to recite (1-based).
  List<int> get pages;

  /// Ordered words of [page], ready to use as a recitation scope.
  List<ExpectedWord> getPageWords(int page);
}

/// Al-Fatiha (surah 1) on a single fake "page 1".
class FakeQuranRepository implements QuranRepository {
  static const List<List<String>> _ayat = [
    ['بِسْمِ', 'ٱللَّهِ', 'ٱلرَّحْمَٰنِ', 'ٱلرَّحِيمِ'], // 1
    ['ٱلْحَمْدُ', 'لِلَّهِ', 'رَبِّ', 'ٱلْعَٰلَمِينَ'], // 2
    ['ٱلرَّحْمَٰنِ', 'ٱلرَّحِيمِ'], // 3
    ['مَٰلِكِ', 'يَوْمِ', 'ٱلدِّينِ'], // 4
    ['إِيَّاكَ', 'نَعْبُدُ', 'وَإِيَّاكَ', 'نَسْتَعِينُ'], // 5
    ['ٱهْدِنَا', 'ٱلصِّرَٰطَ', 'ٱلْمُسْتَقِيمَ'], // 6
    ['صِرَٰطَ', 'ٱلَّذِينَ', 'أَنْعَمْتَ', 'عَلَيْهِمْ', 'غَيْرِ',
        'ٱلْمَغْضُوبِ', 'عَلَيْهِمْ', 'وَلَا', 'ٱلضَّآلِّينَ'], // 7
  ];

  @override
  List<int> get pages => const [1];

  @override
  List<ExpectedWord> getPageWords(int page) {
    final scope = <ExpectedWord>[];
    for (var a = 0; a < _ayat.length; a++) {
      final ayah = a + 1;
      for (var w = 0; w < _ayat[a].length; w++) {
        final display = _ayat[a][w];
        scope.add(ExpectedWord(
          wordId: '1:$ayah:${w + 1}',
          surah: 1,
          ayah: ayah,
          wordIndex: w + 1,
          norm: normalizeForMatch(display),
          display: display,
        ));
      }
    }
    return scope;
  }
}

// =============================================================================
// SWAP POINT 3 — real, SQLite-backed implementation.
//
// Loads the bundled `assets/quran/quran_qcf_v2.sqlite` (built off-device by
// tools/seed) once into memory, so `getPageWords` stays synchronous (the
// recitation controller consumes it synchronously). If the asset is missing or
// the platform plugins are unavailable (e.g. unit tests), loading fails and the
// app falls back to [FakeQuranRepository].
// =============================================================================

/// Everything the app needs from the bundled mushaf, held in memory.
class QuranData {
  final List<int> pages;
  final Map<int, List<ExpectedWord>> pageWords;
  final List<AyahMeta> ayahMeta;
  const QuranData(this.pages, this.pageWords, this.ayahMeta);
}

const String _kDbAsset = 'assets/quran/quran_qcf_v2.sqlite';

/// Copy the bundled DB to a writable path (once), open it read-only, and load
/// all word-level data into memory. Throws if the asset/plugins are absent —
/// callers should catch and fall back.
Future<QuranData> loadQuranData() async {
  final docs = await getApplicationDocumentsDirectory();
  final dbPath = '${docs.path}/quran_qcf_v2.sqlite';
  final file = File(dbPath);
  if (!await file.exists()) {
    final data = await rootBundle.load(_kDbAsset);
    await file.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
  }

  final db = await openDatabase(dbPath, readOnly: true);
  try {
    final wordRows = await db.rawQuery(
      "SELECT id, surah, ayah, word_index, page_number, uthmani_text "
      "FROM words WHERE word_type='word' "
      "ORDER BY page_number, word_position_in_page",
    );
    final pageWords = <int, List<ExpectedWord>>{};
    for (final r in wordRows) {
      final page = r['page_number'] as int;
      final display = (r['uthmani_text'] as String?) ?? '';
      (pageWords[page] ??= []).add(ExpectedWord(
        wordId: r['id'] as String,
        surah: r['surah'] as int,
        ayah: r['ayah'] as int,
        wordIndex: r['word_index'] as int,
        norm: normalizeForMatch(display),
        display: display,
      ));
    }
    final pages = pageWords.keys.toList()..sort();

    final metaRows = await db.rawQuery(
      "SELECT DISTINCT w.surah AS surah, w.ayah AS ayah, "
      "w.page_number AS page, p.juz_number AS juz "
      "FROM words w JOIN pages p ON w.page_number = p.page_number "
      "WHERE w.word_type='word'",
    );
    final ayahMeta = [
      for (final r in metaRows)
        AyahMeta(
          surah: r['surah'] as int,
          ayah: r['ayah'] as int,
          juz: (r['juz'] as int?) ?? 0,
          page: r['page'] as int,
        ),
    ];

    return QuranData(pages, pageWords, ayahMeta);
  } finally {
    await db.close();
  }
}

/// QuranRepository backed by the loaded [QuranData] (synchronous reads).
class SqliteQuranRepository implements QuranRepository {
  final QuranData data;
  SqliteQuranRepository(this.data);

  @override
  List<int> get pages => data.pages;

  @override
  List<ExpectedWord> getPageWords(int page) => data.pageWords[page] ?? const [];
}
