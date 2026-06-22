import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data/quran_repository.dart';
import '../../app/perf.dart';
import '../../app/providers.dart';
import '../recitation/recitation_screen.dart';
import 'mushaf_index_screen.dart';
import 'mushaf_page_controller.dart';
import 'mushaf_page_widget.dart';
import 'page_font_loader.dart';

/// Standalone "just read the Quran" screen (Mushaf Viewer Phase 6): full-screen
/// (no bottom nav — it's a pushed route), browse pages with all words visible.
class MushafReaderScreen extends ConsumerWidget {
  final int initialPage;
  const MushafReaderScreen({super.key, this.initialPage = 1});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dataAsync = ref.watch(quranDataProvider);
    return dataAsync.when(
      loading: () =>
          const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (_, __) => const _Pager(pages: [1], initialPage: 1),
      data: (data) {
        final pages = (data != null && data.pages.isNotEmpty)
            ? data.pages
            : ref.read(quranRepositoryProvider).pages;
        return _Pager(pages: pages, initialPage: initialPage);
      },
    );
  }
}

class _Pager extends ConsumerStatefulWidget {
  final List<int> pages;
  final int initialPage;
  const _Pager({required this.pages, required this.initialPage});

  @override
  ConsumerState<_Pager> createState() => _PagerState();
}

class _PagerState extends ConsumerState<_Pager> {
  late final PageController _controller;
  late int _current;

  // Real-device frame profiler — logs build vs raster ms for janky frames so a
  // swipe can be profiled without DevTools. See FrameTimingProbe.
  final FrameTimingProbe _probe = FrameTimingProbe('mushaf-swipe');

  int _indexOf(int page) {
    final i = widget.pages.indexOf(page);
    return i < 0 ? 0 : i;
  }

  @override
  void initState() {
    super.initState();
    final startIdx = _indexOf(widget.initialPage);
    _current = widget.pages[startIdx];
    _controller = PageController(initialPage: startIdx);
    _precacheAround(startIdx);
    _probe.start();
  }

  // Warm current ± 2 pages OFF the swipe frame: load+parse each page font and
  // pre-shape its lines. The first use of a freshly-loaded per-page QCF font is
  // the dominant page-swipe BUILD cost (font parse + cold shaping, plus the
  // global systemFonts re-layout FontLoader triggers). Doing it ahead, during
  // idle, means the on-screen build reuses an already-parsed/warm font.
  void _precacheAround(int idx) {
    final data = ref.read(quranDataProvider).valueOrNull;
    for (final j in [idx - 2, idx - 1, idx, idx + 1, idx + 2]) {
      if (j >= 0 && j < widget.pages.length) {
        _warmPage(widget.pages[j], data);
      }
    }
  }

  Future<void> _warmPage(int page, QuranData? data) async {
    final ok = await PageFontLoader.ensure(page); // font parse fires here (idle)
    if (!ok || !mounted || data == null) return;
    final glyphs = data.pageGlyphs[page];
    if (glyphs == null || glyphs.isEmpty) return;
    // Pre-shape each line once with the page font so its glyph runs are warm
    // before the page is rendered (off the critical swipe frame).
    final fam = PageFontLoader.family(page);
    final byLine = <int, StringBuffer>{};
    for (final g in glyphs) {
      (byLine[g.lineNumber] ??= StringBuffer()).write(g.text);
    }
    for (final buf in byLine.values) {
      final tp = TextPainter(
        text: TextSpan(
          text: buf.toString(),
          style: TextStyle(fontFamily: fam, fontSize: 24, height: 1.0),
        ),
        textDirection: TextDirection.rtl,
        maxLines: 1,
      )..layout();
      tp.dispose();
    }
  }

  @override
  void dispose() {
    _probe.stop();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openIndex() async {
    final page = await Navigator.of(context).push<int>(
      MaterialPageRoute(builder: (_) => const MushafIndexScreen()),
    );
    if (page == null || !mounted) return;
    final idx = _indexOf(page);
    _controller.jumpToPage(idx);
    setState(() => _current = widget.pages[idx]);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.pages.isEmpty) {
      return const Scaffold(body: Center(child: Text('لا توجد بيانات مصحف.')));
    }
    return Scaffold(
      appBar: AppBar(
        title: Text('المصحف · صفحة $_current'),
        actions: [
          IconButton(
            tooltip: 'الفهرس',
            icon: const Icon(Icons.format_list_bulleted),
            onPressed: _openIndex,
          ),
        ],
      ),
      body: PageView.builder(
        controller: _controller,
        itemCount: widget.pages.length,
        onPageChanged: (i) {
          _precacheAround(i);
          setState(() => _current = widget.pages[i]);
        },
        itemBuilder: (context, i) =>
            RepaintBoundary(child: _ReaderPage(pageNumber: widget.pages[i])),
      ),
    );
  }
}

/// One read-only page (all words visible). Kept alive so revisited pages don't
/// rebuild/reload on every swipe.
class _ReaderPage extends ConsumerStatefulWidget {
  final int pageNumber;
  const _ReaderPage({required this.pageNumber});

  @override
  ConsumerState<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<_ReaderPage>
    with AutomaticKeepAliveClientMixin {
  late final List<PageGlyph> _glyphs;
  late final MushafPageController _controller;
  Map<int, String> _surahNames = const {};
  String _surahLabel = '';
  int? _juz;

  // Do NOT keep every visited page alive. Each new page's font registration
  // fires a global systemFonts re-layout; keeping all pages alive made that
  // re-shape EVERY visited page (cost grew as you read — the escalating swipe
  // jank). Off-screen pages are now disposed, bounding the re-shape to the live
  // window. Rebuild-on-return is cheap (font already warm, one Text per line).
  @override
  bool get wantKeepAlive => false;

  @override
  void initState() {
    super.initState();
    final data = ref.read(quranDataProvider).valueOrNull;
    final real = data?.pageGlyphs[widget.pageNumber];
    if (real != null && real.isNotEmpty) {
      _glyphs = real;
    } else {
      final scope =
          ref.read(quranRepositoryProvider).getPageWords(widget.pageNumber);
      _glyphs = [
        for (var i = 0; i < scope.length; i++)
          PageGlyph(
            positionInPage: i,
            lineNumber: (i ~/ 5) + 1,
            type: 'word',
            text: scope[i].display,
            isCodeV2: false,
            wordId: scope[i].wordId,
            surah: scope[i].surah,
            ayah: scope[i].ayah,
          ),
      ];
    }
    if (data != null) {
      _surahNames = {for (final s in data.surahs) s.id: s.nameAr};
    }
    _controller = MushafPageController()
      ..showAllWords(_glyphs.map((g) => g.positionInPage));
    if (_glyphs.isNotEmpty) {
      final g = _glyphs.first;
      _surahLabel = _surahNames[g.surah] ?? 'سورة ${g.surah}';
      final meta =
          data?.ayahMeta.where((a) => a.surah == g.surah && a.ayah == g.ayah);
      if (meta != null && meta.isNotEmpty) _juz = meta.first.juz;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // for keep-alive
    return MushafPageWidget(
      pageNumber: widget.pageNumber,
      glyphs: _glyphs,
      controller: _controller,
      surahName: _surahLabel,
      juz: _juz,
      surahNames: _surahNames,
      showTopBar: false, // the reader Scaffold provides the single top bar
      interactive: false, // read-only: use the lightweight static glyph path
      onTasmee: () => Navigator.of(context).push(
        MaterialPageRoute(
            builder: (_) => RecitationScreen(pageNumber: widget.pageNumber)),
      ),
    );
  }
}
