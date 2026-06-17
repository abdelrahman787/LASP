import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/review/models.dart';

import '../../app/providers.dart';
import '../recitation/recitation_screen.dart';

/// Resolve a plan item's ayah range to a recitation scope and launch the
/// recitation engine in review mode (Review Plans Phase 4). On completion the
/// recitation screen feeds the result back into the plan.
Future<void> startReview(
  BuildContext context,
  WidgetRef ref, {
  required String planId,
  required PlanItem item,
}) async {
  final repo = ref.read(quranRepositoryProvider);
  final ayahEnd = item.ayahEnd ?? item.ayah;
  final scope = repo.wordsForAyahRange(item.surah, item.ayah, ayahEnd);
  final rangeLabel =
      item.isRange ? '${item.surah}:${item.ayah}-$ayahEnd' : '${item.surah}:${item.ayah}';

  if (scope.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('تعذّر تحميل آيات $rangeLabel')),
    );
    return;
  }

  await Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => RecitationScreen(
        scope: scope,
        title: 'مراجعة $rangeLabel',
        planId: planId,
        planItemId: item.id,
      ),
    ),
  );
}
