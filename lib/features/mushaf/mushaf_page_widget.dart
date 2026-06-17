import 'package:flutter/material.dart';

import '../../app/data/quran_repository.dart';
import 'mushaf_page_controller.dart';
import 'page_font_loader.dart';

// Locked visual palette.
const Color _kCream = Color(0xFFFBF3E0);
const Color _kInk = Color(0xFF1A1A17);
const Color _kBar = Color(0xFFEFE3C8);
const Color _kAccent = Color(0xFF1B7A6B);

/// Pixel-faithful (font-based) mushaf page: 15 lines stretched edge-to-edge,
/// RTL, justified, each word a QCF V2 `code_v2` glyph in the page font. Words
/// toggle visibility via [MushafPageController] so the recitation engine can
/// hide the page and reveal words one-by-one.
///
/// NOTE: exact justification metrics / per-line font scaling are approximated
/// here and want on-device tuning; the data + reveal contract are exact.
class MushafPageWidget extends StatefulWidget {
  final int pageNumber;
  final List<PageGlyph> glyphs;
  final MushafPageController controller;

  /// Glyph position to highlight as the recitation cursor (optional).
  final int? currentPosition;

  /// Chrome.
  final String surahName;
  final int? juz;
  final int? hizb;
  final VoidCallback? onHome;
  final VoidCallback? onBookmark;

  const MushafPageWidget({
    super.key,
    required this.pageNumber,
    required this.glyphs,
    required this.controller,
    this.currentPosition,
    this.surahName = '',
    this.juz,
    this.hizb,
    this.onHome,
    this.onBookmark,
  });

  @override
  State<MushafPageWidget> createState() => _MushafPageWidgetState();
}

class _MushafPageWidgetState extends State<MushafPageWidget> {
  late Future<bool> _fontReady;

  @override
  void initState() {
    super.initState();
    _fontReady = PageFontLoader.ensure(widget.pageNumber);
  }

  @override
  Widget build(BuildContext context) {
    final lineCount = _maxLine();
    return Column(
      children: [
        _topBar(context),
        Expanded(
          child: Container(
            color: _kCream,
            child: FutureBuilder<bool>(
              future: _fontReady,
              builder: (context, snap) {
                final fontReady = snap.data ?? false;
                // 15 lines (or the page's actual max) stretched to fill height
                // with NO top/bottom margin — each line gets equal vertical space.
                return Column(
                  children: [
                    for (var line = 1; line <= lineCount; line++)
                      Expanded(child: _line(line, fontReady)),
                  ],
                );
              },
            ),
          ),
        ),
        _bottomBar(context),
      ],
    );
  }

  int _maxLine() {
    var m = 15;
    for (final g in widget.glyphs) {
      if (g.lineNumber > m) m = g.lineNumber;
    }
    return m;
  }

  Widget _line(int line, bool fontReady) {
    final glyphs = widget.glyphs.where((g) => g.lineNumber == line).toList()
      ..sort((a, b) => a.positionInPage.compareTo(b.positionInPage));
    if (glyphs.isEmpty) return const SizedBox.shrink();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: LayoutBuilder(
        builder: (context, c) {
          // Approximate per-line font size from the line's height.
          final fs = (c.maxHeight * 0.62).clamp(14.0, 44.0);
          return Row(
            // Justify edge-to-edge: distribute free space between words.
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [for (final g in glyphs) _glyph(g, fs, fontReady)],
          );
        },
      ),
    );
  }

  Widget _glyph(PageGlyph g, double fontSize, bool fontReady) {
    final usePageFont = g.isCodeV2 && fontReady;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final visible = widget.controller.isVisible(g.positionInPage);
        final isCursor = g.positionInPage == widget.currentPosition;
        return AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: visible ? 1 : 0,
          child: Container(
            key: widget.controller.keyFor(g.positionInPage),
            padding: const EdgeInsets.symmetric(horizontal: 1),
            decoration: isCursor
                ? BoxDecoration(
                    border: Border.all(color: _kAccent, width: 1.5),
                    borderRadius: BorderRadius.circular(4),
                  )
                : null,
            child: Text(
              g.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontFamily: usePageFont ? PageFontLoader.family(widget.pageNumber) : null,
                fontSize: fontSize,
                color: _kInk,
                height: 1.0,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      color: _kBar,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.home, color: _kInk),
            tooltip: 'الرئيسية',
            onPressed: widget.onHome,
          ),
          Expanded(
            child: Text(
              widget.surahName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: _kInk, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_border, color: _kInk),
            tooltip: 'إشارة مرجعية',
            onPressed: widget.onBookmark,
          ),
        ],
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    Widget pill(String label) => Text(label,
        style: const TextStyle(color: _kInk, fontSize: 13));
    return Container(
      color: _kBar,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          pill(widget.juz != null ? 'الجزء ${widget.juz}' : ''),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: _kAccent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('${widget.pageNumber}',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          pill(widget.hizb != null ? 'الحزب ${widget.hizb}' : ''),
        ],
      ),
    );
  }
}
