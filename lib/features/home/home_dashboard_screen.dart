import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';

import '../../app/providers.dart';
import '../../app/widgets/glass.dart';
import '../mushaf/mushaf_index_screen.dart';
import '../mushaf/mushaf_reader_screen.dart';
import '../plans/plans_screen.dart';
import '../review/start_review.dart';
import '../shell/app_drawer.dart';

/// الرئيسية — the landing screen (C1): اليوم section (continue + summary +
/// streak) and the active-plans progress section.
class HomeDashboardScreen extends ConsumerWidget {
  const HomeDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final dash = ref.watch(dashboardProvider);
    final plans = ref.watch(plansListProvider);

    return Scaffold(
      drawer: const AppDrawer(),
      appBar: AppBar(
        title: const Text('القرآن الكريم'),
        actions: [
          IconButton(
            tooltip: 'الفهرس',
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: () async {
              final page = await Navigator.of(context).push<int>(
                  MaterialPageRoute(builder: (_) => const MushafIndexScreen()));
              if (page != null && context.mounted) {
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => MushafReaderScreen(initialPage: page)));
              }
            },
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(dashboardProvider);
          ref.invalidate(plansListProvider);
        },
        child: dash.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('خطأ: $e')),
          data: (data) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('اليوم', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              _continueCard(context, ref, theme, data),
              const SizedBox(height: 12),
              _todaySummary(theme, data),
              const SizedBox(height: 20),
              Text('خططي', style: theme.textTheme.titleLarge),
              const SizedBox(height: 8),
              plans.when(
                loading: () =>
                    const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
                error: (e, _) => Text('خطأ: $e'),
                data: (list) => list.isEmpty
                    ? const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('لا توجد خطط نشطة بعد.'))
                    : Column(
                        children: [
                          for (final p in list)
                            _planCard(context, ref, theme, p, data),
                        ],
                      ),
              ),
              const SizedBox(height: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.add),
                label: const Text('إدارة الخطط'),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const PlansScreen())),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _continueCard(
      BuildContext context, WidgetRef ref, ThemeData theme, DashboardData data) {
    final due = data.dueToday;
    return GlassCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('إكمال التسميع', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text(
            'التقدّم العام: ${(data.overallProgress * 100).round()}%'
            ' (${data.masteredItems}/${data.totalItems} متقَن)',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 12),
          LiquidProgress(value: data.overallProgress, height: 12),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('استمر في التسميع'),
              onPressed: due.isEmpty
                  ? null
                  : () => startReview(context, ref,
                      planId: data.autoPlan.id, item: due.first),
            ),
          ),
        ],
      ),
    );
  }

  Widget _todaySummary(ThemeData theme, DashboardData data) {
    final last = data.lastScore;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.local_fire_department, color: Color(0xFFF59B63)),
              const SizedBox(width: 6),
              Text('${data.streakDays} يوم متتالٍ',
                  style: theme.textTheme.bodyMedium),
              const Spacer(),
              if (last != null)
                Text('آخر تقييم: ${(last * 100).round()}%',
                    style: theme.textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: LiquidProgress(value: data.dailyProgress)),
              const SizedBox(width: 8),
              Text('${data.reviewedToday}/${data.dailyTarget} اليوم',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ],
      ),
    );
  }

  Widget _planCard(BuildContext context, WidgetRef ref, ThemeData theme,
      ReviewPlan plan, DashboardData data) {
    final total = plan.items.length;
    final mastered =
        plan.items.where((i) => i.status == PlanItemStatus.mastered).length;
    final progress = total == 0 ? 0.0 : mastered / total;
    final due = plan.items.where((i) => i.dueAt <= DateTime.now().millisecondsSinceEpoch).toList();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GlassCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text(plan.name, style: theme.textTheme.titleMedium)),
                StatusChip('مراجعة', color: theme.colorScheme.secondary),
              ],
            ),
            const SizedBox(height: 8),
            LiquidProgress(value: progress),
            const SizedBox(height: 6),
            Row(
              children: [
                Text('${(progress * 100).round()}% · ${due.length} مستحق اليوم',
                    style: theme.textTheme.bodySmall),
                const Spacer(),
                TextButton(
                  onPressed: due.isEmpty
                      ? null
                      : () => startReview(context, ref,
                          planId: plan.id, item: due.first),
                  child: const Text('ابدأ ←'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
