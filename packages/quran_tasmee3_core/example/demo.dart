/// End-to-end demo wiring both pure-Dart cores with FAKE data — no Firebase,
/// no ASR, no Quran API. Run with: `dart run example/demo.dart`.
///
/// It simulates the closed memorization loop:
///   recite (fake ASR tokens) → matching engine classifies errors →
///   weak items → aggregate → generate plan → review → reschedule.
library;

import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/aggregation.dart';
import 'package:quran_tasmee3_core/review/scheduler.dart';

// --- Fake mushaf data (stands in for QuranRepository.getPageWords) ---------
// Al-Fatiha first two ayat as an ordered scope.
const _displayWords = [
  // ayah 1
  ['بِسْمِ', 'ٱللَّهِ', 'ٱلرَّحْمَٰنِ', 'ٱلرَّحِيمِ'],
  // ayah 2
  ['ٱلْحَمْدُ', 'لِلَّهِ', 'رَبِّ', 'ٱلْعَٰلَمِينَ'],
];

List<ExpectedWord> buildScope() {
  final scope = <ExpectedWord>[];
  for (var a = 0; a < _displayWords.length; a++) {
    final ayah = a + 1;
    for (var w = 0; w < _displayWords[a].length; w++) {
      scope.add(ExpectedWord(
        wordId: '1:$ayah:${w + 1}',
        surah: 1,
        ayah: ayah,
        wordIndex: w + 1,
        norm: normalizeForMatch(_displayWords[a][w]),
      ));
    }
  }
  return scope;
}

void main() {
  final scope = buildScope();
  print('Scope (${scope.length} words): '
      '${scope.map((e) => e.wordId).join(', ')}\n');

  // --- 1. A recitation with one substitution in ayah 2 ----------------------
  // Student recites ayah 1 perfectly, then says a wrong word for رب.
  const conf = RecitationConfig.normal;
  var cursor = 0;
  final acceptedHistory = <int>[];

  void feed(String recited, double confidence) {
    final tokens = tokenize(normalizeForMatch(recited));
    final r = matchUtterance(
      scope: scope,
      cursor: cursor,
      recognizedTokens: tokens,
      confidence: confidence,
      mode: conf,
      acceptedHistory: acceptedHistory,
    );
    acceptedHistory.addAll(r.acceptedWordIndices);
    cursor = r.newCursor;
    final revealed = r.acceptedWordIndices.map((i) => scope[i].wordId).join(' ');
    print('utterance "$recited" → revealed [$revealed] '
        'cursor=$cursor replay=${r.wasContextReplay}'
        '${r.error != null ? ' ERROR=${r.error}' : ''}');
  }

  feed('بسم الله الرحمن الرحيم', 0.95); // ayah 1, all accepted
  feed('الحمد لله غلط', 0.9); // ayah 2: two ok then substitution at رب
  print('');

  // --- 2. Turn that error into a weak item, aggregate, plan -----------------
  final now = DateTime.now().millisecondsSinceEpoch;
  final weakItems = <WeakItem>[
    WeakItem(
      wordId: '1:2:3', // رب
      surah: 1,
      ayah: 2,
      wordIndex: 3,
      errorCount: 3,
      lastErrorAt: now,
      masteryScore: 0.4,
      forgetCount: 0,
    ),
  ];

  final ayat = aggregate(weakItems, nowMs: now, pageResolver: (s, a) => 1);
  final qualifying = qualifyingAyat(ayat, const AggregationConfig());
  print('Weak ayat qualifying for review: $qualifying');

  final plan = generatePlan(qualifying, nowMs: now, planId: 'demo-plan');
  print('Generated plan "${plan.name}" with ${plan.items.length} item(s):');
  for (final i in plan.items) {
    print('  $i');
  }
  print('Due today: ${todaysQueue(plan, now).map((i) => i.id).toList()}\n');

  // --- 3. Run the review (passed), reschedule -------------------------------
  final item = plan.items.first;
  final result = ReviewResult.fromCounts(
    planItemId: item.id,
    confirmedErrors: 0,
    totalWords: 4,
    reviewedAt: now,
  );
  final rescheduled = reschedule(item, result, nowMs: now);
  final daysOut = (rescheduled.dueAt - now) ~/ 86400000;
  print('Reviewed ${item.id} (score ${result.score}) → '
      'rescheduled: interval=${rescheduled.intervalDays}d, '
      'next due in $daysOut day(s), status=${rescheduled.status.wire}');
}
