import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../data/db.dart';
import '../data/settings.dart';
import '../reflow/book_text.dart';
import '../reflow/reflow.dart';
import 'appearance_sheet.dart';
import 'bottom_bar.dart';
import 'notes_screen.dart';
import 'original_strip.dart';
import 'page_image.dart';

enum ViewMode { large, original }

class ReaderScreen extends StatefulWidget {
  const ReaderScreen({super.key, required this.path, required this.onOpenLibrary});

  final String path;
  final VoidCallback onOpenLibrary;

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  PdfDocument? _doc;
  String? _fp;
  String? _error;
  BookText? _text;
  List<Highlight> _highlights = [];

  ViewMode _mode = ViewMode.large;
  bool _barVisible = true;

  // Current reading location (kept up to date in both modes).
  int _page = 1;
  int _char = 0;
  double _itemOffset = 0;
  double _pageY = 0;
  double? _zoom;

  // Large-text mode
  ItemScrollController _itemScroll = ItemScrollController();
  late ItemPositionsListener _itemPositions = _newPositions();
  int? _largeInitialIndex;
  double _largeInitialAlign = 0;
  int _topIndex = 0;

  // Original mode
  final _pdfController = PdfViewerController();
  bool _pdfReady = false;
  ({int page, double y, double? zoom})? _pendingOriginalTarget;
  final _origTexts = <int, PdfPageText>{};

  Timer? _saveTimer;

