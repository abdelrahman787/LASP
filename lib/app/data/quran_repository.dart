import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';

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
