import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/plan_service.dart';

import '../../app/providers.dart';
import '../review/start_review.dart';

/// Lists plans and supports custom-plan creation (Review Plans Phase 5).
class PlansScreen extends ConsumerWidget {
  const PlansScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final plans = ref.watch(plansListProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الخطط')),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('خطة مخصّصة'),
        onPressed: () => _showCreateDialog(context, ref),
      ),
      body: plans.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('خطأ: $e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('لا توجد خطط بعد.'))
            : ListView(
                children: [
                  for (final p in list)
                    Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: ListTile(
                        title: Text(p.name),
                        subtitle: Text(
                            '${p.items.length} عنصر · الهدف اليومي ${p.dailyTarget}'),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline),
                          onPressed: () async {
                            await ref
                                .read(planServiceProvider)
                                .deletePlan(p.id);
                            ref.invalidate(plansListProvider);
                          },
                        ),
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => PlanDetailScreen(planId: p.id)),
                        ),
                      ),
                    ),
                ],
              ),
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
          return ListView(
            children: [
              for (final item in plan.items)
                ListTile(
                  title: Text(item.isRange
                      ? '${item.surah}:${item.ayah}-${item.ayahEnd}'
                      : '${item.surah}:${item.ayah}'),
                  subtitle: Text('الحالة: ${_statusLabels[item.status]} · '
                      'الفاصل ${item.intervalDays}ي · ${_due(item.dueAt, now)}'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'ابدأ المراجعة',
                        icon: const Icon(Icons.play_arrow),
                        onPressed: () =>
                            startReview(context, ref, planId: plan.id, item: item),
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
                ),
            ],
          );
        },
      ),
    );
  }
}
