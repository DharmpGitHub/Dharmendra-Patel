import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// One PDF found on the device.
class BookEntry {
  BookEntry({
    required this.path,
    required this.name,
    required this.size,
    required this.modified,
    this.fingerprint,
    this.lastOpened,
    this.page,
    this.pageCount,
  });

  final String path;
  final String name;
  final int size;
  final int modified;
  final String? fingerprint;
  final int? lastOpened;
  final int? page;
  final int? pageCount;

  String get folder => p.basename(p.dirname(path));

  static BookEntry fromRow(Map<String, Object?> r) => BookEntry(
    path: r['path'] as String,
    name: r['name'] as String,
    size: r['size'] as int,
    modified: r['modified'] as int,
    fingerprint: r['fp'] as String?,
    lastOpened: r['last_opened'] as int?,
    page: r['page'] as int?,
    pageCount: r['page_count'] as int?,
  );
}

/// Where the reader was. Stored for every book, keyed by content fingerprint
/// so a moved or renamed file keeps its place.
class ReadingPosition {
  ReadingPosition({
    required this.page,
    required this.charIndex,
    required this.mode,
    this.itemOffset = 0,
    this.pageYFrac = 0,
    this.zoom,
  });

  /// 1-based page number.
  final int page;

  /// Character index inside the page text (shared by both view modes).
  final int charIndex;

  /// 'large' (reflowed text) or 'original'.
  final String mode;

  /// Large-text mode: leading edge of the top paragraph in viewport fractions
  /// (negative when the paragraph is partly scrolled off the top).
  final double itemOffset;

  /// Original mode: top of the viewport as a fraction of the page height.
  final double pageYFrac;

  /// Original mode zoom (null = fit width).
  final double? zoom;
}

class Highlight {
  Highlight({
    this.id,
    required this.page,
    required this.start,
    required this.end,
    required this.text,
    required this.created,
  });

  final int? id;
  final int page;

  /// Start/end (exclusive) character indices in the page text.
  final int start;
  final int end;
  final String text;
  final int created;

  static Highlight fromRow(Map<String, Object?> r) => Highlight(
    id: r['id'] as int,
    page: r['page'] as int,
    start: r['start_idx'] as int,
    end: r['end_idx'] as int,
    text: r['text'] as String,
    created: r['created'] as int,
  );
}

class AppDb {
  AppDb._(this.db);
  final Database db;

  static AppDb? _instance;
  static AppDb get instance => _instance!;

