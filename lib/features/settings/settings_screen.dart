import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

import '../../app/providers.dart';
import '../../app/widgets/glass.dart';

/// Edits [UserSettings] — the scheduler/aggregation knobs (Review Plans Phase 5).
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(settingsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('الإعدادات')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('خطأ: $e')),
        data: (s) => _SettingsForm(settings: s),
      ),
    );
  }
}

class _SettingsForm extends ConsumerStatefulWidget {
  final UserSettings settings;
  const _SettingsForm({required this.settings});

  @override
  ConsumerState<_SettingsForm> createState() => _SettingsFormState();
}

class _SettingsFormState extends ConsumerState<_SettingsForm> {
  late UserSettings _s = widget.settings;

  Widget _sliderCard(String title, String value, double v, double min,
      double max, int divisions, ValueChanged<double> onChanged) {
    final theme = Theme.of(context);
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(title, style: theme.textTheme.titleSmall),
              Text(value, style: theme.textTheme.titleSmall),
            ],
          ),
          Slider(
            min: min,
            max: max,
            divisions: divisions,
            value: v,
            label: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _sliderCard('الهدف اليومي', '${_s.dailyTarget}', _s.dailyTarget.toDouble(),
            1, 50, 49, (v) => setState(() => _s = _s.copyWith(dailyTarget: v.round()))),
        const SizedBox(height: 12),
        _sliderCard('عتبة الضعف', _s.weaknessThreshold.toStringAsFixed(1),
            _s.weaknessThreshold, 0.5, 10, 19,
            (v) => setState(() => _s = _s.copyWith(weaknessThreshold: v))),
        const SizedBox(height: 12),
        _sliderCard('أفق الإتقان (أيام)', '${_s.masteryHorizonDays}',
            _s.masteryHorizonDays.toDouble(), 7, 90, 83,
            (v) => setState(() => _s = _s.copyWith(masteryHorizonDays: v.round()))),
        const SizedBox(height: 12),
        GlassCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('وضع التسميع الافتراضي', style: theme.textTheme.titleSmall),
              const SizedBox(height: 12),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: ModeSelector<RecitationMode>(
                  selected: _s.defaultMode,
                  onChanged: (m) => setState(() => _s = _s.copyWith(defaultMode: m)),
                  options: const [
                    (value: RecitationMode.easy, label: 'سهل'),
                    (value: RecitationMode.normal, label: 'عادي'),
                    (value: RecitationMode.strict, label: 'صارم'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        GlassCard(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SwitchListTile(
            title: const Text('دمج الآيات المتتالية'),
            value: _s.mergeContiguous,
            onChanged: (v) =>
                setState(() => _s = _s.copyWith(mergeContiguous: v)),
          ),
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () async {
            await ref.read(settingsProvider.notifier).save(_s);
            ref.invalidate(dashboardProvider);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('تم الحفظ')),
              );
            }
          },
          child: const Text('حفظ'),
        ),
      ],
    );
  }
}
