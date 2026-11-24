import 'dart:convert';
import 'dart:math' as math;

/// Bump when the algorithm changes so cached pages are rebuilt.
const reflowVersion = 3;

/// One block in the large-text view.
///
/// [map] links every character of [text] to its character index in the
/// page's original text, so highlights, reading position and the
/// original-page strip all stay in sync with the real PDF.
class Para {
  Para({
    required this.page,
    required this.text,
    required this.map,
    required this.top,
    required this.bottom,
    this.heading = false,
    this.image = false,
  });

  final int page;
  final String text;
  final List<int> map;

  /// Vertical extent on the page as fractions of page height (0 = top).
  final double top;
  final double bottom;
  final bool heading;

  /// True when the page has no usable text (scanned page, drawing...):
  /// the large-text view shows the page picture instead.
  final bool image;

  int get start => map.isEmpty ? 0 : map.first;
  int get end => map.isEmpty ? 0 : map.last + 1;

  /// First output offset whose source index is >= [src].
  int outOffsetFor(int src) {
    var lo = 0, hi = map.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (map[mid] < src) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  Map<String, Object> toJson() => {
    't': text,
    'm': _encodeMap(map),
    'y': [top, bottom],
    if (heading) 'h': 1,
    if (image) 'i': 1,
  };

  static Para fromJson(int page, Map<String, dynamic> j) {
    final y = (j['y'] as List).cast<num>();
    return Para(
      page: page,
      text: j['t'] as String,
      map: _decodeMap(j['m'] as List),
      top: y[0].toDouble(),
      bottom: y[1].toDouble(),
      heading: j['h'] == 1,
      image: j['i'] == 1,
    );
  }
}

/// Run-length encode the (mostly consecutive) index map.
List<int> _encodeMap(List<int> m) {
  final out = <int>[];
  var i = 0;
  while (i < m.length) {
    final start = m[i];
    var len = 1;
    while (i + len < m.length && m[i + len] == start + len) {
      len++;
    }
    out
      ..add(start)
      ..add(len);
    i += len;
  }
  return out;
}

List<int> _decodeMap(List enc) {
  final out = <int>[];
  for (var i = 0; i + 1 < enc.length; i += 2) {
    final s = enc[i] as int, n = enc[i + 1] as int;
    for (var k = 0; k < n; k++) {
      out.add(s + k);
    }
  }
  return out;
}

String encodePage(List<Para> paras) => jsonEncode(paras.map((e) => e.toJson()).toList());

List<Para> decodePage(int page, String data) =>
    (jsonDecode(data) as List).map((e) => Para.fromJson(page, e as Map<String, dynamic>)).toList();

/// Character box in PDF coordinates (y grows upwards).
class CharBox {
  const CharBox(this.left, this.top, this.right, this.bottom);
  final double left, top, right, bottom;
  double get height => top - bottom;
  bool get isEmpty => right <= left || top <= bottom;
}

class _Line {
  _Line(this.start, this.end, this.text);
  final int start; // index of first char in page text
  final int end; // exclusive
  final String text;
  double left = double.infinity, right = -double.infinity;
  double top = -double.infinity, bottom = double.infinity; // PDF coords
  final heights = <double>[];
  double get height => heights.isEmpty ? 0 : _median(heights);
  String get trimmed => text.trim();
}

double _median(List<double> v) {
  if (v.isEmpty) return 0;
  final s = [...v]..sort();
  return s[s.length ~/ 2];
}

final _pageNumberRe = RegExp(
  r'^\s*(page\s*)?[-–—(\[]?\s*([0-9]{1,4}|[ivxlcdm]{1,7})\s*[-–—)\]]?\s*$',
  caseSensitive: false,
);
final _bulletRe = RegExp(r'^\s*([•●▪◦■□➢►\-–—*]|\(?[0-9]{1,3}[.)]|\(?[a-zA-Z][.)])\s');
final _sentenceEnd = RegExp(r'''[.!?:;"”’)\]]\s*$''');

/// Normalises a header/footer line so "Chapter 3 · 41" and "Chapter 3 · 42"
/// count as the same running header.
String headerKey(String s) => s.trim().toLowerCase().replaceAll(RegExp(r'[0-9ivxlcdm]+\b'), '#');

/// Converts one page's text into readable paragraphs.
///
/// [text]/[boxes] come from the PDF engine (same length, line breaks as
/// '\n'). [repeatedEdgeLines] holds [headerKey]s of running headers/footers
/// detected across pages; such lines are dropped.
List<Para> reflowPage({
  required int page,
  required String text,
  required List<CharBox> boxes,
  required double pageHeight,
  Set<String> repeatedEdgeLines = const {},
  String? rawText,
  List<CharBox>? rawBoxes,
}) {
  final glyphs = (rawText != null && rawBoxes != null) ? _GlyphIndex(rawText, rawBoxes) : null;
  // ---- 1. split into lines with geometry
  final lines = <_Line>[];
  var s = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i == text.length || text.codeUnitAt(i) == 10) {
      if (i > s) {
        final ln = _Line(s, i, text.substring(s, i));
        for (var k = s; k < i && k < boxes.length; k++) {
          final b = boxes[k];
          if (b.isEmpty || text.codeUnitAt(k) == 32) continue;
          ln.left = math.min(ln.left, b.left);
          ln.right = math.max(ln.right, b.right);
          ln.top = math.max(ln.top, b.top);
          ln.bottom = math.min(ln.bottom, b.bottom);
          final code = text.codeUnitAt(k);
          final est = _sizeEstimate(code, glyphs?.heightFor(code, b) ?? b.height);
          if (est > 0) ln.heights.add(est);
        }
        if (ln.trimmed.isNotEmpty && ln.heights.isNotEmpty) lines.add(ln);
      }
      s = i + 1;
    }
  }

  final meaningful = lines.fold<int>(0, (a, l) => a + l.trimmed.replaceAll(RegExp(r'\s'), '').length);
  final garbled = RegExp('[�-]').allMatches(text).length;
  if (meaningful < 25 || garbled > meaningful * 0.1) {
    return [Para(page: page, text: '', map: const [], top: 0, bottom: 1, image: true)];
  }

  double yTop(double pdfY) => ((pageHeight - pdfY) / pageHeight).clamp(0.0, 1.0);

  // ---- 2. drop page numbers and running headers/footers at page edges
  final kept = <_Line>[];
  for (final l in lines) {
    final t = yTop(l.top), b = yTop(l.bottom);
    final atEdge = t < 0.09 || b > 0.91;
    if (atEdge && (_pageNumberRe.hasMatch(l.trimmed) || repeatedEdgeLines.contains(headerKey(l.trimmed)))) {
      continue;
    }
    kept.add(l);
  }
  if (kept.isEmpty) {
    return [Para(page: page, text: '', map: const [], top: 0, bottom: 1, image: true)];
  }

  final bodyH = _median(kept.map((l) => l.height).toList());
  final maxWidth = kept.fold<double>(0, (a, l) => math.max(a, l.right - l.left));

  // ---- 3. group lines into paragraphs
  final groups = <List<_Line>>[];
  for (final l in kept) {
    if (groups.isEmpty) {
      groups.add([l]);
      continue;
    }
    final prev = groups.last.last;
    final prevText = prev.trimmed;
    final gap = prev.bottom - l.top; // positive: l is below prev
    final sizeChange = (l.height - prev.height).abs() > 0.14 * math.max(l.height, prev.height);
    final movedUp = l.top > prev.top + bodyH * 0.5; // next column / out-of-order block
    final ended = _sentenceEnd.hasMatch(prevText);
    final prevShort = (prev.right - prev.left) < maxWidth * 0.8;
    final indented = l.left > prev.left + bodyH * 0.9 && (l.left - prev.left) < maxWidth * 0.3;

    final newPara =
        sizeChange ||
        (!movedUp && gap > bodyH * 0.75) ||
        (movedUp && ended) ||
        _bulletRe.hasMatch(l.text) ||
        (ended && prevShort) ||
        (ended && indented);
    if (newPara) {
      groups.add([l]);
    } else {
      groups.last.add(l);
    }
  }

  // ---- 4. join lines into clean text with an index map
  final out = <Para>[];
  for (final g in groups) {
    final sb = StringBuffer();
    final map = <int>[];
    for (var li = 0; li < g.length; li++) {
      final l = g[li];
      var a = l.start, z = l.end;
      while (a < z && _isSpace(text.codeUnitAt(a))) {
        a++;
      }
      while (z > a && _isSpace(text.codeUnitAt(z - 1))) {
        z--;
      }
      if (sb.isNotEmpty) {
        final cur = sb.toString();
        final last = cur.codeUnitAt(cur.length - 1);
        final next = a < z ? text.codeUnitAt(a) : 32;
        final hyphen = last == 45 /* - */ || last == 0xAD || last == 0x2010;
        final beforeHyphen = cur.length > 1 ? cur.codeUnitAt(cur.length - 2) : 32;
        if (hyphen && _isLetter(beforeHyphen) && _isLower(next)) {
          // "informa-" + "tion" -> "information"
          final kept = cur.substring(0, cur.length - 1);
          sb
            ..clear()
            ..write(kept);
          map.removeLast();
        } else if (last != 32) {
          sb.write(' ');
          map.add(math.max(l.start - 1, map.isEmpty ? 0 : map.last));
        }
      }
      var prevSpace = false;
      for (var k = a; k < z; k++) {
        final c = text.codeUnitAt(k);
        // Soft line-end hyphen (U+0002 from PDFium, or U+00AD) inside a word
        // that was already joined: drop it ("respon\u0002sibility").
        if ((c == 2 || c == 0xAD) && k + 1 < z && _isLower(text.codeUnitAt(k + 1))) continue;
        final sp = _isSpace(c);
        if (sp && prevSpace) continue;
        prevSpace = sp;
        // PDFium reports a line-end hyphen as U+0002; show it as '-'.
        sb.writeCharCode(sp ? 32 : (c == 2 ? 45 : c));
        map.add(k);
      }
    }
    final str = sb.toString();
    if (str.trim().isEmpty) continue;
    final hs = g.map((l) => l.height).toList();
    final h = _median(hs);
    out.add(
      Para(
        page: page,
        text: str,
        map: _monotonic(map),
        top: yTop(g.map((l) => l.top).reduce(math.max)),
        bottom: yTop(g.map((l) => l.bottom).reduce(math.min)),
        heading: h > bodyH * 1.15 && str.length < 220,
      ),
    );
  }
  return out;
}