  Settings get _s => Settings.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _s.addListener(_onSettings);
    _open();
  }

  @override
  void dispose() {
    _saveNow();
    WidgetsBinding.instance.removeObserver(this);
    _s.removeListener(_onSettings);
    _saveTimer?.cancel();
    _text?.removeListener(_onTextProgress);
    _text?.dispose();
    _doc?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _saveNow();
  }

  void _onSettings() => setState(() {});

  // ------------------------------------------------------------------ open

  Future<void> _open() async {
    try {
      final fp = await fingerprintFile(widget.path);
      final doc = await PdfDocument.openFile(widget.path);
      await AppDb.instance.upsertBook(widget.path, fp);
      final pos = await AppDb.instance.position(fp);
      final hls = await AppDb.instance.highlights(fp);
      if (!mounted) {
        doc.dispose();
        return;
      }
      _s.lastBookPath = widget.path;
      _fp = fp;
      _doc = doc;
      _highlights = hls;
      if (pos != null) {
        _page = pos.page.clamp(1, doc.pages.length);
        _char = pos.charIndex;
        _itemOffset = pos.itemOffset;
        _pageY = pos.pageYFrac;
        _zoom = pos.zoom;
        _mode = pos.mode == 'original' ? ViewMode.original : ViewMode.large;
      }
      if (_mode == ViewMode.original) {
        _pendingOriginalTarget = (page: _page, y: _pageY, zoom: _zoom);
      }
      final text = BookText(doc, fp)..addListener(_onTextProgress);
      _text = text;
      setState(() {});
      unawaited(text.start());
      unawaited(_preloadHighlightTexts());
    } catch (e) {
      setState(() => _error = 'Could not open this PDF.\n${p.basename(widget.path)}\n\n$e');
    }
  }

  void _onTextProgress() {
    final t = _text!;
    if (_mode == ViewMode.large && _largeInitialIndex == null && t.pageStart.containsKey(_page)) {
      // Restore exactly: same paragraph, same offset inside the screen.
      _largeInitialIndex = t.indexFor(_page, _char);
      _largeInitialAlign = _itemOffset;
      _topIndex = _largeInitialIndex!;
    }
    if (_mode == ViewMode.original && t.pageStart.containsKey(_page)) {
      // Text became ready after the page was restored: sync the strip.
      _topIndex = t.indexForPageY(_page, _pageY);
      _char = t.paras[_topIndex].start;
    }
    setState(() {});
  }

  // -------------------------------------------------------------- position

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), _saveNow);
  }

  void _saveNow() {
    final fp = _fp, doc = _doc;
    if (fp == null || doc == null) return;
    AppDb.instance.savePosition(
      fp,
      ReadingPosition(
        page: _page,
        charIndex: _char,
        mode: _mode == ViewMode.original ? 'original' : 'large',
        itemOffset: _itemOffset,
        pageYFrac: _pageY,
        zoom: _zoom,
      ),
      doc.pages.length,
    );
  }

  /// Position tracking follows the list itself, so jumps (notes, go to
  /// page) update the strip and saved position exactly like scrolling.
  ItemPositionsListener _newPositions() {
    final l = ItemPositionsListener.create();
    l.itemPositions.addListener(_onLargeScroll);
    return l;
  }

  void _onLargeScroll() {
    final t = _text;
    if (t == null) return;
    final visible = _itemPositions.itemPositions.value.where((e) => e.itemTrailingEdge > 0.001);
    if (visible.isEmpty) return;
    final top = visible.reduce((a, b) => a.itemLeadingEdge < b.itemLeadingEdge ? a : b);
    if (top.index >= t.paras.length) return;
    final para = t.paras[top.index];
    final changed = top.index != _topIndex || para.page != _page;
    _topIndex = top.index;
    _page = para.page;
    _char = para.start;
    _itemOffset = top.itemLeadingEdge;
    // Approximate the place on the original page for the strip and mode switch.
    final inside = (-top.itemLeadingEdge / (top.itemTrailingEdge - top.itemLeadingEdge)).clamp(0.0, 1.0);
    _pageY = para.top + (para.bottom - para.top) * inside;
    if (changed) setState(() {});
    _scheduleSave();
  }

  void _onOriginalChanged() {
    if (!_pdfReady || !_pdfController.isReady) return;
    final layouts = _pdfController.layout.pageLayouts;
    final vis = _pdfController.visibleRect;
    final y = vis.top + 2;
    var page = 1;
    for (var i = 0; i < layouts.length; i++) {
      if (layouts[i].bottom > y) {
        page = i + 1;
        break;
      }
    }
    final r = layouts[page - 1];
    final yFrac = ((y - r.top) / r.height).clamp(0.0, 1.0);
    final changed = page != _page;
    _page = page;
    _pageY = yFrac;
    _zoom = _pdfController.value.zoom;
    final t = _text;
    if (t != null && t.pageStart.containsKey(page)) {
      final idx = t.indexForPageY(page, yFrac);
      _topIndex = idx;
      _char = t.paras[idx].start;
      _itemOffset = 0;
    } else {
      _char = 0;
    }
    if (changed) setState(() {});
    _scheduleSave();
  }

  // ------------------------------------------------------------ navigation

  void _switchMode() {
    if (_mode == ViewMode.large) {
      final t = _text;
      double y = _pageY;
      if (t != null && _topIndex < t.paras.length && !t.paras[_topIndex].image) {
        y = math.max(0, t.paras[_topIndex].top - 0.01);
      }
      setState(() {
        _pendingOriginalTarget = (page: _page, y: y, zoom: null);
        _pdfReady = false;
        _mode = ViewMode.original;
      });
    } else {
      final t = _text;
      setState(() {
        _mode = ViewMode.large;
        _itemScroll = ItemScrollController();
        _itemPositions = _newPositions();
        if (t != null && t.pageStart.containsKey(_page)) {
          _largeInitialIndex = t.indexForPageY(_page, _pageY);
          _largeInitialAlign = 0;
          _topIndex = _largeInitialIndex!;
        } else {
          _largeInitialIndex = null;
          _itemOffset = 0;
        }
      });
    }
    _scheduleSave();
  }

  void _goTo(int page, int char) {
    final t = _text;
    _page = page;
    _char = char;
    if (_mode == ViewMode.large) {
      if (t == null || !t.pageStart.containsKey(page)) {
        _showSnack('Still preparing large text for page $page… switching to the original page.');
        _pageY = 0;
        _switchMode();
        return;
      }
      final idx = t.indexFor(page, char);
      _itemScroll.jumpTo(index: idx, alignment: 0.02);
    } else {
      var y = 0.0;
      if (t != null && t.pageStart.containsKey(page)) {
        y = math.max(0, t.paras[t.indexFor(page, char)].top - 0.02);
      }
      _goToOriginal(page, y, null);
    }
    setState(() {});
    _scheduleSave();
  }

  void _goToOriginal(int page, double yFrac, double? zoom) {
    if (!_pdfController.isReady) return;
    final layouts = _pdfController.layout.pageLayouts;
    if (page < 1 || page > layouts.length) return;
    final r = layouts[page - 1];
    final z = zoom ?? _pdfController.value.zoom;
    final vis = _pdfController.visibleRect;
    _pdfController.goToPosition(documentOffset: Offset(vis.left, r.top + yFrac * r.height), zoom: z);
  }

  // ------------------------------------------------------------ highlights

  Future<void> _addHighlight(int page, int start, int end, String text) async {
    final clean = text.replaceAll(RegExp(r'-\s*\n\s*'), '').replaceAll(RegExp(r'\s+'), ' ').trim();
    if (clean.isEmpty || _fp == null) return;
    await AppDb.instance.addHighlight(
      _fp!,
      Highlight(page: page, start: start, end: end, text: clean, created: DateTime.now().millisecondsSinceEpoch),
    );
    await _reloadHighlights();
    _showSnack('Highlighted · saved to Notes', short: true);
  }

  Future<void> _removeHighlightsIn(int page, int start, int end) async {
    for (final h in _highlights.where((h) => h.page == page && h.start < end && h.end > start)) {
      await AppDb.instance.deleteHighlight(h.id!);
    }
    await _reloadHighlights();
  }

  Future<void> _reloadHighlights() async {
    _highlights = await AppDb.instance.highlights(_fp!);
    await _preloadHighlightTexts();
    if (mounted) setState(() {});
  }

  Future<void> _preloadHighlightTexts() async {
    final doc = _doc;
    if (doc == null) return;
    for (final pg in _highlights.map((h) => h.page).toSet()) {
      if (_origTexts.containsKey(pg) || pg > doc.pages.length) continue;
      try {
        _origTexts[pg] = await doc.pages[pg - 1].loadStructuredText();
      } catch (_) {}
    }
    if (mounted) setState(() {});
  }

  // --------------------------------------------------------------- sheets

  Future<void> _openNotes() async {
    final target = await Navigator.of(context).push<Highlight>(
      MaterialPageRoute(
        builder: (_) => NotesScreen(title: p.basenameWithoutExtension(widget.path), fp: _fp!),
      ),
    );
    await _reloadHighlights();
    if (target != null) _goTo(target.page, target.start);
  }

  Future<void> _goToPageDialog() async {
    final doc = _doc;
    if (doc == null) return;
    final ctrl = TextEditingController();
    final page = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Go to page'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(hintText: '1 – ${doc.pages.length}'),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, int.tryParse(ctrl.text)), child: const Text('Go')),
        ],
      ),
    );
    if (page != null && page >= 1 && page <= doc.pages.length) _goTo(page, 0);
  }

  void _showSnack(String msg, {bool short = false}) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: Duration(milliseconds: short ? 1200 : 2500),
          behavior: SnackBarBehavior.floating,
          margin: EdgeInsets.fromLTRB(16, 0, 16, MediaQuery.sizeOf(context).height * 0.15 + 8),
        ),
      );
  }

  // ---------------------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    final c = _s.colors;
    final h = MediaQuery.sizeOf(context).height;
    final stripH = math.max(56.0, h * 0.08);
    final barH = math.max(48.0, h * 0.055);

    Widget body;
    if (_error != null) {
      body = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.text),
          ),
        ),
      );
    } else if (_doc == null || _text == null) {
      body = Center(child: CircularProgressIndicator(color: c.muted));
    } else if (_mode == ViewMode.large) {
      body = _buildLarge(c);
    } else {
      body = _buildOriginal(c);
    }

    final ready = _doc != null && _text != null;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _s.theme == ReaderTheme.dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        backgroundColor: c.background,
        body: SafeArea(
          bottom: false,
          child: Column(
            children: [
              Expanded(child: body),
              if (ready)
                SizedBox(
                  height: stripH,
                  child: _mode == ViewMode.large
                      ? OriginalStrip(
                          doc: _doc!,
                          page: _page,
                          yFrac: _currentStripY(),
                          markHeight: _currentStripMarkHeight(),
                          colors: c,
                          onTap: _switchMode,
                        )
                      : LargeTextStrip(
                          text: _currentParaText(),
                          page: _page,
                          pageCount: _doc!.pages.length,
                          colors: c,
                          onTap: _switchMode,
                        ),
                ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                height: _barVisible ? barH + MediaQuery.paddingOf(context).bottom : 0,
                child: ClipRect(
                  child: ReaderBottomBar(
                    height: barH,
                    colors: c,
                    page: _page,
                    pageCount: _doc?.pages.length ?? 0,
                    notesCount: _highlights.length,
                    largeMode: _mode == ViewMode.large,
                    onLibrary: () {
                      _saveNow();
                      widget.onOpenLibrary();
                    },
                    onNotes: ready ? _openNotes : null,
                    onAppearance: ready
                        ? () => showAppearanceSheet(
                            context,
                            largeMode: _mode == ViewMode.large,
                            onSwitchMode: _switchMode,
                          )
                        : null,
                    onPage: ready ? _goToPageDialog : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  double _currentStripY() {
    final t = _text;
    if (t != null && _topIndex < t.paras.length) {
      final para = t.paras[_topIndex];
      if (!para.image) return para.top;
    }
    return _pageY;
  }

  double _currentStripMarkHeight() {
    final t = _text;
    if (t != null && _topIndex < t.paras.length) {
      final para = t.paras[_topIndex];
      if (!para.image) return (para.bottom - para.top).clamp(0.012, 0.2);
    }
    return 0.02;
  }

  String _currentParaText() {
    final t = _text;
    if (t != null && t.pageStart.containsKey(_page) && _topIndex < t.paras.length) {
      final para = t.paras[_topIndex];
      if (!para.image) return para.text;
    }
    return '';
  }

  void _toggleBar() => setState(() => _barVisible = !_barVisible);

  // ------------------------------------------------------ large-text view

  Widget _buildLarge(ReaderColors c) {
    final t = _text!;
    if (_largeInitialIndex == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: c.muted),
            const SizedBox(height: 16),
            Text('Preparing large text… ${t.pagesReady}/${t.doc.pages.length}', style: TextStyle(color: c.muted)),
            const SizedBox(height: 8),
            TextButton(onPressed: _switchMode, child: const Text('Read original page meanwhile')),
          ],
        ),
      );
    }
    final width = MediaQuery.sizeOf(context).width;
    final hPad = width > 700 ? (width - 640) / 2 : 20.0;
    return ScrollablePositionedList.builder(
      key: ValueKey('large-$_largeInitialIndex'),
      itemCount: t.paras.length,
      initialScrollIndex: _largeInitialIndex!.clamp(0, math.max(0, t.paras.length - 1)),
      initialAlignment: _largeInitialAlign,
      itemScrollController: _itemScroll,
      itemPositionsListener: _itemPositions,
      padding: EdgeInsets.fromLTRB(hPad, 12, hPad, 40),
      itemBuilder: (ctx, i) => _paraWidget(t, i, c),
    );
  }

  Widget _paraWidget(BookText t, int i, ReaderColors c) {
    final para = t.paras[i];
    final pageBreak = i > 0 && t.paras[i - 1].page != para.page;
    final children = <Widget>[];
    if (pageBreak) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 14),
          child: Row(
            children: [
              Expanded(child: Divider(color: c.muted.withValues(alpha: 0.25), height: 1)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Text('${para.page}', style: TextStyle(color: c.muted.withValues(alpha: 0.7), fontSize: 11)),
              ),
              Expanded(child: Divider(color: c.muted.withValues(alpha: 0.25), height: 1)),
            ],
          ),
        ),
      );
    }
    if (para.image) {
      final page = t.doc.pages[para.page - 1];
      children.add(
        GestureDetector(
          onTap: _toggleBar,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: AspectRatio(
              aspectRatio: page.width / page.height,
              child: PageImage(page: page, filter: _s.pageFilter),
            ),
          ),
        ),
      );
    } else {
      children.add(
        Padding(
          padding: EdgeInsets.only(
            bottom: _s.fontSize * (para.heading ? 0.6 : 0.85),
            top: para.heading ? _s.fontSize * 0.5 : 0,
          ),
          child: _ParagraphText(
            para: para,
            highlights: _highlights,
            colors: c,
            fontSize: para.heading ? _s.fontSize * 1.2 : _s.fontSize,
            lineHeight: _s.lineHeight,
            serif: _s.serif,
            bold: para.heading,
            onTap: _toggleBar,
            onHighlight: (s, e, text) => _addHighlight(para.page, s, e, text),
            onRemove: (s, e) => _removeHighlightsIn(para.page, s, e),
          ),
        ),
      );
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
  }

  // -------------------------------------------------------- original view

  Widget _buildOriginal(ReaderColors c) {
    return PdfViewer(
      PdfDocumentRefDirect(_doc!, autoDispose: false),
      controller: _pdfController,
      params: PdfViewerParams(
        backgroundColor: c.background,
        pageDropShadow: null,
        pageImageColorFilter: _s.pageFilter,
        onViewerReady: (doc, ctrl) {
          _pdfReady = true;
          final tgt = _pendingOriginalTarget;
          _pendingOriginalTarget = null;
          if (tgt != null) {
            // Wait one frame so the layout is final, then restore the spot.
            WidgetsBinding.instance.addPostFrameCallback((_) => _goToOriginal(tgt.page, tgt.y, tgt.zoom));
          }
          ctrl.addListener(_onOriginalChanged);
        },
        onGeneralTap: (ctx, ctrl, d) {
          if (d.type == PdfViewerGeneralTapType.tap) {
            _toggleBar();
            return true;
          }
          return false;
        },
        textSelectionParams: const PdfTextSelectionParams(enabled: true),
        customizeContextMenuItems: (params, items) {
          if (params.contextMenuFor != PdfViewerPart.selectedText) return;
          items.insert(
            0,
            ContextMenuButtonItem(
              label: 'Highlight',
              onPressed: () async {
                final ranges = await params.textSelectionDelegate.getSelectedTextRanges();
                params.dismissContextMenu();
                for (final r in ranges) {
                  await _addHighlight(r.pageNumber, r.start, r.end, r.text);
                }
                await params.textSelectionDelegate.clearTextSelection();
              },
            ),
          );
        },
        pageOverlaysBuilder: (ctx, pageRect, page) {
          final hs = _highlights.where((h) => h.page == page.pageNumber).toList();
          final text = _origTexts[page.pageNumber];
          if (hs.isEmpty || text == null) return const [];
          return [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _PageHighlightPainter(page: page, text: text, highlights: hs, color: c.highlight),
                ),
              ),
            ),
          ];
        },
      ),
    );
  }
}

