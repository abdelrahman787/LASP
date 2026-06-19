import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';

import '../../app/providers.dart';
import '../../app/widgets/glass.dart';
import '../shell/app_drawer.dart';

/// الإحصائيات — historical/analytical data (C4): weak spots breakdown + session
/// history log. (Time-series charts are a later enhancement.)
class StatsScreen extends ConsumerWidget {
  const StatsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dash = ref.watch(dashboardProvider);
    final history = ref.watch(reviewHistoryListProvider);

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(title: const Text('الإحصائيات')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('سجل الجلسات', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          history.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('خطأ: $e'),
            data: (list) => list.isEmpty
                ? const Text('لا توجد جلسات بعد.')
                : GlassCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (final r in list.take(20))
                          ListTile(
                            dense: true,
                            leading: CircleAvatar(
                              backgroundColor: _scoreColor(theme, r.score)
                                  .withValues(alpha: 0.2),
                              child: Text('${(r.score * 100).round()}',
                                  style: TextStyle(
                                      color: _scoreColor(theme, r.score),
                                      fontSize: 12)),
                            ),
                            title: Text(r.planItemId),
                            subtitle: Text(
                                '${r.confirmedErrors} خطأ من ${r.totalWords} كلمة · '
                                '${_date(r.reviewedAt)}'),
                          ),
                      ],
                    ),
                  ),
          ),
          const SizedBox(height: 20),
          Text('النقاط الضعيفة', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          dash.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('خطأ: $e'),
            data: (data) => _weakSpots(theme, data.weakAyat),
          ),
        ],
      ),
    );
  }

  Widget _weakSpots(ThemeData theme, List<WeakAyah> weakAyat) {
    if (weakAyat.isEmpty) {
      return const Text('لا توجد أخطاء مسجّلة بعد — ابدأ جلسة تسميع.');
    }
    final bySurah = <int, List<WeakAyah>>{};
    for (final w in weakAyat) {
      (bySurah[w.surah] ??= []).add(w);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in bySurah.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 6),
            child: Text('سورة ${entry.key}', style: theme.textTheme.titleSmall),
          ),
          GlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                for (final w in entry.value)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                            width: 56,
                            child: Text('${w.surah}:${w.ayah}',
                                style: theme.textTheme.bodyMedium)),
                        Expanded(child: LiquidProgress(value: w.masteryScore)),
                        const SizedBox(width: 10),
                        StatusChip('${w.totalErrors} خطأ',
                            color: theme.colorScheme.error),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Color _scoreColor(ThemeData theme, double s) {
    if (s >= 0.9) return theme.colorScheme.secondary;
    if (s >= 0.6) return theme.colorScheme.tertiary;
    return theme.colorScheme.error;
  }

  static String _date(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }
}