/// Guarantees a non-decreasing map (needed for binary search).
List<int> _monotonic(List<int> m) {
  for (var i = 1; i < m.length; i++) {
    if (m[i] < m[i - 1]) m[i] = m[i - 1];
  }
  return m;
}

/// Finds the tight glyph box (from the raw PDF text layer) for a character
/// of the structured text, by character and position.
class _GlyphIndex {
  _GlyphIndex(String text, List<CharBox> boxes) {
    for (var i = 0; i < text.length && i < boxes.length; i++) {
      final b = boxes[i];
      if (b.isEmpty) continue;
      final c = text.codeUnitAt(i);
      if (c <= 32) continue;
      final cx = (b.left + b.right) / 2;
      _cells.putIfAbsent(_key(c, (cx / 4).floor()), () => []).add(b);
    }
  }
  final _cells = <int, List<CharBox>>{};
  static int _key(int c, int gx) => c * 100000 + gx;

  double? heightFor(int c, CharBox structured) {
    final cx = (structured.left + structured.right) / 2;
    final gx = (cx / 4).floor();
    CharBox? best;
    var bestD = 1e9;
    for (var dx = -1; dx <= 1; dx++) {
      for (final b in _cells[_key(c, gx + dx)] ?? const <CharBox>[]) {
        // must lie inside the structured (line-height) box vertically
        if (b.top > structured.top + 1 || b.bottom < structured.bottom - 1) continue;
        final d = ((b.left + b.right) / 2 - cx).abs();
        if (d < bestD) {
          bestD = d;
          best = b;
        }
      }
    }
    return best == null || bestD > 3 ? null : best.height;
  }
}

