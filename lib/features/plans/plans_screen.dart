import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart';

import '../../app/providers.dart';
import '../../app/widgets/glass.dart';
import '../review/start_review.dart';
import '../shell/app_drawer.dart';

/// Lists plans and supports custom-plan creation (Review Plans Phase 5).
class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // C3: three plan types. مراجعة is built; حفظ/تسميع are scheduled features
    // (their scheduling logic is a separate task) — shown as clear placeholders.
    return DefaultTabController(
      length: 3,
      initialIndex: 1,
      child: Scaffold(
        drawer: const AppDrawer(),
        appBar: AppBar(
          title: const Text('الخطط'),
          bottom: const TabBar(
            tabs: [Tab(text: 'حفظ'), Tab(text: 'مراجعة'), Tab(text: 'تسميع')],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add),
          label: const Text('خطة مخصّصة'),
          onPressed: () => _showCreateDialog(context, ref),
        ),
        body: TabBarView(
          children: [
            _comingSoon(context,
                'خطط الحفظ', 'حدّد نطاقًا جديدًا لحفظه (سورة/جزء/صفحات) وهدفًا يوميًا.'),
            _reviewList(context, ref),
            _comingSoon(context, 'خطط التسميع',
                'جلسات تسميع مجدولة لما حفظته سابقًا، باختيار نطاق وفترة تكرار.'),
          ],
        ),
      ),
    );
  }

  Widget _comingSoon(BuildContext context, String title, String desc) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.hourglass_empty, size: 64, color: theme.colorScheme.outline),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text('$desc\n(قريبًا)',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }

  Widget _reviewList(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(plansListProvider);
    return plans.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('خطأ: $e')),
      data: (list) => list.isEmpty
          ? const Center(child: Text('لا توجد خطط مراجعة بعد.'))
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
              children: [
                for (final p in list)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: GlassCard(
                      padding: EdgeInsets.zero,
                      child: ListTile(
                        title: Text(p.name),
                        subtitle: Text(
                            '${p.items.length} عنصر · الهدف اليومي ${p.dailyTarget}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await ref.read(planServiceProvider).deletePlan(p.id);
                            ref.invalidate(plansListProvider);
                          },
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => PlanDetailScreen(planId: p.id)),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    var type = RangeType.surah;
    final startCtrl = TextEditingController(text: '1');
    final endCtrl = TextEditingController(text: '1');
    final targetCtrl = TextEditingController(text: '10');

    showDialog<void>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('إنشاء خطة مخصّصة'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<RangeType>(
                initialValue: type,
                decoration: const InputDecoration(labelText: 'النوع'),
                items: const [
                  DropdownMenuItem(value: RangeType.surah, child: Text('سورة')),
                  DropdownMenuItem(value: RangeType.juz, child: Text('جزء')),
                  DropdownMenuItem(value: RangeType.page, child: Text('صفحة')),
                  DropdownMenuItem(
                      value: RangeType.ayahRange, child: Text('نطاق آيات')),
                ],
                onChanged: (v) => setState(() => type = v ?? RangeType.surah),
              ),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: startCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'من'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: endCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'إلى'),
                    ),
                  ),
                ],
              ),
              TextField(
                controller: targetCtrl,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'الهدف اليومي'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () async {
                final start = int.tryParse(startCtrl.text) ?? 1;
                final end = int.tryParse(endCtrl.text) ?? start;
                final target = int.tryParse(targetCtrl.text);
                await ref.read(planServiceProvider).createCustomPlan(
                      type: type,
                      start: start,
                      end: end,
                      dailyTarget: target,
                    );
                ref.invalidate(plansListProvider);
                if (context.mounted) Navigator.pop(context);
              },
              child: const Text('إنشاء'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Plan detail with per-item snooze/reset (Review Plans Phase 4/5).
class PlanDetailScreen extends ConsumerWidget {
  final String planId;
  const PlanDetailScreen({super.key, required this.planId});

  static const _statusLabels = {
    PlanItemStatus.newItem: 'جديد',
    PlanItemStatus.due: 'مستحق',
    PlanItemStatus.scheduled: 'مجدول',
    PlanItemStatus.mastered: 'متقَن',
  };

  static String _due(int dueAt, int now) {
    if (dueAt <= now) return 'مستحق الآن';
    final days = ((dueAt - now) / 86400000).ceil();
    return 'بعد $days يوم';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plansAsync = ref.watch(plansListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('تفاصيل الخطة')),
      body: plansAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('خطأ: $e')),
        data: (list) {
          final plan = list.where((p) => p.id == planId).firstOrNull;
          if (plan == null) {
            return const Center(child: Text('الخطة غير موجودة.'));
          }
          final now = DateTime.now().millisecondsSinceEpoch;
          final theme = Theme.of(context);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Header — clean vertical stacking, no overlapping text (correction #4).
              GlassCard(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(plan.name, style: theme.textTheme.titleLarge),
                    const SizedBox(height: 6),
                    Text(
                      '${plan.items.length} عنصر · الهدف اليومي ${plan.dailyTarget}',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              for (final item in plan.items)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                item.isRange
                                    ? '${item.surah}:${item.ayah}-${item.ayahEnd}'
                                    : '${item.surah}:${item.ayah}',
                                style: theme.textTheme.titleMedium,
                              ),
                            ),
                            StatusChip(_statusLabels[item.status] ?? '',
                                color: _statusColor(theme, item.status)),
                          ],
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'الفاصل ${item.intervalDays}ي · ${_due(item.dueAt, now)}',
                          style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              tooltip: 'ابدأ المراجعة',
                              icon: const Icon(Icons.play_arrow),
                              onPressed: () => startReview(context, ref,
                                  planId: plan.id, item: item),
                            ),
                            IconButton(
                              tooltip: 'تأجيل ٣ أيام',
                              icon: const Icon(Icons.snooze),
                              onPressed: () async {
                                await ref
                                    .read(planServiceProvider)
                                    .snoozePlanItem(plan.id, item.id, 3);
                                ref.invalidate(plansListProvider);
                              },
                            ),
                            IconButton(
                              tooltip: 'إعادة تعيين',
                              icon: const Icon(Icons.restart_alt),
                              onPressed: () async {
                                await ref
                                    .read(planServiceProvider)
                                    .resetPlanItem(plan.id, item.id);
                                ref.invalidate(plansListProvider);
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  static Color _statusColor(ThemeData theme, PlanItemStatus s) {
    switch (s) {
      case PlanItemStatus.mastered:
        return theme.colorScheme.secondary;
      case PlanItemStatus.due:
        return theme.colorScheme.error;
      case PlanItemStatus.scheduled:
        return theme.colorScheme.primary;
      case PlanItemStatus.newItem:
        return theme.colorScheme.tertiary;
    }
  }
}
