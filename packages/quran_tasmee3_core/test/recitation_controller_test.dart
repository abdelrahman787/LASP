import 'package:test/test.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';

/// Al-Fatiha ayah 1 (4 words) + ayah 2 (4 words) as a scope.
List<ExpectedWord> fatihaScope() {
  const ayah1 = ['بسم', 'الله', 'الرحمن', 'الرحيم'];
  const ayah2 = ['الحمد', 'لله', 'رب', 'العالمين'];
  final scope = <ExpectedWord>[];
  for (var w = 0; w < ayah1.length; w++) {
    scope.add(ExpectedWord(
      wordId: '1:1:${w + 1}',
      surah: 1,
      ayah: 1,
      wordIndex: w + 1,
      norm: normalizeForMatch(ayah1[w]),
      display: ayah1[w],
    ));
  }
  for (var w = 0; w < ayah2.length; w++) {
    scope.add(ExpectedWord(
      wordId: '1:2:${w + 1}',
      surah: 1,
      ayah: 2,
      wordIndex: w + 1,
      norm: normalizeForMatch(ayah2[w]),
      display: ayah2[w],
    ));
  }
  return scope;
}

/// Controllable fake clock.
class FakeClock {
  int ms;
  FakeClock(this.ms);
  int call() => ms;
  void advance(int delta) => ms += delta;
}

