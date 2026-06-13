import 'package:flutter/material.dart';

import 'package:quran_tasmee3_core/recitation/session_report.dart';

/// Post-session report (spec Phase 6): score, per-ayah accuracy, and the five
/// Arabic error categories.
class ReportScreen extends StatelessWidget {
  final SessionReport report;
  const ReportScreen({super.key, required this.report});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pct = (report.score * 100).round();
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
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('التقييم', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 8),
                  Text('$pct%', style: theme.textTheme.displaySmall),
                  const SizedBox(height: 4),
                  Text(
                    'أخطاء مؤكدة: ${report.confirmedErrors} · '
                    'أخطاء مبدئية: ${report.softErrors} · '
                    'إجمالي الكلمات: ${report.totalWords}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text('الدقة لكل آية', style: theme.textTheme.titleMedium),
          for (final a in report.perAyah)
            ListTile(
              dense: true,
              title: Text('${a.surah}:${a.ayah}'),
              trailing: Text('${(a.accuracy * 100).round()}%'),
              subtitle: LinearProgressIndicator(value: a.accuracy),
            ),
          const SizedBox(height: 8),
          _Bucket('نسيان (المؤقّت)', report.forgetSilence),
          _Bucket('نسيان (كشف يدوي)', report.forgetManual),
          _Bucket('استبدال', report.substitutions, showExpectedVsRecognized: true),
          _Bucket('زيادة', report.additions, showRecognized: true),
          _Bucket('خطأ ترتيب', report.orderErrors),
          _Bucket('نطق', report.pronunciations),
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
  const _Bucket(
    this.title,
    this.entries, {
    this.showExpectedVsRecognized = false,
    this.showRecognized = false,
  });

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ExpansionTile(
        title: Text('$title (${entries.length})'),
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
    );
  }
}
