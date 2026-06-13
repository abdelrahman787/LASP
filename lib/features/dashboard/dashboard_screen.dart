import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../plans/plans_screen.dart';
import '../recitation/recitation_screen.dart';
import '../settings/settings_screen.dart';

/// Plans dashboard (Review Plans Phase 3): today's review, weak spots.
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
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('مراجعة اليوم', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Text('${data.dueToday.length} عنصر مستحق',
                          style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('ابدأ المراجعة'),
                        onPressed: pages.isEmpty
                            ? null
                            : () => Navigator.of(context).push(MaterialPageRoute(
                                builder: (_) =>
                                    RecitationScreen(pageNumber: pages.first))),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text('تسميع صفحة', style: theme.textTheme.titleMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 8,
                children: [
                  for (final p in pages)
                    ActionChip(
                      label: Text('صفحة $p'),
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => RecitationScreen(pageNumber: p))),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text('النقاط الضعيفة', style: theme.textTheme.titleMedium),
              if (data.weakAyat.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Text('لا توجد أخطاء مسجّلة بعد — ابدأ جلسة تسميع.'),
                ),
              for (final w in data.weakAyat)
                ListTile(
                  title: Text('${w.surah}:${w.ayah}'),
                  subtitle: LinearProgressIndicator(value: w.masteryScore),
                  trailing: Text('${w.totalErrors} خطأ'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
