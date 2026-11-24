// Runs the large-text (reflow) engine on real PDFs with the real PDFium
// engine and checks that the output is clean, complete and in reading order.
import 'dart:io';

import 'package:clear_reader/reflow/reflow.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pdfrx_engine/pdfrx_engine.dart';

const sentences = [
  'The river moved slowly past the old mill, carrying leaves and the quiet weight of autumn.',
  'Mira had walked this path every morning for eleven years, and still it surprised her.',
  'Nobody in the village remembered exactly when the bridge had been built, only that it had always been there.',
  'Understanding arrives gradually, the way morning light fills a valley before the sun is visible.',
  'Her grandfather used to say that patience was simply attention that refused to give up.',
  'Extraordinary circumstances rarely announce themselves; they accumulate like snow on a windowsill.',
  'She opened the notebook, read the first line again, and decided to continue anyway.',
  'Communication between the two families had been interrupted for nearly a generation.',
  'The responsibility felt heavier in the evening, when the workshop grew silent and cold.',
  'Every unfinished sentence in the letters seemed to be waiting for someone to complete it.',
];

Future<({List<Para> paras, List<String> pageTexts})> reflowFile(String path) async {
  final doc = await PdfDocument.openFile(path);
  final texts = <PdfPageText>[];
  final raws = <PdfPageRawText?>[];
  for (final p in doc.pages) {
    texts.add(await p.loadStructuredText());
    raws.add(await p.loadText());
  }
  List<CharBox> boxes(PdfPageText t) => [for (final r in t.charRects) CharBox(r.left, r.top, r.right, r.bottom)];
  final counts = <String, int>{};
  for (var i = 0; i < texts.length; i++) {
    for (final k in edgeLineKeys(texts[i].fullText, boxes(texts[i]), doc.pages[i].height).toSet()) {
      counts[k] = (counts[k] ?? 0) + 1;
    }
  }
  final repeated = {
    for (final e in counts.entries)
      if (e.value >= 3) e.key,
  };
  final paras = <Para>[];
  for (var i = 0; i < texts.length; i++) {
    paras.addAll(
      reflowPage(
        page: i + 1,
        text: texts[i].fullText,
        boxes: boxes(texts[i]),
        pageHeight: doc.pages[i].height,
        repeatedEdgeLines: repeated,
        rawText: raws[i]?.fullText,
        rawBoxes: raws[i] == null
            ? null
            : [for (final r in raws[i]!.charRects) CharBox(r.left, r.top, r.right, r.bottom)],
      ),
    );
  }
  final pageTexts = texts.map((t) => t.fullText).toList();
  await doc.dispose();
  return (paras: paras, pageTexts: pageTexts);
}

/// Text left over after removing every known sentence: should be only
/// headings, i.e. nothing was broken, merged wrongly or reordered.
String residue(String s) {
  var r = s;
  for (final x in sentences) {
    r = r.replaceAll(x, '');
  }
  return r.replaceAll(RegExp(r'\s+'), ' ').trim();
}

void main() {
  setUpAll(() async => pdfrxInitialize());

  test('novel: clean paragraphs, no headers/page numbers, hyphens joined', () async {
    final r = await reflowFile('test/pdfs/novel.pdf');
    final body = r.paras.where((p) => !p.heading && !p.image).toList();
    final headings = r.paras.where((p) => p.heading).map((p) => p.text.trim()).toList();
    print('novel: ${r.pageTexts.length} pages, ${r.paras.length} blocks, headings=$headings');

    expect(headings, ['Chapter 1', 'Chapter 2', 'Chapter 3', 'Chapter 4', 'Chapter 5', 'Chapter 6']);
    for (final p in body) {
      expect(p.text.contains('THE QUIET RIVER'), isFalse, reason: 'running header leaked: ${p.text}');
      expect(RegExp(r'[a-z]- [a-z]').hasMatch(p.text), isFalse, reason: 'unjoined hyphen: ${p.text}');
      expect(RegExp(r'(^|\s)[0-9]{1,3}(\s|\$)').hasMatch(p.text), isFalse, reason: 'page number leaked: ${p.text}');
    }
    // Paragraphs fully inside one page must be whole sentences only.
    for (var i = 0; i < body.length; i++) {
      final p = body[i];
      final firstOnPage = i == 0 || body[i - 1].page != p.page;
      final lastOnPage = i == body.length - 1 || body[i + 1].page != p.page;
      if (firstOnPage || lastOnPage) continue;
      expect(residue(p.text), isEmpty, reason: 'broken text on page ${p.page}: "${residue(p.text)}"');
    }
    // Every paragraph that continues onto the next page is split at the page
    // break; joined back together, still only whole sentences.
    final all = body
        .map((p) => p.text)
        .join(' ')
        .replaceAllMapped(RegExp(r'([a-z])- ([a-z])'), (m) => '${m[1]}${m[2]}');
    expect(residue(all), isEmpty);
  });

  test('paper: two columns read in order, headings detected', () async {
    final r = await reflowFile('test/pdfs/paper.pdf');
    final body = r.paras.where((p) => !p.heading && !p.image).toList();
    print('paper: ${r.paras.length} blocks, headings=${r.paras.where((p) => p.heading).map((p) => p.text).toList()}');
    for (final p in r.paras.where((p) => p.text.contains('Method and results') && !p.heading)) {
      print('NOT HEADING: ${p.text}');
    }
    expect(r.paras.first.text.trim(), 'Reading Comfort on Small Screens');
    expect(r.paras.where((p) => p.text.contains('Method and results')).every((p) => p.heading), isTrue);
    final joined = body.map((p) => p.text).join(' ').replaceAll('A. Researcher, B. Scientist', '');
    // The generator cuts sentences at the bottom of a column; those cut
    // starts are in the PDF itself. Anything else would mean wrong order.
    var rest = residue(joined);
    for (final x in sentences) {
      for (var n = x.length - 1; n >= 15; n--) {
        rest = rest.replaceAll(x.substring(0, n), '');
      }
    }
    expect(rest.trim(), isEmpty, reason: rest);
  });

  test('scanned pages fall back to the page picture', () async {
    final r = await reflowFile('test/pdfs/scanned.pdf');
    expect(r.paras.length, 2);
    expect(r.paras.every((p) => p.image), isTrue);
  });

  test('every character maps back to the right place in the PDF', () async {
    final r = await reflowFile('test/pdfs/novel.pdf');
    var checked = 0;
    for (final p in r.paras.where((p) => !p.image)) {
      final src = r.pageTexts[p.page - 1];
      for (var i = 0; i < p.text.length; i++) {
        final ch = p.text[i];
        if (ch == ' ') continue;
        expect(src[p.map[i]] == '\u0002' ? '-' : src[p.map[i]], ch, reason: 'page ${p.page} offset $i');
        // Highlights use the reverse lookup.
        expect(p.outOffsetFor(p.map[i]), i);
        checked++;
      }
    }
    print('mapped $checked characters');
  });

  test('cache round trip keeps paragraphs identical', () async {
    final r = await reflowFile('test/pdfs/novel.pdf');
    final page2 = r.paras.where((p) => p.page == 2).toList();
    final back = decodePage(2, encodePage(page2));
    expect(back.map((p) => p.text), page2.map((p) => p.text));
    expect(back.map((p) => p.map.join(',')), page2.map((p) => p.map.join(',')));
    expect(back.map((p) => p.top), page2.map((p) => p.top));
  });

  test('pdf files exist', () {
    expect(File('test/pdfs/novel.pdf').existsSync(), isTrue);
  });
}
