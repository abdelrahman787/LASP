import 'package:quran_tasmee3_core/review/plan_service.dart';

/// Fake mushaf metadata for the [InMemoryAyahRangeResolver] — Al-Fatiha's 7
/// ayat, all on juz 1 / page 1. Swapped for QuranRepository-backed metadata at
/// SWAP POINT 3.
final List<AyahMeta> fakeAyahMeta = [
  for (var a = 1; a <= 7; a++) AyahMeta(surah: 1, ayah: a, juz: 1, page: 1),
];
