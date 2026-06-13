/// Review-plan domain model (spec Phase 0). Pure Dart — no Flutter, no DB.
/// All timestamps are epoch milliseconds (int), matching the Firestore schema.
library;

/// A word-level weak item as stored at `users/<uid>/weakItems/<wordId>`.
/// Input to aggregation. `forgetCount` is an optional extension used by the
/// "contains a confirmed forget" qualification rule; it defaults to 0 when the
/// stored document predates that field.
class WeakItem {
  /// "<surah>:<ayah>:<wordIndex>"
  final String wordId;
  final int surah;
  final int ayah;
  final int wordIndex;
  final int errorCount;
  final int lastErrorAt; // epoch ms
  final double masteryScore; // 0..1
  final int forgetCount;

  const WeakItem({
    required this.wordId,
    required this.surah,
    required this.ayah,
    required this.wordIndex,
    required this.errorCount,
    required this.lastErrorAt,
    required this.masteryScore,
    this.forgetCount = 0,
  });
}

/// Word-level weakness rolled up to a reviewable ayah (spec Phase 0).
class WeakAyah {
  final int surah;
  final int ayah;
  final int page;
  final double weaknessScore;
  final int totalErrors;
  final int lastErrorAt; // epoch ms, max across words
  final double masteryScore; // min across words
  final bool hasForget;

  const WeakAyah({
    required this.surah,
    required this.ayah,
    required this.page,
    required this.weaknessScore,
    required this.totalErrors,
    required this.lastErrorAt,
    required this.masteryScore,
    this.hasForget = false,
  });

  @override
  String toString() =>
      'WeakAyah($surah:$ayah, w=${weaknessScore.toStringAsFixed(2)}, '
      'errs=$totalErrors)';
}

/// Lifecycle of a plan item.
enum PlanItemStatus { newItem, due, scheduled, mastered }

extension PlanItemStatusWire on PlanItemStatus {
  /// Stored as new|due|scheduled|mastered.
  String get wire {
    switch (this) {
      case PlanItemStatus.newItem:
        return 'new';
      case PlanItemStatus.due:
        return 'due';
      case PlanItemStatus.scheduled:
        return 'scheduled';
      case PlanItemStatus.mastered:
        return 'mastered';
    }
  }

  static PlanItemStatus fromWire(String s) {
    switch (s) {
      case 'new':
        return PlanItemStatus.newItem;
      case 'due':
        return PlanItemStatus.due;
      case 'scheduled':
        return PlanItemStatus.scheduled;
      case 'mastered':
        return PlanItemStatus.mastered;
      default:
        throw ArgumentError('unknown PlanItemStatus "$s"');
    }
  }
}

/// One schedulable unit in a review plan — a single ayah or a contiguous range
/// (`ayah..ayahEnd`) in the same surah. Carries SM-2-lite scheduling state.
class PlanItem {
  final String id;
  final int surah;
  final int ayah;

  /// Inclusive end of a merged contiguous range; null for a single ayah.
  final int? ayahEnd;

  final double ease; // SM-2 ease factor, >= 1.3
  final int intervalDays;
  final int repetitions;
  final int dueAt; // epoch ms
  final double? lastScore; // 0..1, last review score
  final PlanItemStatus status;

  const PlanItem({
    required this.id,
    required this.surah,
    required this.ayah,
    this.ayahEnd,
    this.ease = 2.5,
    this.intervalDays = 0,
    this.repetitions = 0,
    required this.dueAt,
    this.lastScore,
    this.status = PlanItemStatus.newItem,
  });

  bool get isRange => ayahEnd != null && ayahEnd! > ayah;

  PlanItem copyWith({
    double? ease,
    int? intervalDays,
    int? repetitions,
    int? dueAt,
    double? lastScore,
    PlanItemStatus? status,
  }) {
    return PlanItem(
      id: id,
      surah: surah,
      ayah: ayah,
      ayahEnd: ayahEnd,
      ease: ease ?? this.ease,
      intervalDays: intervalDays ?? this.intervalDays,
      repetitions: repetitions ?? this.repetitions,
      dueAt: dueAt ?? this.dueAt,
      lastScore: lastScore ?? this.lastScore,
      status: status ?? this.status,
    );
  }

  @override
  String toString() =>
      'PlanItem($id $surah:$ayah${isRange ? '-$ayahEnd' : ''}, '
      'int=$intervalDays, ease=${ease.toStringAsFixed(2)}, ${status.wire})';
}

/// A named review plan: an ordered list of items plus a daily target.
class ReviewPlan {
  final String id;
  final String name;
  final List<PlanItem> items;
  final int dailyTarget;
  final int createdAt; // epoch ms
  final int updatedAt; // epoch ms

  const ReviewPlan({
    required this.id,
    required this.name,
    required this.items,
    required this.dailyTarget,
    required this.createdAt,
    required this.updatedAt,
  });

  ReviewPlan copyWith({
    String? name,
    List<PlanItem>? items,
    int? dailyTarget,
    int? updatedAt,
  }) {
    return ReviewPlan(
      id: id,
      name: name ?? this.name,
      items: items ?? this.items,
      dailyTarget: dailyTarget ?? this.dailyTarget,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// The outcome of running a review on a single plan item.
class ReviewResult {
  final String planItemId;
  final double score; // 0..1
  final int confirmedErrors;
  final int totalWords;
  final int reviewedAt; // epoch ms

  const ReviewResult({
    required this.planItemId,
    required this.score,
    required this.confirmedErrors,
    required this.totalWords,
    required this.reviewedAt,
  });

  /// Convenience: build a result computing score = 1 - confirmedErrors/totalWords
  /// clamped to 0..1 (spec Phase 4 loop closure).
  factory ReviewResult.fromCounts({
    required String planItemId,
    required int confirmedErrors,
    required int totalWords,
    required int reviewedAt,
  }) {
    final raw = totalWords <= 0 ? 1.0 : 1.0 - confirmedErrors / totalWords;
    final clamped = raw < 0.0 ? 0.0 : (raw > 1.0 ? 1.0 : raw);
    return ReviewResult(
      planItemId: planItemId,
      score: clamped,
      confirmedErrors: confirmedErrors,
      totalWords: totalWords,
      reviewedAt: reviewedAt,
    );
  }
}
