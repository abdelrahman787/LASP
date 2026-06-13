/// User-configurable settings (spec Phase 5) — the single source for the
/// scheduler/aggregation knobs that were previously hardcoded. Pure Dart;
/// persisted via an injectable [SettingsRepository] (in-memory for now,
/// Firestore/SharedPreferences later).
library;

import '../recitation/recitation_config.dart';
import 'aggregation.dart';

class UserSettings {
  /// Items reviewed per day (was the magic `10` in scheduler.dart).
  final int dailyTarget;

  /// Default recitation mode for review sessions.
  final RecitationMode defaultMode;

  /// Minimum weakness score for an ayah to qualify (was `2.0` in aggregation).
  final double weaknessThreshold;

  /// Interval (days) at/after which an item is mastered (was `30`).
  final int masteryHorizonDays;

  /// Whether contiguous qualifying ayat merge into ranged items.
  final bool mergeContiguous;

  const UserSettings({
    this.dailyTarget = 10,
    this.defaultMode = RecitationMode.normal,
    this.weaknessThreshold = 2.0,
    this.masteryHorizonDays = 30,
    this.mergeContiguous = true,
  });

  /// Defaults — identical to the constants previously buried in the pure
  /// functions, so behavior is unchanged until the user edits a setting.
  static const UserSettings defaults = UserSettings();

  /// The aggregation knobs derived from these settings.
  AggregationConfig toAggregationConfig() => AggregationConfig(
        weaknessThreshold: weaknessThreshold,
        mergeContiguous: mergeContiguous,
      );

  /// The recitation thresholds for [defaultMode].
  RecitationConfig get recitationConfig => RecitationConfig.presets[defaultMode]!;

  UserSettings copyWith({
    int? dailyTarget,
    RecitationMode? defaultMode,
    double? weaknessThreshold,
    int? masteryHorizonDays,
    bool? mergeContiguous,
  }) {
    return UserSettings(
      dailyTarget: dailyTarget ?? this.dailyTarget,
      defaultMode: defaultMode ?? this.defaultMode,
      weaknessThreshold: weaknessThreshold ?? this.weaknessThreshold,
      masteryHorizonDays: masteryHorizonDays ?? this.masteryHorizonDays,
      mergeContiguous: mergeContiguous ?? this.mergeContiguous,
    );
  }

  @override
  String toString() => 'UserSettings(daily=$dailyTarget, mode=${defaultMode.name}, '
      'weakThr=$weaknessThreshold, horizon=$masteryHorizonDays)';
}

/// Persistence for [UserSettings].
abstract class SettingsRepository {
  Future<UserSettings> get();
  Future<void> save(UserSettings settings);
}

/// In-memory settings store; returns [UserSettings.defaults] until saved.
class InMemorySettingsRepository implements SettingsRepository {
  UserSettings _settings;
  InMemorySettingsRepository([UserSettings? initial])
      : _settings = initial ?? UserSettings.defaults;

  @override
  Future<UserSettings> get() async => _settings;

  @override
  Future<void> save(UserSettings settings) async {
    _settings = settings;
  }
}