/// Paints saved highlights on the original page.
class _PageHighlightPainter extends CustomPainter {
  _PageHighlightPainter({required this.page, required this.text, required this.highlights, required this.color});
  final PdfPage page;
  final PdfPageText text;
  final List<Highlight> highlights;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color.withValues(alpha: 0.45);
    final rects = text.charRects;
    for (final h in highlights) {
      Rect? line;
      for (var i = h.start; i < h.end && i < rects.length; i++) {
        final r = rects[i];
        if (r.isEmpty) continue;
        final rr = r.toRect(page: page, scaledPageSize: size);
        if (line != null && (rr.center.dy - line.center.dy).abs() < line.height * 0.5) {
          line = line.expandToInclude(rr);
        } else {
          if (line != null) canvas.drawRect(line, paint);
          line = rr;
        }
      }
      if (line != null) canvas.drawRect(line, paint);
    }
  }

  @override
  bool shouldRepaint(_PageHighlightPainter old) => old.highlights != highlights || old.text != text;
}

/// One paragraph in large-text mode: selectable, shows highlights, and adds
/// "Highlight" / "Remove highlight" to the selection menu.
class _ParagraphText extends StatelessWidget {
  const _ParagraphText({
    required this.para,
    required this.highlights,
    required this.colors,
    required this.fontSize,
    required this.lineHeight,
    required this.serif,
    required this.bold,
    required this.onTap,
    required this.onHighlight,
    required this.onRemove,
  });

