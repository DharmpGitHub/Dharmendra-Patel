import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:permission_handler/permission_handler.dart';

import '../data/db.dart';
import '../data/scanner.dart';
import '../data/settings.dart';

/// Every PDF on the device. Books you have opened are listed first with
/// their page.
class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.onOpen, this.canResume = false, this.onResume});
  final void Function(String path) onOpen;
  final bool canResume;
  final VoidCallback? onResume;

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  List<BookEntry> _books = [];
  bool _scanning = false;
  bool _loaded = false;
  String _query = '';
  bool _searching = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    _books = await AppDb.instance.books();
    _loaded = true;
    if (mounted) setState(() {});
    if (_books.isEmpty) await _scan(auto: true);
  }

  Future<bool> _ensurePermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    if (!mounted) return false;
    final go = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Find your PDFs'),
        content: const Text(
          'To list every PDF on this phone, allow “All files access” on the next screen.\n\n'
          'The app only reads PDFs. Nothing leaves your phone.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Continue')),
        ],
      ),
    );
    if (go != true) return false;
    final st = await Permission.manageExternalStorage.request();
    return st.isGranted;
  }

  Future<void> _scan({bool auto = false}) async {
    if (_scanning) return;
    if (!await _ensurePermission()) {
      if (!auto) _snack('Permission needed to scan for PDFs.');
      return;
    }
    setState(() => _scanning = true);
    try {
      final files = await scanDeviceForPdfs();
      await AppDb.instance.replaceLibrary(files);
      _books = await AppDb.instance.books();
      _snack('Found ${files.length} PDF${files.length == 1 ? '' : 's'}');
    } catch (e) {
      _snack('Scan failed: $e');
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _snack(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final c = Settings.instance.colors;
    final q = _query.toLowerCase();
    final list = q.isEmpty
        ? _books
        : _books.where((b) => b.name.toLowerCase().contains(q) || b.folder.toLowerCase().contains(q)).toList();
    final reading = list.where((b) => b.lastOpened != null).toList();
    final others = list.where((b) => b.lastOpened == null).toList();

    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            if (_searching)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: TextField(
                  autofocus: true,
                  style: TextStyle(color: c.text),
                  decoration: InputDecoration(
                    hintText: 'Search by name or folder',
                    hintStyle: TextStyle(color: c.muted),
                    prefixIcon: Icon(Icons.search, color: c.muted),
                    border: const OutlineInputBorder(borderSide: BorderSide.none),
                    filled: true,
                    fillColor: c.bar,
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            if (_scanning)
              LinearProgressIndicator(minHeight: 2, color: const Color(0xFFE0A100), backgroundColor: c.bar),
            Expanded(
              child: !_loaded
                  ? const SizedBox()
                  : list.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _scanning
                              ? 'Looking for PDFs on this phone…'
                              : _books.isEmpty
                              ? 'No PDFs yet.\n\nTap “Scan” to find every PDF on this phone.'
                              : 'Nothing matches “$_query”.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted, fontSize: 16, height: 1.5),
                        ),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.only(top: 8, bottom: 16),
                      children: [
                        if (reading.isNotEmpty) _header('Reading', c),
                        for (final b in reading) _tile(b, c),
                        if (others.isNotEmpty) _header('All PDFs · ${others.length}', c),
                        for (final b in others) _tile(b, c),
                      ],
                    ),
            ),
            Container(
              color: c.bar,
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              child: SizedBox(
                height: 52,
                child: Row(
                  children: [
                    if (widget.canResume) _btn(Icons.menu_book_outlined, 'Continue', widget.onResume, c),
                    _btn(
                      Icons.search,
                      'Search',
                      () => setState(() {
                        _searching = !_searching;
                        if (!_searching) _query = '';
                      }),
                      c,
                    ),
                    _btn(Icons.radar, _scanning ? 'Scanning…' : 'Scan', _scanning ? null : () => _scan(), c),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _header(String t, ReaderColors c) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
    child: Text(
      t.toUpperCase(),
      style: TextStyle(color: c.muted, fontSize: 11.5, letterSpacing: 0.8, fontWeight: FontWeight.w600),
    ),
  );

  Widget _tile(BookEntry b, ReaderColors c) {
    // Share of pages already finished (page 1 of 10 = 0%, last page = 100%).
    final progress = (b.page != null && b.pageCount != null && b.pageCount! > 0)
        ? (b.pageCount! <= 1 ? 1.0 : (b.page! - 1) / (b.pageCount! - 1))
        : null;
    return InkWell(
      onTap: () {
        if (!File(b.path).existsSync()) {
          _snack('File not found. Tap Scan to refresh.');
          return;
        }
        widget.onOpen(b.path);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 46,
              decoration: BoxDecoration(
                color: c.bar,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: c.muted.withValues(alpha: 0.25)),
              ),
              child: Icon(Icons.picture_as_pdf_outlined, size: 18, color: c.muted),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    b.name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.text, fontSize: 15),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    progress != null
                        ? 'Page ${b.page} of ${b.pageCount} · ${b.folder}'
                        : '${b.folder} · ${_size(b.size)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                  if (progress != null) ...[
                    const SizedBox(height: 6),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: progress,
                        minHeight: 3,
                        color: const Color(0xFFE0A100),
                        backgroundColor: c.muted.withValues(alpha: 0.15),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _size(int bytes) {
    if (bytes > 1 << 20) return '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return '${(bytes / 1024).round()} KB';
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap, ReaderColors c) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: c.text.withValues(alpha: onTap == null ? 0.3 : 0.8)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 10.5, color: c.muted)),
        ],
      ),
    ),
  );
}