  static Future<AppDb> open() async {
    if (_instance != null) return _instance!;
    final dir = await getDatabasesPath();
    final db = await openDatabase(
      p.join(dir, 'clear_reader.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE books(
          path TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL,
          modified INTEGER NOT NULL, fp TEXT)''');
        await db.execute('CREATE INDEX books_fp ON books(fp)');
        await db.execute('''CREATE TABLE positions(
          fp TEXT PRIMARY KEY, page INTEGER NOT NULL, char_idx INTEGER NOT NULL,
          mode TEXT NOT NULL, item_offset REAL NOT NULL, page_y REAL NOT NULL,
          zoom REAL, page_count INTEGER, last_opened INTEGER NOT NULL)''');
        await db.execute('''CREATE TABLE highlights(
          id INTEGER PRIMARY KEY AUTOINCREMENT, fp TEXT NOT NULL, page INTEGER NOT NULL,
          start_idx INTEGER NOT NULL, end_idx INTEGER NOT NULL, text TEXT NOT NULL,
          created INTEGER NOT NULL)''');
        await db.execute('CREATE INDEX hl_fp ON highlights(fp, page, start_idx)');
        await db.execute('''CREATE TABLE page_cache(
          fp TEXT NOT NULL, page INTEGER NOT NULL, version INTEGER NOT NULL,
          data TEXT NOT NULL, PRIMARY KEY(fp, page))''');
      },
    );
    return _instance = AppDb._(db);
  }

  // ---------------------------------------------------------------- library

  Future<List<BookEntry>> books() async {
    final rows = await db.rawQuery('''
      SELECT b.*, p.last_opened, p.page, p.page_count FROM books b
      LEFT JOIN positions p ON p.fp = b.fp
      ORDER BY (p.last_opened IS NULL), p.last_opened DESC, b.name COLLATE NOCASE''');
    return rows.map(BookEntry.fromRow).toList();
  }

  /// Replace the library with a fresh scan result, keeping known fingerprints.
  Future<void> replaceLibrary(List<Map<String, Object>> files) async {
    final old = {for (final r in await db.query('books')) r['path'] as String: r};
    await db.transaction((txn) async {
      await txn.delete('books');
      final batch = txn.batch();
      for (final f in files) {
        final prev = old[f['path']];
        final same = prev != null && prev['size'] == f['size'] && prev['modified'] == f['modified'];
        batch.insert('books', {...f, 'fp': same ? prev['fp'] : null});
      }
      await batch.commit(noResult: true);
    });
  }

  Future<void> upsertBook(String path, String fp) async {
    final f = File(path);
    final stat = f.statSync();
    await db.insert('books', {
      'path': path,
      'name': p.basenameWithoutExtension(path),
      'size': stat.size,
      'modified': stat.modified.millisecondsSinceEpoch,
      'fp': fp,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  // --------------------------------------------------------------- position

  Future<ReadingPosition?> position(String fp) async {
    final r = await db.query('positions', where: 'fp = ?', whereArgs: [fp]);
    if (r.isEmpty) return null;
    final row = r.first;
    return ReadingPosition(
      page: row['page'] as int,
      charIndex: row['char_idx'] as int,
      mode: row['mode'] as String,
      itemOffset: (row['item_offset'] as num).toDouble(),
      pageYFrac: (row['page_y'] as num).toDouble(),
      zoom: (row['zoom'] as num?)?.toDouble(),
    );
  }

  Future<void> savePosition(String fp, ReadingPosition pos, int pageCount) => db.insert('positions', {
    'fp': fp,
    'page': pos.page,
    'char_idx': pos.charIndex,
    'mode': pos.mode,
    'item_offset': pos.itemOffset,
    'page_y': pos.pageYFrac,
    'zoom': pos.zoom,
    'page_count': pageCount,
    'last_opened': DateTime.now().millisecondsSinceEpoch,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  // ------------------------------------------------------------- highlights

  Future<List<Highlight>> highlights(String fp) async {
    final rows = await db.query('highlights', where: 'fp = ?', whereArgs: [fp], orderBy: 'page, start_idx, end_idx');
    return rows.map(Highlight.fromRow).toList();
  }

  Future<void> addHighlight(String fp, Highlight h) => db.insert('highlights', {
    'fp': fp,
    'page': h.page,
    'start_idx': h.start,
    'end_idx': h.end,
    'text': h.text,
    'created': h.created,
  });

  Future<void> deleteHighlight(int id) => db.delete('highlights', where: 'id = ?', whereArgs: [id]);

  // ------------------------------------------------------------- text cache

  Future<Map<int, String>> cachedPages(String fp, int version) async {
    final rows = await db.query(
      'page_cache',
      columns: ['page', 'data'],
      where: 'fp = ? AND version = ?',
      whereArgs: [fp, version],
    );
    return {for (final r in rows) r['page'] as int: r['data'] as String};
  }

  Future<void> cachePages(String fp, int version, Map<int, String> pages) async {
    final batch = db.batch();
    pages.forEach((page, data) {
      batch.insert('page_cache', {
        'fp': fp,
        'page': page,
        'version': version,
        'data': data,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
    await batch.commit(noResult: true);
  }
}

/// Fast content fingerprint: size + first and last 64 KB. Survives renames
/// and moves, changes when the content changes.
Future<String> fingerprintFile(String path) async {
  final f = File(path);
  final len = await f.length();
  final raf = await f.open();
  try {
    const chunk = 64 * 1024;
    final head = await raf.read(chunk);
    var tail = <int>[];
    if (len > chunk * 2) {
      await raf.setPosition(len - chunk);
      tail = await raf.read(chunk);
    }
    final digest = sha1.convert([...utf8.encode('$len:'), ...head, ...tail]);
    return digest.toString();
  } finally {
    await raf.close();
  }
}