  final Para para;
  final List<Highlight> highlights;
  final ReaderColors colors;
  final double fontSize;
  final double lineHeight;
  final bool serif;
  final bool bold;
  final VoidCallback onTap;
  final void Function(int start, int end, String text) onHighlight;
  final void Function(int start, int end) onRemove;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(
      fontSize: fontSize,
      height: lineHeight,
      color: colors.text,
      fontFamily: serif ? 'serif' : null,
      fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
    );
    // Output ranges covered by highlights.
    final ranges = <(int, int)>[];
    for (final h in highlights) {
      if (h.page != para.page || h.end <= para.start || h.start >= para.end) continue;
      final a = para.outOffsetFor(h.start);
      final b = para.outOffsetFor(h.end);
      if (b > a) ranges.add((a, b));
    }
    ranges.sort((x, y) => x.$1.compareTo(y.$1));
    final spans = <TextSpan>[];
    var pos = 0;
    for (final (a, b) in ranges) {
      if (a < pos) {
        if (b > pos) {
          spans.add(
            TextSpan(
              text: para.text.substring(pos, b),
              style: TextStyle(backgroundColor: colors.highlight),
            ),
          );
          pos = b;
        }
        continue;
      }
      if (a > pos) spans.add(TextSpan(text: para.text.substring(pos, a)));
      spans.add(
        TextSpan(
          text: para.text.substring(a, b),
          style: TextStyle(backgroundColor: colors.highlight),
        ),
      );
      pos = b;
    }
    if (pos < para.text.length) spans.add(TextSpan(text: para.text.substring(pos)));

