import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';

import '../../app/providers.dart';
import '../plans/plans_screen.dart';
import '../recitation/recitation_screen.dart';
import '../review/start_review.dart';
import '../settings/settings_screen.dart';

/// Plans dashboard (Review Plans Phase 3): today's review, weak spots, streak.
/// Functionally wired; visual design comes later.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dash = ref.watch(dashboardProvider);
    final pages = ref.watch(quranRepositoryProvider).pages;

    return Scaffold(
      appBar: AppBar(
        title: const Text('قرآن تسميع'),
        actions: [
          IconButton(
            tooltip: 'تبديل السمة',
            icon: const Icon(Icons.brightness_6),
            onPressed: () {
              final cur = ref.read(themeModeProvider);
              ref.read(themeModeProvider.notifier).state =
                  cur == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
            },
          ),
          IconButton(
            tooltip: 'الخطط',
            icon: const Icon(Icons.list_alt),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const PlansScreen())),
          ),
          IconButton(
            tooltip: 'الإعدادات',
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
          IconButton(
            tooltip: 'تسجيل الخروج',
            icon: const Icon(Icons.logout),
            onPressed: () => ref.read(authServiceProvider).signOut(),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(dashboardProvider),
        child: dash.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('خطأ: $e')),
          data: (data) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _streakStrip(theme, data),
              const SizedBox(height: 12),
              _todaysReviewCard(context, ref, theme, data),
              const SizedBox(height: 16),
              _weakSpots(theme, data),
              const SizedBox(height: 16),
              Text('تسميع صفحة', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in pages.take(20))
                    ActionChip(
                      label: Text('صفحة $p'),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => RecitationScreen(pageNumber: p))),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _streakStrip(ThemeData theme, DashboardData data) {
    return Row(
      children: [
        const Icon(Icons.local_fire_department, color: Colors.orange),
        const SizedBox(width: 6),
        Text('${data.streakDays} يوم متتالٍ', style: theme.textTheme.bodyMedium),
        const Spacer(),
        Text('أُتقن: ${data.weakAyat.where((w) => w.masteryScore >= 0.9).length}',
            style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _todaysReviewCard(
      BuildContext context, WidgetRef ref, ThemeData theme, DashboardData data) {
    final due = data.dueToday;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('مراجعة اليوم', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text('${due.length} عنصر مستحق', style: theme.textTheme.headlineSmall),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: LinearProgressIndicator(value: data.dailyProgress),
                ),
                const SizedBox(width: 8),
                Text('${data.reviewedToday}/${data.dailyTarget}',
                    style: theme.textTheme.bodySmall),
              ],
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('ابدأ المراجعة'),
              onPressed: due.isEmpty
                  ? null
                  : () => startReview(context, ref,
                      planId: data.autoPlan.id, item: due.first),
            ),
          ],
        ),
      ),
    );
  }

  Widget _weakSpots(ThemeData theme, DashboardData data) {
    // Group weak ayat by surah, preserving the global weaknessScore desc order.
    final bySurah = <int, List<WeakAyah>>{};
    for (final w in data.weakAyat) {
      (bySurah[w.surah] ??= []).add(w);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('النقاط الضعيفة', style: theme.textTheme.titleMedium),
        if (data.weakAyat.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 16),
            child: Text('لا توجد أخطاء مسجّلة بعد — ابدأ جلسة تسميع.'),
          ),
        for (final entry in bySurah.entries) ...[
          Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 2),
            child: Text('سورة ${entry.key}',
                style: theme.textTheme.titleSmall),
          ),
          for (final w in entry.value)
            ListTile(
              dense: true,
              title: Text('${w.surah}:${w.ayah}'),
              subtitle: LinearProgressIndicator(value: w.masteryScore),
              trailing: Text('${w.totalErrors} خطأ'),
            ),
        ],
      ],
    );
  }
}
