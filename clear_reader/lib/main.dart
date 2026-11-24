import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'data/db.dart';
import 'data/settings.dart';
import 'ui/library_screen.dart';
import 'ui/reader_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  if (Platform.isWindows || Platform.isLinux) {
    // Desktop: SQLite through FFI (phones use the platform plugin).
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  await Settings.load();
  await AppDb.open();
  // Clean screen: no status bar, no clock. Swipe from an edge to peek.
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const ClearReaderApp());
}

class ClearReaderApp extends StatelessWidget {
  const ClearReaderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Settings.instance,
      builder: (context, _) {
        final dark = Settings.instance.theme == ReaderTheme.dark;
        return MaterialApp(
          title: 'Clear Reader',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: dark ? Brightness.dark : Brightness.light,
            colorSchemeSeed: const Color(0xFFB07D00),
            useMaterial3: true,
          ),
          home: const _Home(),
        );
      },
    );
  }
}

/// Opens the last book straight away; otherwise shows the library.
class _Home extends StatefulWidget {
  const _Home();

  @override
  State<_Home> createState() => _HomeState();
}

class _HomeState extends State<_Home> {
  String? _bookPath;
  bool _showLibrary = false;

  @override
  void initState() {
    super.initState();
    final last = Settings.instance.lastBookPath;
    if (last != null && File(last).existsSync()) {
      _bookPath = last;
    } else {
      _showLibrary = true;
    }
  }

  @override
  Widget build(BuildContext context) {
    final book = _bookPath;
    return PopScope(
      canPop: !_showLibrary || book == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _showLibrary && book != null) setState(() => _showLibrary = false);
      },
      child: (_showLibrary || book == null)
          ? LibraryScreen(
              canResume: book != null,
              onResume: () => setState(() => _showLibrary = false),
              onOpen: (path) => setState(() {
                _bookPath = path;
                _showLibrary = false;
              }),
            )
          : ReaderScreen(key: ValueKey(book), path: book, onOpenLibrary: () => setState(() => _showLibrary = true)),
    );
  }
}
