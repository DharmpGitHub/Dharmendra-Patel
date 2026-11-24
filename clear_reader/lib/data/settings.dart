import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderTheme { light, sepia, dark }

class ReaderColors {
  const ReaderColors(this.background, this.text, this.muted, this.highlight, this.bar);
  final Color background;
  final Color text;
  final Color muted;
  final Color highlight;
  final Color bar;

  static ReaderColors of(ReaderTheme t) => switch (t) {
    ReaderTheme.light => const ReaderColors(
      Color(0xFFFFFFFF),
      Color(0xFF1F1F1F),
      Color(0xFF8A8A8A),
      Color(0x66FFD54F),
      Color(0xFFF4F4F4),
    ),
    ReaderTheme.sepia => const ReaderColors(
      Color(0xFFF6EEDC),
      Color(0xFF3B2F22),
      Color(0xFF8C7B66),
      Color(0x80F2C14E),
      Color(0xFFEDE2CA),
    ),
    ReaderTheme.dark => const ReaderColors(
      Color(0xFF121212),
      Color(0xFFE2E2E2),
      Color(0xFF8E8E8E),
      Color(0x66B38F00),
      Color(0xFF1E1E1E),
    ),
  };
}

/// Reader appearance, remembered between launches.
class Settings extends ChangeNotifier {
  Settings._(this._prefs);
  final SharedPreferences _prefs;

  static late Settings instance;

  static Future<Settings> load() async {
    instance = Settings._(await SharedPreferences.getInstance());
    return instance;
  }

  double get fontSize => _prefs.getDouble('fontSize') ?? 22;
  set fontSize(double v) => _set(() => _prefs.setDouble('fontSize', v));

  double get lineHeight => _prefs.getDouble('lineHeight') ?? 1.55;
  set lineHeight(double v) => _set(() => _prefs.setDouble('lineHeight', v));

  bool get serif => _prefs.getBool('serif') ?? true;
  set serif(bool v) => _set(() => _prefs.setBool('serif', v));

  ReaderTheme get theme => ReaderTheme.values[_prefs.getInt('theme') ?? 0];
  set theme(ReaderTheme v) => _set(() => _prefs.setInt('theme', v.index));

  ReaderColors get colors => ReaderColors.of(theme);

  /// Tints original PDF pages to match the reading theme.
  ColorFilter? get pageFilter => switch (theme) {
    ReaderTheme.light => null,
    ReaderTheme.sepia => const ColorFilter.mode(Color(0xFFF6EEDC), BlendMode.multiply),
    ReaderTheme.dark => const ColorFilter.matrix([
      -0.87, 0, 0, 0, 230, 0, -0.87, 0, 0, 230, 0, 0, -0.87, 0, 230, 0, 0, 0, 1, 0, //
    ]),
  };

  String? get lastBookPath => _prefs.getString('lastBook');
  set lastBookPath(String? v) {
    if (v == null) {
      _prefs.remove('lastBook');
    } else {
      _prefs.setString('lastBook', v);
    }
  }

  void _set(void Function() write) {
    write();
    notifyListeners();
  }
}
