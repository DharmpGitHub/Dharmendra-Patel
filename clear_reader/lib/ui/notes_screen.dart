import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../data/db.dart';
import '../data/settings.dart';

/// All highlights of one book, in page and reading order, as one continuous
/// selectable text. Long-press (phone) or drag (mouse) to copy any part.
class NotesScreen extends StatefulWidget {
  const NotesScreen({super.key, required this.title, required this.fp});
  final String title;
  final String fp;

  @override
  State<NotesScreen> createState() => _NotesScreenState();
}

class _NotesScreenState extends State<NotesScreen> {
  List<Highlight>? _notes;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final n = await AppDb.instance.highlights(widget.fp);
    if (mounted) setState(() => _notes = n);
  }

  String _plain() {
    final sb = StringBuffer('${widget.title} — Notes\n\n');
    for (final h in _notes!) {
      sb.writeln('p. ${h.page}');
      sb.writeln(h.text);
      sb.writeln();
    }
    return sb.toString().trimRight();
  }

  Future<void> _copyAll() async {
    await Clipboard.setData(ClipboardData(text: _plain()));
    _snack('All notes copied');
  }

  Future<void> _export() async {
    try {
      final safe = widget.title.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      var dir = Directory('/storage/emulated/0/Download');
      if (!Platform.isAndroid || !dir.existsSync()) dir = Directory.systemTemp;
      final f = File('${dir.path}/$safe - notes.txt');
      await f.writeAsString(_plain());
      _snack('Saved to ${f.path}');
    } catch (e) {
      _snack('Could not save: $e');
    }
  }

  Future<void> _delete(Highlight h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this note?'),
        content: Text(h.text, maxLines: 4, overflow: TextOverflow.ellipsis),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Keep')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
        ],
      ),
    );
    if (ok == true) {
      await AppDb.instance.deleteHighlight(h.id!);
      await _load();
    }
  }

  void _snack(String m) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(m), behavior: SnackBarBehavior.floating));

  @override
  Widget build(BuildContext context) {
    final s = Settings.instance;
    final c = s.colors;
    final notes = _notes;
    final width = MediaQuery.sizeOf(context).width;
    final hPad = width > 700 ? (width - 640) / 2 : 20.0;
    return Scaffold(
      backgroundColor: c.background,
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Expanded(
              child: notes == null
                  ? const SizedBox()
                  : notes.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          'No notes yet.\n\nSelect text while reading and tap “Highlight”. '
                          'It appears here in page order.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: c.muted, fontSize: 16, height: 1.5),
                        ),
                      ),
                    )
                  : SelectionArea(
                      child: ListView(
                        padding: EdgeInsets.fromLTRB(hPad, 16, hPad, 32),
                        children: [
                          Text(
                            widget.title,
                            style: TextStyle(color: c.text, fontSize: 20, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text('${notes.length} notes · in page order', style: TextStyle(color: c.muted, fontSize: 13)),
                          const SizedBox(height: 20),
                          for (final h in notes) ...[
                            Row(
                              children: [
                                SelectionContainer.disabled(
                                  child: InkWell(
                                    onTap: () => Navigator.pop(context, h),
                                    borderRadius: BorderRadius.circular(6),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                      child: Text(
                                        'p. ${h.page}  ↗',
                                        style: const TextStyle(
                                          color: Color(0xFFB07D00),
                                          fontSize: 13,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                SelectionContainer.disabled(
                                  child: IconButton(
                                    visualDensity: VisualDensity.compact,
                                    iconSize: 18,
                                    icon: Icon(Icons.close, color: c.muted.withValues(alpha: 0.6)),
                                    tooltip: 'Remove',
                                    onPressed: () => _delete(h),
                                  ),
                                ),
                              ],
                            ),
                            Text(
                              h.text,
                              style: TextStyle(
                                color: c.text,
                                fontSize: s.fontSize * 0.85,
                                height: 1.5,
                                fontFamily: s.serif ? 'serif' : null,
                              ),
                            ),
                            const SizedBox(height: 22),
                          ],
                        ],
                      ),
                    ),
            ),
            Container(
              color: c.bar,
              padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
              child: SizedBox(
                height: 52,
                child: Row(
                  children: [
                    _btn(Icons.arrow_back, 'Back', () => Navigator.pop(context), c),
                    _btn(Icons.copy_all_outlined, 'Copy all', notes?.isNotEmpty == true ? _copyAll : null, c),
                    _btn(Icons.file_download_outlined, 'Export .txt', notes?.isNotEmpty == true ? _export : null, c),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
