import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';

/// A whole PDF page drawn to fit the available width (used in large-text
/// mode for pages without text, e.g. scanned pages).
class PageImage extends StatefulWidget {
  const PageImage({super.key, required this.page, this.filter});
  final PdfPage page;
  final ColorFilter? filter;

  @override
  State<PageImage> createState() => _PageImageState();
}

class _PageImageState extends State<PageImage> {
  ui.Image? _image;
  double _width = 0;
  bool _busy = false;

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  Future<void> _render(double width) async {
    if (_busy || (width - _width).abs() < 1) return;
    _busy = true;
    _width = width;
    final w = width.clamp(100.0, 2400.0);
    final h = w * widget.page.height / widget.page.width;
    try {
      final img = await widget.page.renderForDisplay(fullWidth: w, fullHeight: h, backgroundColor: 0xFFFFFFFF);
      if (!mounted) {
        img?.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = img;
      });
    } catch (_) {
    } finally {
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, box) {
        _render(box.maxWidth * MediaQuery.devicePixelRatioOf(ctx));
        final img = _image;
        if (img == null) return const SizedBox.expand();
        final child = RawImage(image: img, width: box.maxWidth, height: box.maxHeight, fit: BoxFit.contain);
        return widget.filter == null ? child : ColorFiltered(colorFilter: widget.filter!, child: child);
      },
    );
  }
}
