import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data/quran_repository.dart';
import '../../app/providers.dart';
import '../recitation/recitation_screen.dart';
import 'mushaf_page_controller.dart';
import 'mushaf_page_widget.dart';

/// Standalone "just read the Quran" screen (Mushaf Viewer Phase 6): browse and
/// read pages with ALL words visible, fully outside any recitation session.
/// The تسميع button launches a recitation session for the current page.
class MushafReaderScreen extends ConsumerStatefulWidget {
  final int initialPage;
  const MushafReaderScreen({super.key, this.initialPage = 1});

  @override
  ConsumerState<MushafReaderScreen> createState() => _MushafReaderScreenState();
}

class _MushafReaderScreenState extends ConsumerState<MushafReaderScreen> {
  late final PageController _pageController;
  late final List<int> _pages;
  late int _current;

  @override
  void initState() {
    super.initState();
    _pages = ref.read(quranRepositoryProvider).pages;
    final startIdx = _pages.indexOf(widget.initialPage);
    _current = widget.initialPage;
    _pageController = PageController(initialPage: startIdx < 0 ? 0 : startIdx);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pages.isEmpty) {
      return const Scaffold(
        body: Center(child: Text('لا توجد بيانات مصحف.')),
      );
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.mic),
        label: const Text('تسميع'),
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(
              builder: (_) => RecitationScreen(pageNumber: _current)),
        ),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: _pages.length,
        onPageChanged: (i) => setState(() => _current = _pages[i]),
        itemBuilder: (context, i) => _ReaderPage(pageNumber: _pages[i]),
      ),
    );
  }
}

/// One read-only page (all words visible).
class _ReaderPage extends ConsumerStatefulWidget {
  final int pageNumber;
  const _ReaderPage({required this.pageNumber});

  @override
  ConsumerState<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends ConsumerState<_ReaderPage> {
  late final List<PageGlyph> _glyphs;
  late final MushafPageController _controller;
  String _surahLabel = '';
  int? _juz;

  @override
  void initState() {
    super.initState();
    final data = ref.read(quranDataProvider).valueOrNull;
    final real = data?.pageGlyphs[widget.pageNumber];
    if (real != null && real.isNotEmpty) {
      _glyphs = real;
    } else {
      final scope = ref.read(quranRepositoryProvider).getPageWords(widget.pageNumber);
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
    _controller = MushafPageController()
      ..showAllWords(_glyphs.map((g) => g.positionInPage));
    if (_glyphs.isNotEmpty) {
      final g = _glyphs.first;
      _surahLabel = 'سورة ${g.surah}';
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
    return MushafPageWidget(
      pageNumber: widget.pageNumber,
      glyphs: _glyphs,
      controller: _controller,
      surahName: _surahLabel,
      juz: _juz,
    );
  }
}
