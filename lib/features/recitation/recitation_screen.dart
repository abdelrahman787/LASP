import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';
import 'package:quran_tasmee3_core/recitation/session_report.dart';

import '../../app/debug.dart';
import '../../app/providers.dart';
import '../report/report_screen.dart';

/// Drives the [RecitationController] for one page. The mic/ASR is faked: the
/// "simulate" buttons feed canned [AsrResult]s through the wired [AsrService],
/// so the full state machine (reveal, ladder, silence-forget, manual reveals)
/// runs on the emulator without a microphone.
class RecitationScreen extends ConsumerStatefulWidget {
  final int pageNumber;
  const RecitationScreen({super.key, required this.pageNumber});

  @override
  ConsumerState<RecitationScreen> createState() => _RecitationScreenState();
}

class _RecitationScreenState extends ConsumerState<RecitationScreen> {
  late final List<ExpectedWord> _scope;
  late final RecitationController _controller;
  late final AsrService _asr;
  final _logger = InMemorySessionLogger();
  Timer? _silenceTimer;
  int _seenEvents = 0;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider);
    _scope = ref.read(quranRepositoryProvider).getPageWords(widget.pageNumber);
    final mode = ref.read(settingsProvider).valueOrNull?.recitationConfig ??
        RecitationConfig.normal;

    _controller = RecitationController(
      scope: _scope,
      mode: mode,
      now: now,
      logger: _logger,
      onReveal: (_) => _refresh(),
      onEvent: (_) => _refresh(),
    );
    _asr = ref.read(asrServiceProvider);
    // Wire the ASR feed → the engine. Real impl streams mic chunks here.
    _asr.start((r) {
      final before = _controller.cursor;
      // Normalized tokens (exactly what the engine compares).
      final recog = tokenize(normalizeForMatch(r.text));
      final expWin = [
        for (var i = before; i < _scope.length && i < before + 4; i++)
          _scope[i].norm,
      ];
      final eventsBefore = _controller.events.length;
      _controller.submitAsr(r);
      dlog('submitAsr "${r.text}" conf=${r.confidence.toStringAsFixed(2)} '
          'cursor $before→${_controller.cursor} '
          'revealed=${_controller.revealedIndices.length} '
          'err=${_controller.lastError?.errorType.name ?? '-'}');
      dlog('  expected@$before=$expWin  recognized=$recog');

      // If this utterance re-anchored, print the exact skipped range + forgets.
      final reanchor = _controller.events
          .skip(eventsBefore)
          .where((e) => e.type == RecitationEventType.reanchored)
          .lastOrNull;
      if (reanchor != null) {
        final anchorStart = reanchor.index ?? before;
        final skipped = [
          for (var i = before; i < anchorStart && i < _scope.length; i++)
            if (!_controller.revealedIndices.contains(i)) _scope[i].wordId,
        ];
        dlog('  RE-ANCHOR skipped ${skipped.length} word(s) '
            '[$before..${anchorStart - 1}] → forgets logged: $skipped');
      }
      _refresh();
    });
    _controller.start();

    // Real silence behavior: poll the timers against the wall clock.
    var lastTickStatus = '';
    _silenceTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _controller.checkSilence();
      // Log only when something changed to avoid 2/sec spam.
      final snap = 'cursor=${_controller.cursor} '
          'silence=${_controller.silenceIndicatorVisible} '
          'status=${_controller.status.name}';
      if (snap != lastTickStatus) {
        dlog('checkSilence $snap');
        lastTickStatus = snap;
      }
      _refresh();
    });
  }

  @override
  void dispose() {
    _silenceTimer?.cancel();
    _asr.stop();
    super.dispose();
  }

  void _refresh() {
    if (!mounted) return;
    // Surface a one-shot "audio unclear" hint.
    if (_controller.events.length > _seenEvents) {
      final fresh = _controller.events.sublist(_seenEvents);
      _seenEvents = _controller.events.length;
      if (fresh.any((e) => e.type == RecitationEventType.asrUnclear)) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('الصوت غير واضح'), duration: Duration(seconds: 2)),
        );
      }
      final reanchor = fresh
          .where((e) => e.type == RecitationEventType.reanchored)
          .lastOrNull;
      if (reanchor != null) {
        dlog('RE-ANCHORED → cursor jumped to ${reanchor.index} '
            '(recovered from stuck state)');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('تمت إعادة المحاذاة'),
              duration: Duration(seconds: 2)),
        );
      }
    }
    setState(() {});
    if (_controller.status == RecitationStatus.completed) _finish();
  }

  Future<void> _finish() async {
    if (_finishing) return;
    _finishing = true;
    _silenceTimer?.cancel();
    await _asr.stop();

    final report = buildSessionReport(scope: _scope, errors: _logger.errors);
    _logReport(report);
    final now = ref.read(clockProvider)();
    await ref.read(reviewServiceProvider).ingestSession(
          errors: _logger.errors,
          nowMs: now,
        );
    ref.invalidate(dashboardProvider);
    ref.invalidate(plansListProvider);

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => ReportScreen(report: report)),
    );
  }

  /// Dump the full SessionReport to logcat so report correctness can be
  /// verified from `[ASR]` lines without inspecting Firestore or the UI.
  void _logReport(SessionReport r) {
    List<String> ids(List<ReportEntry> es) => es.map((e) => e.wordId).toList();
    dlog('==================== SESSION REPORT ====================');
    dlog('score=${(r.score * 100).round()}%  '
        'confirmed=${r.confirmedErrors}  soft=${r.softErrors}  '
        'totalWords=${r.totalWords}');
    dlog('نسيان/forgetSilence (${r.forgetSilence.length}): ${ids(r.forgetSilence)}');
    dlog('نسيان/forgetManual  (${r.forgetManual.length}): ${ids(r.forgetManual)}');
    dlog('استبدال/substitution (${r.substitutions.length}): ${ids(r.substitutions)}');
    dlog('زيادة/addition       (${r.additions.length}): ${ids(r.additions)}');
    dlog('ترتيب/order          (${r.orderErrors.length}): ${ids(r.orderErrors)}');
    dlog('نطق/pronunciation    (${r.pronunciations.length}): ${ids(r.pronunciations)}');
    dlog('perAyah: ${r.perAyah.map((a) => '${a.surah}:${a.ayah}='
        '${(a.accuracy * 100).round()}%(${a.errorWords}/${a.totalWords})').toList()}');
    dlog('========================================================');
  }

  /// The simulate buttons only apply to the fake ASR feed; with the real
  /// [GroqAsrService] the mic drives the engine instead.
  bool get _isFake => _asr is FakeAsrService;

  void _feedCorrect() {
    final asr = _asr;
    final c = _controller.cursor;
    if (asr is FakeAsrService && c < _scope.length) {
      asr.emit(AsrResult(_scope[c].display, 0.95));
    }
  }

  void _feedWrong() {
    final asr = _asr;
    if (asr is FakeAsrService) asr.emit(const AsrResult('زقمون', 0.9));
  }

  void _feedUnclear() {
    final asr = _asr;
    if (asr is FakeAsrService) asr.emit(const AsrResult('', 0.0));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('تسميع — صفحة ${widget.pageNumber}'),
        actions: [
          TextButton(
            onPressed: _finishing ? null : _finish,
            child: const Text('إنهاء'),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_controller.silenceIndicatorVisible)
            Container(
              width: double.infinity,
              color: theme.colorScheme.secondaryContainer,
              padding: const EdgeInsets.all(8),
              child: const Text('… نستمع', textAlign: TextAlign.center),
            ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 10,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                textDirection: TextDirection.rtl,
                children: [
                  for (var i = 0; i < _scope.length; i++)
                    _WordChip(
                      text: _scope[i].display,
                      revealed: _controller.revealedIndices.contains(i),
                      isCursor: i == _controller.cursor,
                    ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Text(
                  'المؤشر عند الكلمة ${_controller.cursor + 1} من ${_scope.length}',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    if (_isFake) ...[
                      FilledButton.tonal(
                        onPressed: _feedCorrect,
                        child: const Text('محاكاة: نطق صحيح'),
                      ),
                      FilledButton.tonal(
                        onPressed: _feedWrong,
                        child: const Text('محاكاة: نطق خطأ'),
                      ),
                      OutlinedButton(
                        onPressed: _feedUnclear,
                        child: const Text('محاكاة: صوت غير واضح'),
                      ),
                    ],
                    OutlinedButton(
                      onPressed: () {
                        _controller.revealNextWord();
                        dlog('revealNextWord → cursor=${_controller.cursor} '
                            '(mic streaming continues uninterrupted)');
                        _refresh();
                      },
                      child: const Text('إظهار الكلمة التالية'),
                    ),
                    OutlinedButton(
                      onPressed: () {
                        _controller.revealFullAyah();
                        dlog('revealFullAyah → cursor=${_controller.cursor} '
                            '(mic streaming continues uninterrupted)');
                        _refresh();
                      },
                      child: const Text('إظهار الآية كاملة'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WordChip extends StatelessWidget {
  final String text;
  final bool revealed;
  final bool isCursor;
  const _WordChip({
    required this.text,
    required this.revealed,
    required this.isCursor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 250),
      opacity: revealed ? 1 : 0.12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: isCursor
              ? Border.all(color: theme.colorScheme.primary, width: 2)
              : null,
          color: revealed
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
              : theme.colorScheme.surfaceContainerHighest,
        ),
        child: Text(
          revealed ? text : '•••',
          style: theme.textTheme.titleLarge,
        ),
      ),
    );
  }
}
