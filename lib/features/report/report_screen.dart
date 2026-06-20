import 'package:flutter/material.dart';

import 'package:quran_tasmee3_core/recitation/session_report.dart';

import '../../app/widgets/glass.dart';
import '../recitation/recitation_screen.dart';

/// Post-session report (spec Phase 6): score, per-ayah accuracy, and the five
/// Arabic error categories.
class ReportScreen extends StatelessWidget {
  final SessionReport report;

  /// Optional "review complete" banner (Phase 4 loop closure).
  final String? summary;

  /// When set (page recitation, not a review), offer to continue onto this
  /// page (mushaf page-chaining).
  final int? continuePage;
  const ReportScreen(
      {super.key, required this.report, this.summary, this.continuePage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('تقرير الجلسة'),
        leading: IconButton(
          icon: const Icon(Icons.home),
          onPressed: () =>
              Navigator.of(context).popUntil((r) => r.isFirst),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (summary != null) ...[
            GlassCard(
              fill: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
              child: Row(
                children: [
                  Icon(Icons.check_circle, color: theme.colorScheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(summary!)),
                ],
              ),
            ),
            const SizedBox(height: 12),
          ],
          GlassCard(
            padding: const EdgeInsets.all(20),
            child: Row(
              children: [
                _DonutScore(value: report.score),
                const SizedBox(width: 20),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('التقييم', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          StatusChip('مؤكدة: ${report.confirmedErrors}',
                              color: theme.colorScheme.error),
                          StatusChip('مبدئية: ${report.softErrors}',
                              color: theme.colorScheme.tertiary),
                          StatusChip('كلمات: ${report.totalWords}',
                              color: theme.colorScheme.secondary),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text('الدقة لكل آية', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          // Color-coded ayah-sequence strip.
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final a in report.perAyah)
                StatusChip('${a.ayah} · ${(a.accuracy * 100).round()}%',
                    color: _accuracyColor(theme, a.accuracy)),
            ],
          ),
          const SizedBox(height: 16),
          _Bucket('نسيان (المؤقّت)', report.forgetSilence),
          _Bucket('نسيان (كشف يدوي)', report.forgetManual),
          _Bucket('استبدال', report.substitutions, showExpectedVsRecognized: true),
          _Bucket('زيادة', report.additions, showRecognized: true),
          _Bucket('خطأ ترتيب', report.orderErrors),
          _Bucket('نطق', report.pronunciations),
          _Bucket('تأخر تعرف', report.asrLag, subtitleNote: true),
          if (continuePage != null) ...[
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.arrow_back), // RTL: points to "next"
              label: Text('الاستمرار لقراءة الصفحة $continuePage'),
              onPressed: () => Navigator.of(context).pushReplacement(
                MaterialPageRoute(
                    builder: (_) =>
                        RecitationScreen(pageNumber: continuePage!)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Color _accuracyColor(ThemeData theme, double acc) {
    if (acc >= 0.9) return theme.colorScheme.secondary;
    if (acc >= 0.6) return theme.colorScheme.tertiary;
    return theme.colorScheme.error;
  }
}

/// Radial donut score gauge with the percentage centered inside (per mockup).
class _DonutScore extends StatelessWidget {
  final double value; // 0..1
  const _DonutScore({required this.value});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (value.clamp(0.0, 1.0) * 100).round();
    return SizedBox(
      width: 96,
      height: 96,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: 96,
            height: 96,
            child: CircularProgressIndicator(
              value: value.clamp(0.0, 1.0),
              strokeWidth: 10,
              strokeCap: StrokeCap.round,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
              valueColor:
                  AlwaysStoppedAnimation<Color>(theme.colorScheme.secondary),
            ),
          ),
          Text('$pct%',
              style: theme.textTheme.headlineSmall
                  ?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }
}

class _Bucket extends StatelessWidget {
  final String title;
  final List<ReportEntry> entries;
  final bool showExpectedVsRecognized;
  final bool showRecognized;

  /// Shows an explanatory note that this bucket is informational only (used for
  /// "تأخر تعرف" / asrLag — these are NOT counted as mistakes).
  final bool subtitleNote;
  const _Bucket(
    this.title,
    this.entries, {
    this.showExpectedVsRecognized = false,
    this.showRecognized = false,
    this.subtitleNote = false,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        padding: EdgeInsets.zero,
        child: ExpansionTile(
          shape: const Border(),
          title: Text('$title (${entries.length})'),
          subtitle: subtitleNote
              ? Text(
                  'تخطّاها النظام لتأخر التعرّف — لا تُحتسب ضمن الأخطاء',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                )
              : null,
          children: [
          for (final e in entries)
            ListTile(
              dense: true,
              title: Text(e.expectedText.isEmpty ? e.wordId : e.expectedText),
              subtitle: showExpectedVsRecognized
                  ? Text('المتوقع: ${e.expectedText} · المسموع: ${e.recognizedText ?? '—'}')
                  : showRecognized
                      ? Text('المسموع: ${e.recognizedText ?? '—'}')
                      : Text(e.wordId),
            ),
          ],
        ),
      ),
    );
  }
}
