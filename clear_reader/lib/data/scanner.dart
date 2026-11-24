import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;

/// Finds every PDF on the device's storage volumes. Runs in a background
/// isolate so the UI never freezes.
Future<List<Map<String, Object>>> scanDeviceForPdfs() => Isolate.run(_scan);

List<Map<String, Object>> _scan() {
  if (!Platform.isAndroid) {
    // Desktop: the user's home folder (Documents, Downloads, Desktop...).
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'] ?? '.';
    final found = <String, Map<String, Object>>{};
    _walk(Directory(home), found, 1);
    return found.values.toList();
  }
  final roots = <String>{'/storage/emulated/0'};
  // SD cards and USB drives appear as /storage/XXXX-XXXX.
  try {
    for (final e in Directory('/storage').listSync(followLinks: false)) {
      final name = p.basename(e.path);
      if (name != 'emulated' && name != 'self' && e is Directory) roots.add(e.path);
    }
  } catch (_) {}

  final found = <String, Map<String, Object>>{};
  for (final root in roots) {
    _walk(Directory(root), found, 0);
  }
  return found.values.toList();
}

const _skipDirs = {'Android', 'LOST.DIR', '.thumbnails', '.trash', '.Trash'};

void _walk(Directory dir, Map<String, Map<String, Object>> out, int depth) {
  if (depth > 24) return;
  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    return;
  }
  for (final e in entries) {
    final name = p.basename(e.path);
    if (name.startsWith('.')) continue;
    if (e is Directory) {
      if (depth == 0 && _skipDirs.contains(name)) continue;
      _walk(e, out, depth + 1);
    } else if (e is File && name.toLowerCase().endsWith('.pdf')) {
      try {
        final st = e.statSync();
        if (st.size < 100) continue;
        out[e.path] = {
          'path': e.path,
          'name': p.basenameWithoutExtension(name),
          'size': st.size,
          'modified': st.modified.millisecondsSinceEpoch,
        };
      } catch (_) {}
    }
  }
}