void main() {
  late FakeClock clock;
  late InMemorySessionLogger logger;
  late List<int> revealed;
  late RecitationController c;

  RecitationController build({int startCursor = 0, RecitationConfig? mode}) {
    clock = FakeClock(1000);
    logger = InMemorySessionLogger();
    revealed = [];
    return RecitationController(
      scope: fatihaScope(),
      mode: mode ?? RecitationConfig.normal,
      now: clock.call,
      logger: logger,
      onReveal: revealed.add,
      startCursor: startCursor,
    );
  }

  group('multi-word acceptance', () {
    test('one breath reveals the whole ayah in sequence, advances cursor', () {
      c = build();
      c.start();
      c.submitAsr(const AsrResult('بسم الله الرحمن الرحيم', 0.95));

      expect(revealed, equals([0, 1, 2, 3]), reason: 'sequential reveal');
      expect(c.cursor, 4);
      expect(c.status, RecitationStatus.listening);
      expect(logger.errors, isEmpty);
    });

    test('completion when the final word is revealed', () {
      c = build();
      c.start();
      c.submitAsr(const AsrResult('بسم الله الرحمن الرحيم', 0.95));
      c.submitAsr(const AsrResult('الحمد لله رب العالمين', 0.95));
      expect(c.cursor, 8);
      expect(c.status, RecitationStatus.completed);
      expect(c.events.last.type, RecitationEventType.completed);
    });
  });

  group('silence timers', () {
    test('5s shows indicator, 10s logs a forget WITHOUT advancing cursor', () {
      c = build();
      c.start(); // lastProgress at t=1000

      clock.advance(5000); // t=6000, elapsed 5s
      c.checkSilence();
      expect(c.silenceIndicatorVisible, isTrue);
      expect(c.events.any((e) => e.type == RecitationEventType.silenceIndicatorShown),
          isTrue);
      expect(logger.errors, isEmpty);
      expect(c.cursor, 0);

      clock.advance(5000); // t=11000, elapsed 10s from start
      c.checkSilence();
      expect(logger.errors.length, 1);
      final f = logger.errors.single;
      expect(f.errorType, ErrorType.forget);
      expect(f.manualReveal, isFalse);
      expect(f.wordId, '1:1:1');
      expect(c.cursor, 0, reason: 'silence-forget does NOT advance');
      expect(c.silenceIndicatorVisible, isFalse, reason: 'indicator reset');
    });

    test('silence re-arms: another full window needed for the next forget', () {
      c = build();
      c.start();
      clock.advance(10000);
      c.checkSilence(); // forget #1
      expect(logger.errors.length, 1);

      clock.advance(5000); // only 5s since re-arm
      c.checkSilence();
      expect(logger.errors.length, 1, reason: 'not yet another 10s');

      clock.advance(5000); // now 10s since re-arm
      c.checkSilence();
      expect(logger.errors.length, 2);
    });

    test('accepted progress resets the silence clock', () {
      c = build();
      c.start();
      clock.advance(6000);
      c.checkSilence();
      expect(c.silenceIndicatorVisible, isTrue);

      c.submitAsr(const AsrResult('بسم', 0.95)); // progress at t=7000
      expect(c.silenceIndicatorVisible, isFalse);

      clock.advance(6000); // 6s since the accept
      c.checkSilence();
      expect(c.silenceIndicatorVisible, isTrue);
      expect(logger.errors, isEmpty);
    });
  });

  group('attempt ladder (substitution)', () {
    test('attempt 1 transient (no log), 2 soft, 3+ confirmed', () {
      c = build(mode: RecitationConfig.strict);
      c.start();
      // Wrong word at cursor 0 that matches nothing ahead → substitution.
      const wrong = AsrResult('زقمون', 0.9);

      c.submitAsr(wrong); // attempt 1
      expect(logger.errors, isEmpty, reason: 'attempt 1 is transient');
      expect(c.lastError!.severity, ErrorSeverity.transient);
      expect(c.attemptCounts['1:1:1'], 1);

      c.submitAsr(wrong); // attempt 2 → soft
      expect(logger.errors.length, 1);
      expect(logger.errors.last.severity, ErrorSeverity.soft);
      expect(logger.errors.last.errorType, ErrorType.substitution);
      expect(logger.errors.last.attempts, 2);

      c.submitAsr(wrong); // attempt 3 → confirmed
      expect(logger.errors.length, 2);
      expect(logger.errors.last.severity, ErrorSeverity.confirmed);
      expect(logger.errors.last.attempts, 3);

      expect(c.cursor, 0, reason: 'errors never advance the cursor');
    });

    test('order error is classified and laddered', () {
      c = build();
      c.start();
      // At cursor 0 (بسم) recite الله which is scope[1] → order error.
      c.submitAsr(const AsrResult('الله', 0.9));
      expect(c.lastError!.errorType, ErrorType.order);
      c.submitAsr(const AsrResult('الله', 0.9)); // soft
      expect(logger.errors.last.errorType, ErrorType.order);
      expect(logger.errors.last.severity, ErrorSeverity.soft);
    });
  });

  group('manual reveal buttons (direct forget, bypass ladder)', () {
    test('Reveal Next Word logs one manual forget and advances by one', () {
      c = build();
      c.start();
      c.revealNextWord();
      expect(revealed, equals([0]));
      expect(c.cursor, 1);
      expect(logger.errors.length, 1);
      final e = logger.errors.single;
      expect(e.errorType, ErrorType.forget);
      expect(e.manualReveal, isTrue);
      expect(e.wordId, '1:1:1');
      expect(c.attemptCounts, isEmpty, reason: 'bypasses the ladder');
    });

    test('Reveal Full Ayah logs each unrevealed word and jumps to next ayah',
        () {
      c = build();
      c.start();
      // Reveal first word by recitation, then full-ayah the rest.
      c.submitAsr(const AsrResult('بسم', 0.95)); // reveals index 0
      c.revealFullAyah();
      // indices 1,2,3 were unrevealed → 3 manual forgets, word 0 not re-logged.
      final manual = logger.errors.where((e) => e.manualReveal).toList();
      expect(manual.length, 3);
      expect(manual.map((e) => e.wordId),
          equals(['1:1:2', '1:1:3', '1:1:4']));
      expect(c.cursor, 4, reason: 'cursor at first word of ayah 2');
      expect(c.status, RecitationStatus.listening);
    });

    test('Reveal Full Ayah on the last ayah completes the session', () {
      c = build(startCursor: 4); // start of ayah 2
      c.start();
      c.revealFullAyah();
      expect(c.cursor, 8);
      expect(c.status, RecitationStatus.completed);
    });
  });

  group('context replay through the controller', () {
    test('re-reciting accepted trailing words then continuing is not an error',
        () {
      c = build();
      c.start();
      c.submitAsr(const AsrResult('بسم الله', 0.95)); // accept 0,1
      expect(c.cursor, 2);

      // Replay الله then continue الرحمن الرحيم.
      c.submitAsr(const AsrResult('الله الرحمن الرحيم', 0.95));
      expect(c.cursor, 4);
      expect(logger.errors, isEmpty);
      expect(revealed, equals([0, 1, 2, 3]));
    });
  });

  group('ASR failure handling', () {
    test('empty/zero-confidence results are silent; 3 in a row → unclear', () {
      c = build();
      c.start();
      c.submitAsr(const AsrResult('', 0.0));
      c.submitAsr(const AsrResult('   ', 0.9)); // whitespace only
      expect(c.consecutiveAsrFailures, 2);
      expect(c.events.any((e) => e.type == RecitationEventType.asrUnclear),
          isFalse);

      c.submitAsr(const AsrResult('', 0.0)); // third failure
      expect(c.consecutiveAsrFailures, 3);
      expect(c.events.any((e) => e.type == RecitationEventType.asrUnclear),
          isTrue);
      expect(logger.errors, isEmpty, reason: 'ASR failure is not a mistake');

      // A success resets the counter.
      c.submitAsr(const AsrResult('بسم', 0.95));
      expect(c.consecutiveAsrFailures, 0);
    });
  });

  group('pronunciation flag', () {
    test('low-confidence accept in strict is revealed and logged as a flag', () {
      c = build(mode: RecitationConfig.strict);
      c.start();
      c.submitAsr(const AsrResult('بسم', 0.50)); // below strict confFloor 0.85
      expect(revealed, equals([0]), reason: 'still revealed');
      expect(c.cursor, 1);
      final pron = logger.errors
          .where((e) => e.errorType == ErrorType.pronunciation)
          .toList();
      expect(pron.length, 1);
      expect(pron.single.severity, ErrorSeverity.flag);
    });
  });

  group('FakeAsrService wiring', () {
    test('drives the controller via the AsrService contract', () {
      c = build();
      final asr = FakeAsrService(const [
        AsrResult('بسم الله الرحمن الرحيم', 0.95),
        AsrResult('الحمد لله رب العالمين', 0.95),
      ]);
      c.start();
      asr.start(c.submitAsr);
      asr.drainScript();
      expect(c.status, RecitationStatus.completed);
      expect(c.revealedIndices.length, 8);
    });
  });
}
