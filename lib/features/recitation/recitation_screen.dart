import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:quran_tasmee3_core/recitation/asr_service.dart';
import 'package:quran_tasmee3_core/recitation/matching_engine.dart';
import 'package:quran_tasmee3_core/recitation/normalizer.dart';
import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/recitation/recitation_controller.dart';
import 'package:quran_tasmee3_core/recitation/session_report.dart';
import 'package:quran_tasmee3_core/review/models.dart' show ReviewResult;

import '../../app/data/quran_repository.dart';
import '../../app/debug.dart';
import '../../app/providers.dart';
import '../mushaf/mushaf_page_controller.dart';
import '../mushaf/mushaf_page_widget.dart';
import '../report/report_screen.dart';

/// Drives the [RecitationController] for one page. The mic/ASR is faked: the
/// "simulate" buttons feed canned [AsrResult]s through the wired [AsrService],
/// so the full state machine (reveal, ladder, silence-forget, manual reveals)
/// runs on the emulator without a microphone.
class RecitationScreen extends ConsumerStatefulWidget {
  final int pageNumber;

  /// Review mode (Phase 4): when [scope] is provided, recite exactly these
  /// words (a plan item's ayah range) instead of a full page, and on completion
  /// feed the result back into the plan via [planId]/[planItemId].
  final List<ExpectedWord>? scope;
  final String? title;
  final String? planId;
  final String? planItemId;

  const RecitationScreen({
    super.key,
    this.pageNumber = 0,
    this.scope,
    this.title,
    this.planId,
    this.planItemId,
  });

  bool get isReview => scope != null;

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

  // Page renderer (Mushaf Phase 2).
  late final List<PageGlyph> _glyphs;
  late final MushafPageController _pageCtrl;
  late final Map<String, int> _wordPos; // wordId → positionInPage
  String _surahLabel = '';
  int? _juz;

  @override
  void initState() {
    super.initState();
    final now = ref.read(clockProvider);
    _scope = widget.scope ??
        ref.read(quranRepositoryProvider).getPageWords(widget.pageNumber);
    final mode = ref.read(settingsProvider).valueOrNull?.recitationConfig ??
        RecitationConfig.normal;

    // Page render data: real glyphs when reciting a whole page with the bundled
    // DB loaded; otherwise (review mode / fake / tests) a synthesized layout.
    final data = ref.read(quranDataProvider).valueOrNull;
    final real = widget.isReview ? null : data?.pageGlyphs[widget.pageNumber];
    if (real != null && real.isNotEmpty) {
      _glyphs = real;
    } else {
      _glyphs = [
        for (var i = 0; i < _scope.length; i++)
          PageGlyph(
            positionInPage: i,
            lineNumber: (i ~/ 5) + 1,
            type: 'word',
            text: _scope[i].display,
            isCodeV2: false,
            wordId: _scope[i].wordId,
            surah: _scope[i].surah,
            ayah: _scope[i].ayah,
          ),
      ];
    }
    _wordPos = {
      for (final g in _glyphs)
        if (g.wordId != null) g.wordId!: g.positionInPage,
    };
    _pageCtrl = MushafPageController();
    _pageCtrl.hideAllWords(); // engine hides the page on session start

    if (_scope.isNotEmpty) {
      final fw = _scope.first;
      _surahLabel = 'سورة ${fw.surah}';
      final meta =
          data?.ayahMeta.where((a) => a.surah == fw.surah && a.ayah == fw.ayah);
      if (meta != null && meta.isNotEmpty) _juz = meta.first.juz;
    }

    _controller = RecitationController(
      scope: _scope,
      mode: mode,
      now: now,
      logger: _logger,
      onReveal: _onReveal,
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
    _pageCtrl.dispose();
    super.dispose();
  }

  /// Every reveal (correct match, manual reveal, or re-anchor) flows through the
  /// controller's onReveal as a SCOPE index; map it to the page glyph position
  /// and reveal it on the real page, plus any trailing medallion/pause glyphs.
  void _onReveal(int scopeIndex) {
    if (scopeIndex < 0 || scopeIndex >= _scope.length) return;
    final pos = _wordPos[_scope[scopeIndex].wordId];
    if (pos != null) {
      _pageCtrl.revealWord(pos);
      _revealTrailingMarks(pos);
    }
    _refresh();
  }

  /// Reveal ayah-end medallions / pause marks that immediately follow a just-
  /// revealed word (glyph list is in positionInPage order, so index == pos).
  void _revealTrailingMarks(int pos) {
    for (var j = pos + 1; j < _glyphs.length && !_glyphs[j].isWord; j++) {
      _pageCtrl.revealWord(_glyphs[j].positionInPage);
    }
  }

  int? get _cursorPosition => _controller.cursor < _scope.length
      ? _wordPos[_scope[_controller.cursor].wordId]
      : null;

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
    final reviewService = ref.read(reviewServiceProvider);
    await reviewService.ingestSession(errors: _logger.errors, nowMs: now);

    // Loop closure (Phase 4): feed the result back into the plan item.
    String? summary;
    if (widget.planId != null && widget.planItemId != null) {
      final result = ReviewResult.fromCounts(
        planItemId: widget.planItemId!,
        confirmedErrors: report.confirmedErrors,
        totalWords: report.totalWords,
        reviewedAt: now,
      );
      try {
        final plan = await reviewService.applyReview(
          planId: widget.planId!,
          result: result,
          nowMs: now,
        );
        final item = plan.items.where((i) => i.id == widget.planItemId).toList();
        final days = item.isNotEmpty
            ? ((item.first.dueAt - now) / 86400000).round()
            : null;
        summary = 'تمت المراجعة • النتيجة ${(report.score * 100).round()}%'
            '${days != null ? ' • الاستحقاق القادم بعد $days يوم' : ''}';
        dlog('review applied: item=${widget.planItemId} '
            'score=${result.score.toStringAsFixed(2)} nextDueDays=$days');
      } catch (e) {
        dlog('applyReview failed: $e');
      }
    }

    ref.invalidate(dashboardProvider);
    ref.invalidate(plansListProvider);

    // Page-chaining: after a page recitation (not a review), offer to continue
    // onto the next page.
    final continuePage = (!widget.isReview &&
            widget.pageNumber >= 1 &&
            widget.pageNumber < 604)
        ? widget.pageNumber + 1
        : null;

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => ReportScreen(
              report: report, summary: summary, continuePage: continuePage)),
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
        title: Text(widget.title ??
            'تسميع · ${_surahLabel.isNotEmpty ? _surahLabel : 'صفحة ${widget.pageNumber}'}'),
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
            child: MushafPageWidget(
              pageNumber: widget.pageNumber,
              glyphs: _glyphs,
              controller: _pageCtrl,
              currentPosition: _cursorPosition,
              surahName: _surahLabel,
              juz: _juz,
              // The Scaffold AppBar is the single top bar — avoid a duplicate.
              showTopBar: false,
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
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
