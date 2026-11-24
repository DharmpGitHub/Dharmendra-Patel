import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/db.dart';
import 'reflow.dart';

/// Builds and holds the large-text version of a whole book.
///
/// Pages are processed in order in the background and cached in the
/// database, so a book is only analysed once.
class BookText extends ChangeNotifier {
  BookText(this.doc, this.fp);

  final PdfDocument doc;
  final String fp;

  /// All paragraphs of the book in reading order (grows while loading).
  final paras = <Para>[];

  /// Index in [paras] of each page's first paragraph (1-based page -> index).
  final pageStart = <int, int>{};

  int pagesReady = 0;
  bool get complete => pagesReady >= doc.pages.length;
  bool _disposed = false;

  Future<void> start() async {
    final cached = await AppDb.instance.cachedPages(fp, reflowVersion);
    final total = doc.pages.length;

    // Learn running headers/footers from a sample of pages first.
    final headerCounts = <String, int>{};
    if (cached.length < total) {
      final sample = <int>{
        for (var i = 1; i <= total && i <= 12; i++) i,
        for (var i = total ~/ 2; i <= total && i < total ~/ 2 + 8; i++) i,
      };
      for (final n in sample) {
        if (_disposed) return;
        final t = await _loadText(n);
        if (t == null) continue;
        for (final k in edgeLineKeys(t.fullText, _boxes(t), doc.pages[n - 1].height).toSet()) {
          headerCounts[k] = (headerCounts[k] ?? 0) + 1;
        }
      }
    }
    final repeated = {
      for (final e in headerCounts.entries)
        if (e.value >= 3) e.key,
    };

    final pending = <int, String>{};
    for (var n = 1; n <= total; n++) {
      if (_disposed) return;
      List<Para> list;
      final c = cached[n];
      if (c != null) {
        list = decodePage(n, c);
      } else {
        final t = await _loadText(n);
        final raw = t == null ? null : await _loadRaw(n);
        list = t == null
            ? [Para(page: n, text: '', map: const [], top: 0, bottom: 1, image: true)]
            : reflowPage(
                page: n,
                text: t.fullText,
                boxes: _boxes(t),
                pageHeight: doc.pages[n - 1].height,
                repeatedEdgeLines: repeated,
                rawText: raw?.fullText,
                rawBoxes: raw == null
                    ? null
                    : [for (final r in raw.charRects) CharBox(r.left, r.top, r.right, r.bottom)],
              );
        pending[n] = encodePage(list);
      }
      pageStart[n] = paras.length;
      paras.addAll(list);
      pagesReady = n;
      if (pending.length >= 20) {
        await AppDb.instance.cachePages(fp, reflowVersion, Map.of(pending));
        pending.clear();
      }
      if (n % 8 == 0 || n == total || c == null && n < 4) notifyListeners();
    }
    if (pending.isNotEmpty && !_disposed) {
      await AppDb.instance.cachePages(fp, reflowVersion, pending);
    }
    if (!_disposed) notifyListeners();
  }

  Future<PdfPageText?> _loadText(int n) async {
    try {
      return await doc.pages[n - 1].loadStructuredText();
    } catch (_) {
      return null;
    }
  }

  Future<PdfPageRawText?> _loadRaw(int n) async {
    try {
      return await doc.pages[n - 1].loadText();
    } catch (_) {
      return null;
    }
  }

  static List<CharBox> _boxes(PdfPageText t) => [
    for (final r in t.charRects) CharBox(r.left, r.top, r.right, r.bottom),
  ];

  /// Paragraph index containing (or nearest after) a page position.
  int indexFor(int page, int charIndex) {
    final s = pageStart[page];
    if (s == null) return paras.isEmpty ? 0 : paras.length - 1;
    final e = pageStart[page + 1] ?? paras.length;
    for (var i = s; i < e; i++) {
      if (paras[i].image) return i;
      if (charIndex < paras[i].end) return i;
    }
    return e - 1 < s ? s : e - 1;
  }

  /// Paragraph index nearest to a vertical position on a page.
  int indexForPageY(int page, double yFrac) {
    final s = pageStart[page];
    if (s == null) return 0;
    final e = pageStart[page + 1] ?? paras.length;
    // Closest paragraph starting at or above the line (works with columns).
    var best = s;
    var bestTop = -1.0;
    for (var i = s; i < e; i++) {
      final t = paras[i].top;
      if (t <= yFrac + 0.01 && t > bestTop) {
        best = i;
        bestTop = t;
      }
    }
    return best;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
