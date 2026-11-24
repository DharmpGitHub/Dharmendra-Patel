import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

import '../data/settings.dart';

/// The thin band under the large text: shows the real PDF page, at its
/// normal look, around the line being read. Tap it to open the original page.
class OriginalStrip extends StatefulWidget {
  const OriginalStrip({
    super.key,
    required this.doc,
    required this.page,
    required this.yFrac,
    required this.markHeight,
    required this.colors,
    required this.onTap,
  });

  final PdfDocument doc;
  final int page;

  /// Top of the current paragraph as a fraction of page height.
  final double yFrac;
  final double markHeight;
  final ReaderColors colors;
  final VoidCallback onTap;

  @override
  State<OriginalStrip> createState() => _OriginalStripState();
}

class _OriginalStripState extends State<OriginalStrip> {
  final _cache = <int, ui.Image>{};
  final _loading = <int>{};
  double _renderedWidth = 0;

  @override
  void dispose() {
    for (final i in _cache.values) {
      i.dispose();
    }
    super.dispose();
  }

  Future<void> _ensure(int page, double width) async {
    if (_cache.containsKey(page) || _loading.contains(page)) return;
    if (page < 1 || page > widget.doc.pages.length) return;
    _loading.add(page);
    final pg = widget.doc.pages[page - 1];
    final w = width.clamp(200.0, 1600.0);
    final h = w * pg.height / pg.width;
    try {
      final img = await pg.renderForDisplay(fullWidth: w, fullHeight: h, backgroundColor: 0xFFFFFFFF);
      if (!mounted) {
        img?.dispose();
        return;
      }
      if (img != null) {
        _cache[page] = img;
        // Keep memory low: current page and neighbours only.
        final drop = _cache.keys.where((k) => (k - widget.page).abs() > 1).toList();
        for (final k in drop) {
          _cache.remove(k)?.dispose();
        }
        setState(() {});
      }
    } catch (_) {
    } finally {
      _loading.remove(page);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: widget.onTap,
      child: LayoutBuilder(
        builder: (ctx, box) {
          final dpr = MediaQuery.devicePixelRatioOf(ctx);
          final width = box.maxWidth * dpr;
          if (_renderedWidth != width) {
            _renderedWidth = width;
            for (final i in _cache.values) {
              i.dispose();
            }
            _cache.clear();
          }
          _ensure(widget.page, width);
          _ensure(widget.page + 1, width);
          final img = _cache[widget.page];
          return Container(
            decoration: BoxDecoration(
              color: c.bar,
              border: Border(top: BorderSide(color: c.muted.withValues(alpha: 0.25))),
            ),
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (img != null)
                  CustomPaint(
                    painter: _StripPainter(
                      image: img,
                      yFrac: widget.yFrac,
                      markHeight: widget.markHeight,
                      filter: Settings.instance.pageFilter,
                    ),
                  ),
                Positioned(
                  right: 6,
                  bottom: 4,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: c.bar.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text('Original ▸', style: TextStyle(fontSize: 10, color: c.muted)),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StripPainter extends CustomPainter {
  _StripPainter({required this.image, required this.yFrac, required this.markHeight, required this.filter});
  final ui.Image image;
  final double yFrac;
  final double markHeight;
  final ColorFilter? filter;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / image.width; // logical px per image px
    final imgH = image.height * scale;
    // Place the current line ~35% down the strip.
    var top = yFrac * imgH - size.height * 0.35;
    top = top.clamp(0.0, (imgH - size.height).clamp(0.0, double.infinity));
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    if (filter != null) paint.colorFilter = filter;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, top / scale, image.width.toDouble(), size.height / scale),
      Offset.zero & size,
      paint,
    );
    // Mark where you are reading.
    final markTop = yFrac * imgH - top;
    final markH = (markHeight * imgH).clamp(6.0, size.height);
    canvas.drawRect(Rect.fromLTWH(0, markTop - 2, 4, markH + 4), Paint()..color = const Color(0xFFE0A100));
    canvas.drawRect(Rect.fromLTWH(4, markTop - 2, size.width - 4, markH + 4), Paint()..color = const Color(0x22E0A100));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_StripPainter old) =>
      old.image != image || old.yFrac != yFrac || old.markHeight != markHeight || old.filter != filter;
}

/// In original-page mode the strip shows the current passage in large text.
class LargeTextStrip extends StatelessWidget {
  const LargeTextStrip({
    super.key,
    required this.text,
    required this.page,
    required this.pageCount,
    required this.colors,
    required this.onTap,
  });

  final String text;
  final int page;
  final int pageCount;
  final ReaderColors colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: c.bar,
          border: Border(top: BorderSide(color: c.muted.withValues(alpha: 0.25))),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        child: Row(
          children: [
            Icon(Icons.text_increase, size: 20, color: c.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text.isEmpty ? 'Tap for large text' : text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.text, fontSize: 15, height: 1.3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
