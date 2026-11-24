import 'package:material_ui/material_ui.dart';

import '../data/settings.dart';

/// "Aa": text size, spacing, font, colours and view mode.
Future<void> showAppearanceSheet(BuildContext context, {required bool largeMode, required VoidCallback onSwitchMode}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Settings.instance.colors.bar,
    showDragHandle: true,
    builder: (ctx) => ListenableBuilder(
      listenable: Settings.instance,
      builder: (ctx, _) {
        final s = Settings.instance;
        final c = s.colors;
        final label = TextStyle(color: c.muted, fontSize: 12);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SegmentedButton<bool>(
                  segments: const [
                    ButtonSegment(value: true, label: Text('Large text'), icon: Icon(Icons.text_increase)),
                    ButtonSegment(
                      value: false,
                      label: Text('Original page'),
                      icon: Icon(Icons.picture_as_pdf_outlined),
                    ),
                  ],
                  selected: {largeMode},
                  onSelectionChanged: (v) {
                    if (v.first != largeMode) {
                      Navigator.pop(ctx);
                      onSwitchMode();
                    }
                  },
                ),
                const SizedBox(height: 16),
                Text('Text size  ${s.fontSize.round()}', style: label),
                Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.remove, color: c.text),
                      onPressed: () => s.fontSize = (s.fontSize - 1).clamp(12, 44),
                    ),
                    Expanded(
                      child: Slider(
                        value: s.fontSize,
                        min: 12,
                        max: 44,
                        divisions: 32,
                        onChanged: (v) => s.fontSize = v,
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.add, color: c.text),
                      onPressed: () => s.fontSize = (s.fontSize + 1).clamp(12, 44),
                    ),
                  ],
                ),
                Text('Line spacing', style: label),
                Slider(value: s.lineHeight, min: 1.2, max: 2.0, divisions: 8, onChanged: (v) => s.lineHeight = v),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: SegmentedButton<bool>(
                        segments: const [
                          ButtonSegment(value: true, label: Text('Serif')),
                          ButtonSegment(value: false, label: Text('Sans')),
                        ],
                        selected: {s.serif},
                        onSelectionChanged: (v) => s.serif = v.first,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [for (final t in ReaderTheme.values) _ThemeDot(theme: t, selected: s.theme == t)],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ThemeDot extends StatelessWidget {
  const _ThemeDot({required this.theme, required this.selected});
  final ReaderTheme theme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = ReaderColors.of(theme);
    return GestureDetector(
      onTap: () => Settings.instance.theme = theme,
      child: Column(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: c.background,
              shape: BoxShape.circle,
              border: Border.all(
                color: selected ? const Color(0xFFE0A100) : c.muted.withValues(alpha: 0.4),
                width: selected ? 3 : 1,
              ),
            ),
            child: Center(
              child: Text(
                'Aa',
                style: TextStyle(color: c.text, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            theme.name[0].toUpperCase() + theme.name.substring(1),
            style: TextStyle(fontSize: 11, color: Settings.instance.colors.muted),
          ),
        ],
      ),
    );
  }
}
