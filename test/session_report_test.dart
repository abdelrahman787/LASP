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

      // رب (1:2:3) substitution confirmed; 1:2:3 & 1:2:4 manual-forgotten.
      expect(report.substitutions.any((e) => e.wordId == '1:2:3'), isTrue);
      expect(report.forgetManual.isNotEmpty, isTrue);
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
