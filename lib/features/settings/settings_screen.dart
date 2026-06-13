import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

import '../../app/providers.dart';

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

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: const Text('الهدف اليومي'),
          trailing: Text('${_s.dailyTarget}'),
        ),
        Slider(
          min: 1,
          max: 50,
          divisions: 49,
          value: _s.dailyTarget.toDouble(),
          label: '${_s.dailyTarget}',
          onChanged: (v) =>
              setState(() => _s = _s.copyWith(dailyTarget: v.round())),
        ),
        const Divider(),
        ListTile(
          title: const Text('عتبة الضعف'),
          trailing: Text(_s.weaknessThreshold.toStringAsFixed(1)),
        ),
        Slider(
          min: 0.5,
          max: 10,
          divisions: 19,
          value: _s.weaknessThreshold,
          label: _s.weaknessThreshold.toStringAsFixed(1),
          onChanged: (v) =>
              setState(() => _s = _s.copyWith(weaknessThreshold: v)),
        ),
        const Divider(),
        ListTile(
          title: const Text('أفق الإتقان (أيام)'),
          trailing: Text('${_s.masteryHorizonDays}'),
        ),
        Slider(
          min: 7,
          max: 90,
          divisions: 83,
          value: _s.masteryHorizonDays.toDouble(),
          label: '${_s.masteryHorizonDays}',
          onChanged: (v) =>
              setState(() => _s = _s.copyWith(masteryHorizonDays: v.round())),
        ),
        const Divider(),
        ListTile(
          title: const Text('وضع التسميع الافتراضي'),
          trailing: DropdownButton<RecitationMode>(
            value: _s.defaultMode,
            items: const [
              DropdownMenuItem(value: RecitationMode.easy, child: Text('سهل')),
              DropdownMenuItem(value: RecitationMode.normal, child: Text('عادي')),
              DropdownMenuItem(value: RecitationMode.strict, child: Text('صارم')),
            ],
            onChanged: (v) => setState(
                () => _s = _s.copyWith(defaultMode: v ?? RecitationMode.normal)),
          ),
        ),
        SwitchListTile(
          title: const Text('دمج الآيات المتتالية'),
          value: _s.mergeContiguous,
          onChanged: (v) => setState(() => _s = _s.copyWith(mergeContiguous: v)),
        ),
        const SizedBox(height: 16),
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
