# Clear Reader

A light, distraction-free PDF reader for Android (Windows and iOS later),
built with Flutter.

**The idea:** most of the screen shows the page's text re-flowed in large,
comfortable type. A thin strip under it always shows the real PDF page at the
line you are reading. Tap the strip to switch between the large text and the
original page.

## Install on your phone

1. Copy `../apk/ClearReader-0.1.1-universal.apk` to the phone. It works on
   every phone CPU type (64-bit, 32-bit, x86) and needs Android 7.0 or newer.
2. Open it and allow "Install unknown apps" for your file manager when Android asks.
3. Open **Clear Reader**, tap **Scan**, and allow **All files access** so it
   can list every PDF on the phone.

## Features

| | |
|---|---|
| **Exact resume** | Reopens the last book at the exact paragraph and scroll offset. The position is saved 0.4 s after every scroll and whenever the app goes to the background, so it survives the app being killed. Books are identified by content, so renaming or moving a file keeps its place. |
| **Large text** | Text is extracted from each page and rebuilt into paragraphs: headings detected, running headers and page numbers removed, hyphenated words rejoined, and two-column pages read in order. |
| **Original strip** | The bottom ~8% shows the real page around the current paragraph, with a yellow marker. Tap it to open the original page at the same spot. |
| **Highlights → Notes** | Select text and tap **Highlight**, in either mode. Selections snap to whole words. Highlights show in both views. |
| **Notes** | One scrolling page of all highlights in **page and reading order**. Long-press or drag to copy any part, or use **Copy all** or **Export .txt** (saved to Downloads). Tap `p. 12 ↗` to jump there. |
| **Library** | Scans the whole phone, including SD cards, for PDFs. Books you are reading are listed first with a progress bar. Includes search. |
| **Clean screen** | No status bar or clock. Bottom bar: Library · Notes · Aa · page number. Tap the page to hide or show the bar. |
| **Aa** | Text size, line spacing, serif or sans, Light / Sepia / Dark (the original page is tinted to match), and Large text / Original page. |
| **Scanned pages** | Pages with no text layer are shown as the page picture inside the large-text flow, so a page is never skipped. |

## Known limits (version 0.1)

- **Scanned books** have no text to enlarge, so they show as page pictures. OCR is planned for a later version.
- **Maths and tables** come out as plain text in large-text mode. Use the strip or the original page for those.
- **Old Hindi fonts** (Kruti Dev and similar) extract as wrong characters. Unicode Hindi works.
- A highlight in large-text mode stays within one paragraph. In original mode it can span pages.
- The APK is signed with a release key kept in `android/keystore/`, which is not in git. Keep a backup: future updates must be signed with the same key, or Android refuses to update the installed app.

## Build from source

```bash
flutter pub get
flutter test                                   # reflow tests on real PDFs
flutter build apk --release --split-per-abi    # Android
```

Requires Flutter 3.50+, Android SDK 37 and NDK 28.

## Code map

```
lib/main.dart                 start-up: opens the last book or the library
lib/data/db.dart              SQLite: library, positions, highlights, text cache
lib/data/scanner.dart         finds PDFs on the device (background isolate)
lib/data/settings.dart        text size, theme, last book
lib/reflow/reflow.dart        page text -> clean paragraphs (+ index map)
lib/reflow/book_text.dart     processes the whole book in the background, cached
lib/ui/reader_screen.dart     large-text / original views, position save & restore
lib/ui/original_strip.dart    the strip of the real page
lib/ui/notes_screen.dart      notes in page order, copy and export
lib/ui/library_screen.dart    library, scan, search
test/reflow_test.dart         runs the reflow on real PDFs (novel, 2-column paper, scan)
```

## Audit screenshots

See `docs/screenshots/`. They were taken from the same code running at phone size (412×870).
`08-resume-after-force-kill.png` shows the screen before a `kill -9` and after the restart;
the two are pixel-identical.
