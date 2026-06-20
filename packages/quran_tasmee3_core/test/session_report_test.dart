import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';
import 'package:quran_tasmee3_core/recitation/session_report.dart';
import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/review_service.dart';

const int _msPerDay = 86400000;
const int now = 1000000000000;

/// Two ayat × 4 words each (surah 1).
List<ExpectedWord> twoAyahScope() {
  const ayah1 = ['بسم', 'الله', 'الرحمن', 'الرحيم'];
  const ayah2 = ['الحمد', 'لله', 'رب', 'العالمين'];
  final scope = <ExpectedWord>[];
  for (var w = 0; w < ayah1.length; w++) {
    scope.add(ExpectedWord(
      wordId: '1:1:${w + 1}',
      surah: 1, ayah: 1, wordIndex: w + 1,
      norm: normalizeForMatch(ayah1[w]), display: ayah1[w],
    ));
  }
  for (var w = 0; w < ayah2.length; w++) {
    scope.add(ExpectedWord(
      wordId: '1:2:${w + 1}',
      surah: 1, ayah: 2, wordIndex: w + 1,
      norm: normalizeForMatch(ayah2[w]), display: ayah2[w],
    ));
  }
  return scope;
}

RecordedError re(
  String wordId,
  ErrorType type, {
  ErrorSeverity severity = ErrorSeverity.confirmed,
  bool manualReveal = false,
  int attempts = 0,
  String? recognized,
  String expected = '',
  int at = now,
}) {
  return RecordedError(
    wordId: wordId,
    expectedText: expected,
    recognizedText: recognized,
    errorType: type,
    confidence: 0.9,
    attempts: attempts,
    manualReveal: manualReveal,
    severity: severity,
    createdAt: at,
  );
}