    return SelectableText.rich(
      TextSpan(style: base, children: spans),
      textAlign: TextAlign.start,
      onTap: onTap,
      contextMenuBuilder: (ctx, state) {
        final sel = state.textEditingValue.selection;
        final items = <ContextMenuButtonItem>[];
        if (!sel.isCollapsed) {
          var a = math.min(sel.start, sel.end), b = math.max(sel.start, sel.end);
          // Fingers are imprecise: grow the selection to whole words.
          bool word(int i) => i >= 0 && i < para.text.length && _isWordChar(para.text.codeUnitAt(i));
          while (a > 0 && word(a - 1) && word(a)) {
            a--;
          }
          while (b < para.text.length && word(b) && word(b - 1)) {
            b++;
          }
          final srcA = para.map[a.clamp(0, para.map.length - 1)];
          final srcB = para.map[(b - 1).clamp(0, para.map.length - 1)] + 1;
          final overlaps = ranges.any((r) => r.$1 < b && r.$2 > a);
          items.add(
            ContextMenuButtonItem(
              label: 'Highlight',
              onPressed: () {
                onHighlight(srcA, srcB, para.text.substring(a, b));
                state.hideToolbar();
                state.userUpdateTextEditingValue(
                  state.textEditingValue.copyWith(selection: TextSelection.collapsed(offset: b)),
                  SelectionChangedCause.toolbar,
                );
              },
            ),
          );
          if (overlaps) {
            items.add(
              ContextMenuButtonItem(
                label: 'Remove highlight',
                onPressed: () {
                  onRemove(srcA, srcB);
                  state.hideToolbar();
                },
              ),
            );
          }
        }
        items.addAll(state.contextMenuButtonItems);
        return AdaptiveTextSelectionToolbar.buttonItems(anchors: state.contextMenuAnchors, buttonItems: items);
      },
    );
  }
}

bool _isWordChar(int c) =>
    (c >= 48 && c <= 57) ||
    (c >= 65 && c <= 90) ||
    (c >= 97 && c <= 122) ||
    c == 39 ||
    c == 0x2019 ||
    (c > 0xBF && c != 0x2014 && c != 0x2013 && c != 0x201C && c != 0x201D);
