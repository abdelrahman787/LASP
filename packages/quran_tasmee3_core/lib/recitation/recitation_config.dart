/// Runtime-configurable recitation mode thresholds (spec Phase 1c).
///
/// Two knobs drive the matching engine:
///  - [levThreshold]  : a recited token is the "same word within tolerance"
///                      as the expected word when `levRatio <= levThreshold`
///                      (after normalization). Larger = more lenient.
///  - [confFloor]     : the ASR utterance confidence below which an accepted
///                      word is *flagged* as a pronunciation issue (it still
///                      reveals — low confidence only lowers the score, it
///                      never rejects a word whose root matched).
library;

/// Identifies the recitation difficulty mode.
enum RecitationMode { easy, normal, strict }

/// Immutable bag of thresholds for a recitation mode. Construct your own for
/// custom tuning, or use the [easy]/[normal]/[strict] presets which match the
/// spec exactly.
class RecitationConfig {
  final RecitationMode mode;

  /// Max normalized Levenshtein ratio for "same word within tolerance".
  final double levThreshold;

  /// ASR confidence floor; accepted words below this are flagged
  /// `pronunciation` (never rejected on confidence alone).
  final double confFloor;

  const RecitationConfig({
    required this.mode,
    required this.levThreshold,
    required this.confFloor,
  });

  /// easy   : levThreshold = 0.30, confFloor = 0.60
  static const RecitationConfig easy = RecitationConfig(
    mode: RecitationMode.easy,
    levThreshold: 0.30,
    confFloor: 0.60,
  );

  /// normal : levThreshold = 0.20, confFloor = 0.75
  static const RecitationConfig normal = RecitationConfig(
    mode: RecitationMode.normal,
    levThreshold: 0.20,
    confFloor: 0.75,
  );

  /// strict : levThreshold = 0.10, confFloor = 0.85
  static const RecitationConfig strict = RecitationConfig(
    mode: RecitationMode.strict,
    levThreshold: 0.10,
    confFloor: 0.85,
  );

  /// Convenience lookup from the enum to the matching preset.
  static const Map<RecitationMode, RecitationConfig> presets = {
    RecitationMode.easy: easy,
    RecitationMode.normal: normal,
    RecitationMode.strict: strict,
  };

  RecitationConfig copyWith({double? levThreshold, double? confFloor}) {
    return RecitationConfig(
      mode: mode,
      levThreshold: levThreshold ?? this.levThreshold,
      confFloor: confFloor ?? this.confFloor,
    );
  }

  @override
  String toString() =>
      'RecitationConfig($mode, lev=$levThreshold, conf=$confFloor)';
}
