import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';
import 'package:quran_tasmee3_core/recitation/session_report.dart';
import 'package:test/test.dart';

List<ExpectedWord> _buildScope(int a1, int a2) {
  final scope = <ExpectedWord>[];
  for (var i = 0; i < a1; i++) {
    scope.add(ExpectedWord(
      wordId: '2:1:$i',
      surah: 2,
      ayah: 1,
      wordIndex: i,
      norm: 'w1_$i',
      display: 'w1d_$i',
    ));
  }
  for (var i = 0; i < a2; i++) {
    scope.add(ExpectedWord(
      wordId: '2:2:$i',
      surah: 2,
      ayah: 2,
      wordIndex: i,
      norm: 'w2_$i',
      display: 'w2d_$i',
    ));
  }
  return scope;
}

RecordedError _forget(ExpectedWord w) => RecordedError(
      wordId: w.wordId,
      expectedText: w.display,
      recognizedText: null,
      errorType: ErrorType.forget,
      confidence: 0.0,
      attempts: 0,
      manualReveal: false,
      severity: ErrorSeverity.confirmed,
      createdAt: 0,
    );

void main() {
  group('unattempted-word scoring', () {
    test('reading nothing of ayah 2 must NOT yield 100%', () {
      final scope = _buildScope(3, 3);

      final errors = [
        for (final w in scope.where((w) => w.ayah == 2)) _forget(w),
      ];

      final report = buildSessionReport(scope: scope, errors: errors);

      expect(report.totalWords, 6);
      expect(report.confirmedErrors, 3);
      expect(report.score, lessThan(1.0));
      expect(report.score, closeTo(0.5, 0.001));

      final ayah2 = report.perAyah.firstWhere((a) => a.ayah == 2);
      expect(ayah2.accuracy, lessThan(1.0));
    });

    test('reading everything clean still yields 100%', () {
      final scope = _buildScope(3, 3);
      final report = buildSessionReport(scope: scope, errors: const []);
      expect(report.score, 1.0);
    });
  });
}