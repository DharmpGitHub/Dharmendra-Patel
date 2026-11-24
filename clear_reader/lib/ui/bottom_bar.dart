import 'package:material_ui/material_ui.dart';

import '../data/settings.dart';

/// The only controls in the reader: Library · Notes · Aa · page.
class ReaderBottomBar extends StatelessWidget {
  const ReaderBottomBar({
    super.key,
    required this.height,
    required this.colors,
    required this.page,
    required this.pageCount,
    required this.notesCount,
    required this.largeMode,
    required this.onLibrary,
    required this.onNotes,
    required this.onAppearance,
    required this.onPage,
  });

  final double height;
  final ReaderColors colors;
  final int page;
  final int pageCount;
  final int notesCount;
  final bool largeMode;
  final VoidCallback onLibrary;
  final VoidCallback? onNotes;
  final VoidCallback? onAppearance;
  final VoidCallback? onPage;

  @override
  Widget build(BuildContext context) {
    final c = colors;
    return Container(
      color: c.bar,
      padding: EdgeInsets.only(bottom: MediaQuery.paddingOf(context).bottom),
      child: SizedBox(
        height: height,
        child: Row(
          children: [
            _btn(Icons.local_library_outlined, 'Library', onLibrary),
            _btn(Icons.sticky_note_2_outlined, notesCount > 0 ? 'Notes $notesCount' : 'Notes', onNotes),
            _btn(Icons.text_fields, 'Aa', onAppearance),
            Expanded(
              child: InkWell(
                onTap: onPage,
                child: Center(
                  child: Text(
                    pageCount == 0 ? '' : '$page / $pageCount',
                    style: TextStyle(color: c.muted, fontSize: 13, fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback? onTap) => Expanded(
    child: InkWell(
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 20, color: colors.text.withValues(alpha: onTap == null ? 0.3 : 0.8)),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 10.5, color: colors.muted)),
        ],
      ),
    ),
  );
}
