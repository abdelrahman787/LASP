/// Post-session report (spec Phase 6). Pure Dart, built entirely from the
/// session's [RecordedError] log + the recitation scope. No Flutter/Firebase.
///
/// It groups mistakes into the five Arabic categories, computes a session
/// score (penalizing only *confirmed* errors) with a soft/confirmed breakdown,
/// and reports per-ayah accuracy. The weak-item handoff to the review feature
/// lives in `ReviewService.ingestSession` (review layer).
library;

import 'matching_engine.dart';
import 'recitation_controller.dart';

/// One row in a report bucket — a single word's mistake.
class ReportEntry {
  final String wordId;
  final int surah;
  final int ayah;
  final int wordIndex;
  final String expectedText;
  final String? recognizedText;
  final ErrorType errorType;
  final ErrorSeverity severity;
  final bool manualReveal;
  final int attempts;

  const ReportEntry({
    required this.wordId,
    required this.surah,
    required this.ayah,
    required this.wordIndex,
    required this.expectedText,
    required this.recognizedText,
    required this.errorType,
    required this.severity,
    required this.manualReveal,
    required this.attempts,
  });

  @override
  String toString() => 'ReportEntry($wordId ${errorType.wire}/${severity.name})';
}

/// Accuracy for one ayah in the scope.
class AyahAccuracy {
  final int surah;
  final int ayah;
  final int totalWords;
  final int errorWords; // distinct words with a confirmed error
  final double accuracy; // 0..1

  const AyahAccuracy({
    required this.surah,
    required this.ayah,
    required this.totalWords,
    required this.errorWords,
    required this.accuracy,
  });

  @override
  String toString() =>
      'AyahAccuracy($surah:$ayah ${(accuracy * 100).round()}% '
      '($errorWords/$totalWords wrong))';
}

/// The full session report.
class SessionReport {
  // نسيان (forget) — split by source so the UI can flag "not memorized".
  final List<ReportEntry> forgetSilence; // from the 10s silence timer
  final List<ReportEntry> forgetManual; // from Reveal Next / Full Ayah

  /// استبدال (substitution) — wrong word; carries expected vs recognized.
  final List<ReportEntry> substitutions;

  /// زيادة (addition) — out-of-ayah inserted words.
  final List<ReportEntry> additions;

  /// خطأ ترتيب (order) — correct word, wrong position.
  final List<ReportEntry> orderErrors;

  /// نطق (pronunciation) — low-confidence accepts (correct but flagged).
  final List<ReportEntry> pronunciations;

  /// تأخر تعرف (asr lag) — words a re-anchor jumped over because the ASR fell
  /// behind the reciter. NOT a memorization mistake: surfaced for transparency
  /// but deliberately excluded from [score], [confirmedErrors], per-ayah
  /// accuracy, and weak-item aggregation.
  final List<ReportEntry> asrLag;

  final int totalWords;

  /// Distinct words whose worst recorded mistake is confirmed (attempt 3+,
  /// silence forget, manual reveal, or addition).
  final int confirmedErrors;

  /// Distinct words whose worst recorded mistake is soft (attempt 2) and not
  /// also confirmed.
  final int softErrors;

  /// `1 - confirmedErrors / totalWords`, clamped to `[0,1]`.
  final double score;

  final List<AyahAccuracy> perAyah;

  const SessionReport({
    required this.forgetSilence,
    required this.forgetManual,
    required this.substitutions,
    required this.additions,
    required this.orderErrors,
    required this.pronunciations,
    required this.asrLag,
    required this.totalWords,
    required this.confirmedErrors,
    required this.softErrors,
    required this.score,
    required this.perAyah,
  });

  /// All forgets (silence + manual) — convenience for the نسيان header count.
  int get forgetCount => forgetSilence.length + forgetManual.length;
}

int _severityRank(ErrorSeverity s) {
  switch (s) {
    case ErrorSeverity.confirmed:
      return 3;
    case ErrorSeverity.soft:
      return 2;
    case ErrorSeverity.flag:
      return 1;
    case ErrorSeverity.transient:
      return 0;
  }
}