void main() {
  group('bucket assignment (all 5 types)', () {
    test('each error type lands in the right bucket; forget is split', () {
      final scope = twoAyahScope();
      final errors = [
        re('1:1:1', ErrorType.forget, manualReveal: false), // silence
        re('1:1:2', ErrorType.forget, manualReveal: true), // manual
        re('1:1:3', ErrorType.substitution,
            severity: ErrorSeverity.confirmed, attempts: 3,
            expected: 'الرحمن', recognized: 'الرحيم'),
        re('1:2:1', ErrorType.addition, recognized: 'زيادة'),
        re('1:2:2', ErrorType.order, severity: ErrorSeverity.soft, attempts: 2),
        re('1:2:3', ErrorType.pronunciation, severity: ErrorSeverity.flag),
      ];

      final r = buildSessionReport(scope: scope, errors: errors);

      expect(r.forgetSilence.map((e) => e.wordId), equals(['1:1:1']));
      expect(r.forgetManual.map((e) => e.wordId), equals(['1:1:2']));
      expect(r.substitutions.single.wordId, '1:1:3');
      expect(r.substitutions.single.expectedText, 'الرحمن');
      expect(r.substitutions.single.recognizedText, 'الرحيم');
      expect(r.additions.single.recognizedText, 'زيادة');
      expect(r.orderErrors.single.wordId, '1:2:2');
      expect(r.pronunciations.single.wordId, '1:2:3');
      expect(r.forgetCount, 2);
    });

    test('ladder duplicates dedup to the most-escalated entry per word', () {
      final scope = twoAyahScope();
      final errors = [
        re('1:1:1', ErrorType.substitution,
            severity: ErrorSeverity.soft, attempts: 2),
        re('1:1:1', ErrorType.substitution,
            severity: ErrorSeverity.confirmed, attempts: 3),
      ];
      final r = buildSessionReport(scope: scope, errors: errors);
      expect(r.substitutions.length, 1);
      expect(r.substitutions.single.attempts, 3);
      expect(r.substitutions.single.severity, ErrorSeverity.confirmed);
    });

    test('cross-bucket dedup: soft order → confirmed substitution → later '
        'forget appears ONLY in forgetSilence', () {
      final scope = twoAyahScope();
      // Same word 1:2:4 logged three contradictory ways over the session
      // (ladder soft order, ladder confirmed substitution, then re-anchor
      // forget). The forget is logged LAST → it wins the display bucket.
      final errors = [
        re('1:2:4', ErrorType.order,
            severity: ErrorSeverity.soft, attempts: 2),
        re('1:2:4', ErrorType.substitution,
            severity: ErrorSeverity.confirmed, attempts: 3, recognized: 'خطأ'),
        re('1:2:4', ErrorType.forget), // re-anchor / skip, confirmed
      ];
      final r = buildSessionReport(scope: scope, errors: errors);

      // Appears in exactly one bucket — forgetSilence — and nowhere else.
      expect(r.forgetSilence.map((e) => e.wordId), equals(['1:2:4']));
      expect(r.substitutions.any((e) => e.wordId == '1:2:4'), isFalse);
      expect(r.orderErrors.any((e) => e.wordId == '1:2:4'), isFalse);
      expect(r.forgetManual, isEmpty);

      final inBuckets = [
        ...r.forgetSilence,
        ...r.forgetManual,
        ...r.substitutions,
        ...r.additions,
        ...r.orderErrors,
        ...r.pronunciations,
      ].where((e) => e.wordId == '1:2:4').length;
      expect(inBuckets, 1, reason: 'exactly one bucket');

      // Score still counts the word once as confirmed (unchanged).
      expect(r.confirmedErrors, 1);
      expect(r.softErrors, 0);
    });

    test('asrLag lands in its own bucket and is excluded from scoring', () {
      final scope = twoAyahScope(); // 8 words
      final errors = [
        re('1:1:1', ErrorType.asrLag),
        re('1:1:2', ErrorType.asrLag),
        re('1:1:3', ErrorType.forget), // a real confirmed forget
      ];
      final r = buildSessionReport(scope: scope, errors: errors);

      expect(r.asrLag.map((e) => e.wordId), equals(['1:1:1', '1:1:2']));
      // asrLag words appear in NO other bucket.
      expect(r.forgetSilence.map((e) => e.wordId), equals(['1:1:3']));
      expect(r.forgetManual, isEmpty);

      // Only the genuine forget counts toward the score.
      expect(r.confirmedErrors, 1, reason: 'asrLag excluded from confirmed');
      expect(r.score, closeTo(1 - 1 / 8, 1e-9));

      // Per-ayah accuracy ignores asrLag too: ayah 1 has 4 words, only one
      // (the forget) counts as wrong.
      expect(r.perAyah[0].errorWords, 1);
    });
  });

  group('score (confirmed vs soft) + per-ayah accuracy', () {
    test('score penalizes only confirmed; breakdown distinguishes soft', () {
      final scope = twoAyahScope(); // 8 words
      final errors = [
        re('1:1:1', ErrorType.forget), // confirmed
        re('1:1:2', ErrorType.substitution,
            severity: ErrorSeverity.confirmed, attempts: 3),
        re('1:2:1', ErrorType.order,
            severity: ErrorSeverity.soft, attempts: 2), // soft only
        re('1:2:2', ErrorType.pronunciation,
            severity: ErrorSeverity.flag), // not an error
      ];
      final r = buildSessionReport(scope: scope, errors: errors);

      expect(r.totalWords, 8);
      expect(r.confirmedErrors, 2);
      expect(r.softErrors, 1);
      expect(r.score, closeTo(1 - 2 / 8, 1e-9)); // 0.75
    });

    test('per-ayah accuracy uses confirmed errors, preserves scope order', () {
      final scope = twoAyahScope();
      final errors = [
        re('1:1:1', ErrorType.forget), // ayah 1: 1 confirmed
        re('1:1:2', ErrorType.forget), // ayah 1: 2 confirmed
      ];
      final r = buildSessionReport(scope: scope, errors: errors);
      expect(r.perAyah.length, 2);
      expect(r.perAyah[0].surah, 1);
      expect(r.perAyah[0].ayah, 1);
      expect(r.perAyah[0].errorWords, 2);
      expect(r.perAyah[0].accuracy, closeTo(1 - 2 / 4, 1e-9)); // 0.5
      expect(r.perAyah[1].ayah, 2);
      expect(r.perAyah[1].accuracy, 1.0); // no errors in ayah 2
    });

    test('clean session scores 1.0', () {
      final r = buildSessionReport(scope: twoAyahScope(), errors: const []);
      expect(r.score, 1.0);
      expect(r.confirmedErrors, 0);
      expect(r.perAyah.every((a) => a.accuracy == 1.0), isTrue);
    });
  });

  group('weak-item handoff via ReviewService.ingestSession', () {
    test('confirmed errors bump errorCount + recompute mastery; ordered out',
        () async {
      final weak = InMemoryWeakItemRepository();
      final service = ReviewService(
        weakItems: weak,
        plans: InMemoryPlanRepository(),
        history: InMemoryReviewHistoryRepository(),
      );

      // Pre-existing weakness on one word.
      await weak.upsert(WeakItem(
        wordId: '1:1:1', surah: 1, ayah: 1, wordIndex: 1,
        errorCount: 2, lastErrorAt: now - _msPerDay, masteryScore: 0.8,
      ));

      final errors = [
        re('1:1:1', ErrorType.forget, at: now), // confirmed → +1
        re('1:1:2', ErrorType.substitution,
            severity: ErrorSeverity.confirmed, attempts: 3, at: now), // new word
        re('1:1:3', ErrorType.order,
            severity: ErrorSeverity.soft, attempts: 2, at: now), // soft → ignored
        re('1:1:4', ErrorType.pronunciation,
            severity: ErrorSeverity.flag, at: now), // flag → ignored
      ];

      final top = await service.ingestSession(errors: errors, nowMs: now);

      final w1 = await weak.get('1:1:1');
      expect(w1!.errorCount, 3, reason: 'existing 2 + 1 confirmed');
      expect(w1.forgetCount, 1);
      expect(w1.lastErrorAt, now);
      expect(w1.masteryScore, closeTo(1 - 3 / 10, 1e-9)); // 0.7

      final w2 = await weak.get('1:1:2');
      expect(w2!.errorCount, 1);
      expect(w2.masteryScore, closeTo(0.9, 1e-9));

      // soft / flag words were NOT added.
      expect(await weak.get('1:1:3'), isNull);
      expect(await weak.get('1:1:4'), isNull);

      // Returned ordered by errorCount desc.
      expect(top.first.wordId, '1:1:1'); // errorCount 3
      expect(top.length, 2);
    });

    test('asrLag does NOT inflate weak-item error counts', () async {
      final weak = InMemoryWeakItemRepository();
      final service = ReviewService(
        weakItems: weak,
        plans: InMemoryPlanRepository(),
        history: InMemoryReviewHistoryRepository(),
      );

      // A re-anchor skipped these words (logged confirmed asrLag) plus one real
      // confirmed forget. Only the forget should create/raise a weak item.
      final errors = [
        re('1:1:1', ErrorType.asrLag, at: now),
        re('1:1:2', ErrorType.asrLag, at: now),
        re('1:1:3', ErrorType.asrLag, at: now),
        re('1:1:4', ErrorType.forget, at: now), // genuine forget
      ];

      final top = await service.ingestSession(errors: errors, nowMs: now);

      // None of the asrLag words became weak items.
      expect(await weak.get('1:1:1'), isNull);
      expect(await weak.get('1:1:2'), isNull);
      expect(await weak.get('1:1:3'), isNull);

      // The genuine forget is the only weak item.
      final w4 = await weak.get('1:1:4');
      expect(w4!.errorCount, 1);
      expect(top.length, 1);
      expect(top.single.wordId, '1:1:4');
    });
  });

  group('end-to-end: controller log → report → ingest → plan input', () {
    test('a real session produces a report and feeds plan generation', () async {
      final scope = twoAyahScope();
      var clock = now;
      final logger = InMemorySessionLogger();
      final c = RecitationController(
        scope: scope,
        mode: RecitationConfig.normal,
        now: () => clock,
        logger: logger,
      );
      c.start();

      // Recite ayah 1 correctly.
      c.submitAsr(const AsrResult('بسم الله الرحمن الرحيم', 0.95));
      // Ayah 2: two correct, then a confirmed substitution (3 attempts) on رب.
      c.submitAsr(const AsrResult('الحمد لله', 0.95)); // reveals 4,5
      const wrong = AsrResult('زقمون', 0.95);
      c.submitAsr(wrong); // attempt 1 transient
      c.submitAsr(wrong); // attempt 2 soft
      c.submitAsr(wrong); // attempt 3 confirmed
      // Then forget the rest via Reveal Full Ayah.
      c.revealFullAyah();

      final report = buildSessionReport(scope: scope, errors: logger.errors);

      // رب (1:2:3) was substituted (confirmed) then manually revealed; the
      // later manual forget supersedes for display, so it now appears in
      // forgetManual, NOT substitution (cross-bucket dedup). 1:2:4 too.
      expect(report.substitutions.any((e) => e.wordId == '1:2:3'), isFalse);
      expect(report.forgetManual.map((e) => e.wordId),
          containsAll(<String>['1:2:3', '1:2:4']));
      expect(report.confirmedErrors, greaterThan(0));
      expect(report.score, lessThan(1.0));

      // Handoff to weak items, then generate a plan from them.
      final weak = InMemoryWeakItemRepository();
      final service = ReviewService(
        weakItems: weak,
        plans: InMemoryPlanRepository(),
        history: InMemoryReviewHistoryRepository(),
      );
      final top = await service.ingestSession(errors: logger.errors, nowMs: now);
      expect(top, isNotEmpty);

      final plan = await service.rebuildAutoPlan(nowMs: now);
      expect(plan.items, isNotEmpty, reason: 'weak words seed a review plan');
    });
  });
}
