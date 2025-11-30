import 'dart:async';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class PlaybackHistoryEntry {
  PlaybackHistoryEntry({
    required this.id,
    required this.libraryItemId,
    required this.bookTitle,
    required this.positionMs,
    required this.createdAtMs,
    required this.chapterTitle,
    required this.chapterIndex,
  });

  final int id;
  final String libraryItemId;
  final String? bookTitle;
  final int positionMs;
  final int createdAtMs;
  final String? chapterTitle;
  final int? chapterIndex;

  Duration get position => Duration(milliseconds: positionMs);
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
}

class BookmarkEntry {
  BookmarkEntry({
    required this.id,
    required this.libraryItemId,
    required this.bookTitle,
    required this.positionMs,
    required this.createdAtMs,
    required this.chapterTitle,
    required this.chapterIndex,
    required this.note,
  });

  final int id;
  final String libraryItemId;
  final String? bookTitle;
  final int positionMs;
  final int createdAtMs;
  final String? chapterTitle;
  final int? chapterIndex;
  final String? note;

  Duration get position => Duration(milliseconds: positionMs);
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
}

class PlaybackJournalService {
  PlaybackJournalService._();
  static final PlaybackJournalService instance = PlaybackJournalService._();

  Database? _db;
  static const _dbName = 'kitzi_playback_journal.db';
  static const _historyTable = 'playback_history';
  static const _bookmarkTable = 'playback_bookmarks';
  static const _historyPerItem = 15;
  static const _bookmarksPerItem = 50;

  Future<Database> _ensureDb() async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_historyTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            libraryItemId TEXT NOT NULL,
            bookTitle TEXT,
            positionMs INTEGER NOT NULL,
            chapterTitle TEXT,
            chapterIndex INTEGER,
            createdAt INTEGER NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE $_bookmarkTable (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            libraryItemId TEXT NOT NULL,
            bookTitle TEXT,
            positionMs INTEGER NOT NULL,
            chapterTitle TEXT,
            chapterIndex INTEGER,
            note TEXT,
            createdAt INTEGER NOT NULL
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_history_item ON $_historyTable(libraryItemId, createdAt DESC)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_bookmark_item ON $_bookmarkTable(libraryItemId, createdAt DESC)');
      },
    );
    return _db!;
  }

  Future<void> recordHistoryEntry({
    required String libraryItemId,
    required String? bookTitle,
    required int positionMs,
    String? chapterTitle,
    int? chapterIndex,
  }) async {
    final db = await _ensureDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert(_historyTable, {
      'libraryItemId': libraryItemId,
      'bookTitle': bookTitle,
      'positionMs': positionMs,
      'chapterTitle': chapterTitle,
      'chapterIndex': chapterIndex,
      'createdAt': now,
    });
    await _trimHistoryFor(libraryItemId, db);
  }

  Future<List<PlaybackHistoryEntry>> historyFor(String libraryItemId, {int limit = 50}) async {
    final db = await _ensureDb();
    final rows = await db.query(
      _historyTable,
      where: 'libraryItemId = ?',
      whereArgs: [libraryItemId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows
        .map((row) => PlaybackHistoryEntry(
              id: row['id'] as int,
              libraryItemId: row['libraryItemId'] as String,
              bookTitle: row['bookTitle'] as String?,
              positionMs: row['positionMs'] as int,
              createdAtMs: row['createdAt'] as int,
              chapterTitle: row['chapterTitle'] as String?,
              chapterIndex: row['chapterIndex'] as int?,
            ))
        .toList(growable: false);
  }

  Future<int> addBookmark({
    required String libraryItemId,
    required String? bookTitle,
    required int positionMs,
    String? chapterTitle,
    int? chapterIndex,
    String? note,
  }) async {
    final db = await _ensureDb();
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await db.insert(_bookmarkTable, {
      'libraryItemId': libraryItemId,
      'bookTitle': bookTitle,
      'positionMs': positionMs,
      'chapterTitle': chapterTitle,
      'chapterIndex': chapterIndex,
      'note': note,
      'createdAt': now,
    });
    await _trimBookmarksFor(libraryItemId, db);
    return id;
  }

  Future<void> deleteBookmark(int id) async {
    final db = await _ensureDb();
    await db.delete(_bookmarkTable, where: 'id = ?', whereArgs: [id]);
  }

  Future<List<BookmarkEntry>> bookmarksFor(String libraryItemId) async {
    final db = await _ensureDb();
    final rows = await db.query(
      _bookmarkTable,
      where: 'libraryItemId = ?',
      whereArgs: [libraryItemId],
      orderBy: 'createdAt DESC',
    );
    return rows
        .map((row) => BookmarkEntry(
              id: row['id'] as int,
              libraryItemId: row['libraryItemId'] as String,
              bookTitle: row['bookTitle'] as String?,
              positionMs: row['positionMs'] as int,
              createdAtMs: row['createdAt'] as int,
              chapterTitle: row['chapterTitle'] as String?,
              chapterIndex: row['chapterIndex'] as int?,
              note: row['note'] as String?,
            ))
        .toList(growable: false);
  }

  Future<void> _trimHistoryFor(String libraryItemId, Database db) async {
    await db.rawDelete('''
      DELETE FROM $_historyTable
      WHERE libraryItemId = ?
        AND id NOT IN (
          SELECT id FROM $_historyTable
          WHERE libraryItemId = ?
          ORDER BY createdAt DESC
          LIMIT ?
        )
    ''', [libraryItemId, libraryItemId, _historyPerItem]);
  }

  Future<void> _trimBookmarksFor(String libraryItemId, Database db) async {
    await db.rawDelete('''
      DELETE FROM $_bookmarkTable
      WHERE libraryItemId = ?
        AND id NOT IN (
          SELECT id FROM $_bookmarkTable
          WHERE libraryItemId = ?
          ORDER BY createdAt DESC
          LIMIT ?
        )
    ''', [libraryItemId, libraryItemId, _bookmarksPerItem]);
  }
}