/// Build the [SessionReport] from the scope + the session's error log.
SessionReport buildSessionReport({
  required List<ExpectedWord> scope,
  required List<RecordedError> errors,
}) {
  final byId = {for (final w in scope) w.wordId: w};

  ReportEntry toEntry(RecordedError e) {
    final w = byId[e.wordId];
    int surah, ayah, wordIndex;
    if (w != null) {
      surah = w.surah;
      ayah = w.ayah;
      wordIndex = w.wordIndex;
    } else {
      // Fallback: parse "<surah>:<ayah>:<wordIndex>".
      final parts = e.wordId.split(':');
      surah = parts.length > 0 ? int.tryParse(parts[0]) ?? 0 : 0;
      ayah = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      wordIndex = parts.length > 2 ? int.tryParse(parts[2]) ?? 0 : 0;
    }
    return ReportEntry(
      wordId: e.wordId,
      surah: surah,
      ayah: ayah,
      wordIndex: wordIndex,
      expectedText: e.expectedText,
      recognizedText: e.recognizedText,
      errorType: e.errorType,
      severity: e.severity,
      manualReveal: e.manualReveal,
      attempts: e.attempts,
    );
  }

  final forgetSilence = <ReportEntry>[];
  final forgetManual = <ReportEntry>[];
  final substitutions = <ReportEntry>[];
  final additions = <ReportEntry>[];
  final orderErrors = <ReportEntry>[];
  final pronunciations = <ReportEntry>[];
  final asrLag = <ReportEntry>[];

  // Track the worst severity per distinct word (for the score) and the single
  // display winner per word (the LAST-logged error wins — clock-independent,
  // so a later re-anchor forget supersedes an earlier order/substitution).
  final worstByWord = <String, ErrorSeverity>{};
  final displayWinner = <String, RecordedError>{};

  for (final e in errors) {
    if (e.severity == ErrorSeverity.transient) {
      // Attempt-1 transient errors are not persisted in normal flow; ignore
      // them defensively if a caller passes them in.
      continue;
    }
    // asrLag is not a mistake — it must NOT contribute to the score, the
    // confirmed/soft counts, or per-ayah accuracy. Keep it out of worstByWord
    // entirely, but still let it win the display bucket if it's the last word
    // classification (so the transparency bucket is populated).
    if (e.errorType != ErrorType.asrLag) {
      final prev = worstByWord[e.wordId];
      if (prev == null || _severityRank(e.severity) > _severityRank(prev)) {
        worstByWord[e.wordId] = e.severity;
      }
    }
    displayWinner[e.wordId] = e; // last occurrence wins
  }

  // Route each word's winner to exactly ONE bucket, so a word never appears in
  // multiple buckets in the human-readable report. Insertion order of words is
  // preserved.
  for (final e in displayWinner.values) {
    final entry = toEntry(e);
    switch (e.errorType) {
      case ErrorType.forget:
        (e.manualReveal ? forgetManual : forgetSilence).add(entry);
        break;
      case ErrorType.substitution:
        substitutions.add(entry);
        break;
      case ErrorType.addition:
        additions.add(entry);
        break;
      case ErrorType.order:
        orderErrors.add(entry);
        break;
      case ErrorType.pronunciation:
        pronunciations.add(entry);
        break;
      case ErrorType.asrLag:
        asrLag.add(entry);
        break;
    }
  }

  // Score breakdown: count distinct words by worst severity.
  var confirmed = 0;
  var soft = 0;
  for (final sev in worstByWord.values) {
    if (sev == ErrorSeverity.confirmed) confirmed++;
    if (sev == ErrorSeverity.soft) soft++;
  }

  final totalWords = scope.length;
  final raw = totalWords <= 0 ? 1.0 : 1.0 - confirmed / totalWords;
  final score = raw < 0.0 ? 0.0 : (raw > 1.0 ? 1.0 : raw);

  // Per-ayah accuracy (based on confirmed errors, consistent with the score).
  final confirmedWords = <String>{
    for (final e in worstByWord.entries)
      if (e.value == ErrorSeverity.confirmed) e.key,
  };

  // Preserve scope order of ayat.
  final ayahOrder = <String>[];
  final ayahTotals = <String, int>{};
  final ayahErrs = <String, int>{};
  for (final w in scope) {
    final key = '${w.surah}:${w.ayah}';
    if (!ayahTotals.containsKey(key)) {
      ayahOrder.add(key);
      ayahTotals[key] = 0;
      ayahErrs[key] = 0;
    }
    ayahTotals[key] = ayahTotals[key]! + 1;
    if (confirmedWords.contains(w.wordId)) {
      ayahErrs[key] = ayahErrs[key]! + 1;
    }
  }

  final perAyah = <AyahAccuracy>[];
  for (final key in ayahOrder) {
    final parts = key.split(':');
    final total = ayahTotals[key]!;
    final errs = ayahErrs[key]!;
    final acc = total <= 0 ? 1.0 : 1.0 - errs / total;
    perAyah.add(AyahAccuracy(
      surah: int.parse(parts[0]),
      ayah: int.parse(parts[1]),
      totalWords: total,
      errorWords: errs,
      accuracy: acc < 0 ? 0 : (acc > 1 ? 1 : acc),
    ));
  }

  return SessionReport(
    forgetSilence: forgetSilence,
    forgetManual: forgetManual,
    substitutions: substitutions,
    additions: additions,
    orderErrors: orderErrors,
    pronunciations: pronunciations,
    asrLag: asrLag,
    totalWords: totalWords,
    confirmedErrors: confirmed,
    softErrors: soft,
    score: score,
    perAyah: perAyah,
  );
}