/// Estimated font size from one glyph's tight box. Glyph boxes depend on the
/// letter ("o" is short, "H" is tall), so scale by the letter's typical
/// height to get a value proportional to the real font size.
double _sizeEstimate(int c, double h) {
  if (h <= 0) return 0;
  if ((c >= 65 && c <= 90) || (c >= 48 && c <= 57) || 'bdfhklt'.codeUnits.contains(c)) return h / 0.72;
  if ('acemnorsuvwxz'.codeUnits.contains(c)) return h / 0.5;
  if ('gpqy'.codeUnits.contains(c)) return h / 0.7;
  if (c > 0x2FF) return h; // other scripts: use the box as is
  return 0;
}

bool _isSpace(int c) =>
    c == 32 || c == 9 || c == 10 || c == 13 || c == 0xA0 || c == 0x2002 || c == 0x2003 || c == 0x2009;
bool _isLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c > 0xBF;
bool _isLower(int c) => (c >= 97 && c <= 122) || (c > 0xDF && c < 0x250);

/// Text near the top/bottom edge of a page, used to learn running headers.
List<String> edgeLineKeys(String text, List<CharBox> boxes, double pageHeight) {
  final keys = <String>[];
  var s = 0;
  for (var i = 0; i <= text.length; i++) {
    if (i == text.length || text.codeUnitAt(i) == 10) {
      if (i > s) {
        double top = -double.infinity, bottom = double.infinity;
        for (var k = s; k < i && k < boxes.length; k++) {
          if (boxes[k].isEmpty) continue;
          top = math.max(top, boxes[k].top);
          bottom = math.min(bottom, boxes[k].bottom);
        }
        if (top > -double.infinity) {
          final t = (pageHeight - top) / pageHeight, b = (pageHeight - bottom) / pageHeight;
          final line = text.substring(s, i).trim();
          if ((t < 0.09 || b > 0.91) && line.length > 3 && line.length < 120) keys.add(headerKey(line));
        }
      }
      s = i + 1;
    }
  }
  return keys;
}
