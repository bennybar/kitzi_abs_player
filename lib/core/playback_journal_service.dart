import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import 'api_client.dart';
import 'auth_repository.dart';

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

class _BookmarkCacheEntry {
  _BookmarkCacheEntry(this.entries, this.fetchedAt);

  final List<BookmarkEntry> entries;
  final DateTime fetchedAt;
}

class BookmarkEntry {
  BookmarkEntry({
    this.localId,
    this.remoteTimeSeconds,
    this.remoteTimeKey,
    required this.libraryItemId,
    this.bookTitle,
    required this.positionMs,
    required this.createdAtMs,
    this.chapterTitle,
    this.chapterIndex,
    this.note,
  });

  final int? localId;
  final double? remoteTimeSeconds;
  final String? remoteTimeKey;
  final String libraryItemId;
  final String? bookTitle;
  final int positionMs;
  final int createdAtMs;
  final String? chapterTitle;
  final int? chapterIndex;
  final String? note;

  double get timeSecondsForServer =>
      remoteTimeSeconds ?? (positionMs / 1000.0);

  Duration get position => Duration(milliseconds: positionMs);
  DateTime get createdAt => DateTime.fromMillisecondsSinceEpoch(createdAtMs);
}

class PlaybackJournalService {
  PlaybackJournalService._();
  static final PlaybackJournalService instance = PlaybackJournalService._();

  Database? _db;
  final Map<String, _BookmarkCacheEntry> _bookmarkCache = {};
  static const _dbName = 'kitzi_playback_journal.db';
  static const _dbVersion = 3;
  static const _historyTable = 'playback_history';
  static const _bookmarkTable = 'playback_bookmarks';
  static const _historyPerItem = 15;
  static const _bookmarksPerItem = 50;
  static const _bookmarkCacheTtl = Duration(seconds: 20);

  Future<Database> _ensureDb() async {
    if (_db != null) return _db!;
    final path = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: _dbVersion,
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
            createdAt INTEGER NOT NULL,
            remoteTime REAL,
            remoteTimeKey TEXT
          )
        ''');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_history_item ON $_historyTable(libraryItemId, createdAt DESC)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_bookmark_item ON $_bookmarkTable(libraryItemId, createdAt DESC)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('ALTER TABLE $_bookmarkTable ADD COLUMN remoteTime REAL');
        }
        if (oldVersion < 3) {
          await db.execute('ALTER TABLE $_bookmarkTable ADD COLUMN remoteTimeKey TEXT');
        }
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

  Future<BookmarkEntry> addBookmark({
    required String libraryItemId,
    required String? bookTitle,
    required int positionMs,
    String? chapterTitle,
    int? chapterIndex,
    String? note,
  }) async {
    final entry = await _createRemoteBookmark(
      libraryItemId: libraryItemId,
      bookTitle: bookTitle,
      positionMs: positionMs,
      chapterTitle: chapterTitle,
      chapterIndex: chapterIndex,
      note: note,
    );
    final stored = await _insertLocalBookmark(entry);
    _invalidateBookmarkCache(libraryItemId);
    return stored;
  }

  Future<void> deleteBookmark({
    required String libraryItemId,
    required double? remoteTimeSeconds,
    String? remoteTimeKey,
    int? localId,
    int? fallbackPositionMs,
  }) async {
    final resolvedTime =
        remoteTimeSeconds ?? (fallbackPositionMs != null ? fallbackPositionMs / 1000.0 : null);
    if (resolvedTime == null && remoteTimeKey == null) {
      throw StateError('Cannot delete bookmark without a known timestamp.');
    }

    final timeSegment = remoteTimeKey ?? _formatBookmarkTime(resolvedTime!);
    try {
      final api = await _getApiClient();
      final resp = await api.request(
        'DELETE',
        '/api/me/item/$libraryItemId/bookmark/$timeSegment',
      );
      if (resp.statusCode != 200) {
        throw Exception('Server responded with HTTP ${resp.statusCode}');
      }
    } finally {
      await _deleteLocalBookmark(
        libraryItemId: libraryItemId,
        localId: localId,
        remoteTimeSeconds: resolvedTime,
        remoteTimeKey: remoteTimeKey,
      );
      _invalidateBookmarkCache(libraryItemId);
    }
  }

  Future<List<BookmarkEntry>> bookmarksFor(String libraryItemId, {bool forceRemote = false}) async {
    final cacheEntry = _bookmarkCache[libraryItemId];
    if (!forceRemote &&
        cacheEntry != null &&
        DateTime.now().difference(cacheEntry.fetchedAt) < _bookmarkCacheTtl) {
      return cacheEntry.entries;
    }

    final remoteEntries = await _fetchRemoteBookmarksForItem(libraryItemId);
    if (remoteEntries != null) {
      _bookmarkCache[libraryItemId] = _BookmarkCacheEntry(remoteEntries, DateTime.now());
      return remoteEntries;
    }

    final local = await _readLocalBookmarks(libraryItemId);
    _bookmarkCache[libraryItemId] = _BookmarkCacheEntry(local, DateTime.now());
    return local;
  }

  Future<ApiClient> _getApiClient() async {
    final auth = await AuthRepository.ensure();
    return auth.api;
  }

  void _invalidateBookmarkCache([String? libraryItemId]) {
    if (libraryItemId == null) {
      _bookmarkCache.clear();
      return;
    }
    _bookmarkCache.remove(libraryItemId);
  }

  Future<BookmarkEntry> _createRemoteBookmark({
    required String libraryItemId,
    String? bookTitle,
    required int positionMs,
    String? chapterTitle,
    int? chapterIndex,
    String? note,
  }) async {
    final safeTitle = (chapterTitle?.trim().isNotEmpty == true)
        ? chapterTitle!.trim()
        : 'Bookmark';
    final roundedSeconds = double.parse((positionMs / 1000.0).toStringAsFixed(3));
    final payload = jsonEncode({
      'time': roundedSeconds,
      'title': safeTitle,
    });

    final api = await _getApiClient();
    final resp = await api.request(
      'POST',
      '/api/me/item/$libraryItemId/bookmark',
      headers: {'Content-Type': 'application/json'},
      body: payload,
    );
    if (resp.statusCode != 200) {
      throw Exception('Server responded with HTTP ${resp.statusCode}');
    }
    final json = jsonDecode(resp.body) as Map<String, dynamic>;
    return _bookmarkFromRemoteJson(
      json,
      fallbackLibraryItemId: libraryItemId,
      fallbackBookTitle: bookTitle,
      fallbackChapterTitle: safeTitle,
      fallbackPositionMs: positionMs,
      fallbackChapterIndex: chapterIndex,
      note: note,
    );
  }

  Future<BookmarkEntry> _insertLocalBookmark(BookmarkEntry entry) async {
    final db = await _ensureDb();
    final id = await db.insert(_bookmarkTable, _bookmarkToRow(entry));
    await _trimBookmarksFor(entry.libraryItemId, db);
    return BookmarkEntry(
      localId: id,
      remoteTimeSeconds: entry.remoteTimeSeconds,
      remoteTimeKey: entry.remoteTimeKey,
      libraryItemId: entry.libraryItemId,
      bookTitle: entry.bookTitle,
      positionMs: entry.positionMs,
      createdAtMs: entry.createdAtMs,
      chapterTitle: entry.chapterTitle,
      chapterIndex: entry.chapterIndex,
      note: entry.note,
    );
  }

  Future<void> _deleteLocalBookmark({
    required String libraryItemId,
    int? localId,
    double? remoteTimeSeconds,
    String? remoteTimeKey,
  }) async {
    final db = await _ensureDb();
    if (localId != null) {
      await db.delete(_bookmarkTable, where: 'id = ?', whereArgs: [localId]);
      return;
    }
    if (remoteTimeKey != null) {
      final deleted = await db.delete(
        _bookmarkTable,
        where: 'libraryItemId = ? AND remoteTimeKey = ?',
        whereArgs: [libraryItemId, remoteTimeKey],
      );
      if (deleted > 0) return;
    }
    if (remoteTimeSeconds != null) {
      final posMs = (remoteTimeSeconds * 1000).round();
      await db.delete(
        _bookmarkTable,
        where: 'libraryItemId = ? AND positionMs = ?',
        whereArgs: [libraryItemId, posMs],
      );
      return;
    }
    await db.delete(_bookmarkTable, where: 'libraryItemId = ?', whereArgs: [libraryItemId]);
  }

  Future<List<BookmarkEntry>?> _fetchRemoteBookmarksForItem(String libraryItemId) async {
    try {
      final api = await _getApiClient();
      final resp = await api.request('GET', '/api/me/item/$libraryItemId/bookmark');
      if (resp.statusCode != 200) {
        return null;
      }
      final decoded = jsonDecode(resp.body);
      List<dynamic> rawList;
      if (decoded is List) {
        rawList = decoded;
      } else if (decoded is Map<String, dynamic>) {
        if (decoded['bookmarks'] is List) {
          rawList = decoded['bookmarks'] as List<dynamic>;
        } else if (decoded['data'] is List) {
          rawList = decoded['data'] as List<dynamic>;
        } else {
          rawList = const [];
        }
      } else {
        rawList = const [];
      }

      final entries = <BookmarkEntry>[];
      for (final raw in rawList) {
        if (raw is! Map<String, dynamic>) continue;
        try {
          entries.add(_bookmarkFromRemoteJson(
            raw,
            fallbackLibraryItemId: libraryItemId,
          ));
        } catch (_) {
          // Ignore malformed bookmark
        }
      }

      entries.sort((a, b) => b.createdAtMs.compareTo(a.createdAtMs));
      if (entries.length > _bookmarksPerItem) {
        entries.removeRange(_bookmarksPerItem, entries.length);
      }
      await _replaceLocalBookmarks(libraryItemId, entries);
      return entries;
    } catch (_) {
      return null;
    }
  }

  Future<void> _replaceLocalBookmarks(String libraryItemId, List<BookmarkEntry> entries) async {
    final db = await _ensureDb();
    final batch = db.batch();
    batch.delete(_bookmarkTable, where: 'libraryItemId = ?', whereArgs: [libraryItemId]);
    for (final entry in entries) {
      batch.insert(_bookmarkTable, _bookmarkToRow(entry));
    }
    await batch.commit(noResult: true);
  }

  Future<List<BookmarkEntry>> _readLocalBookmarks(String libraryItemId) async {
    final db = await _ensureDb();
    final rows = await db.query(
      _bookmarkTable,
      where: 'libraryItemId = ?',
      whereArgs: [libraryItemId],
      orderBy: 'createdAt DESC',
      limit: _bookmarksPerItem,
    );
    return rows
        .map((row) => BookmarkEntry(
              localId: row['id'] as int,
              remoteTimeSeconds: (row['remoteTime'] as num?)?.toDouble(),
              remoteTimeKey: row['remoteTimeKey'] as String?,
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

  Map<String, Object?> _bookmarkToRow(BookmarkEntry entry) {
    return {
      'libraryItemId': entry.libraryItemId,
      'bookTitle': entry.bookTitle,
      'positionMs': entry.positionMs,
      'chapterTitle': entry.chapterTitle,
      'chapterIndex': entry.chapterIndex,
      'note': entry.note,
      'createdAt': entry.createdAtMs,
      'remoteTime': entry.remoteTimeSeconds,
      'remoteTimeKey': entry.remoteTimeKey,
    };
  }

  BookmarkEntry _bookmarkFromRemoteJson(
    Map<String, dynamic> raw, {
    String? fallbackLibraryItemId,
    String? fallbackBookTitle,
    String? fallbackChapterTitle,
    int? fallbackPositionMs,
    int? fallbackChapterIndex,
    String? note,
  }) {
    String? resolvedLibraryItemId = raw['libraryItemId'] as String?;
    String? resolvedBookTitle = fallbackBookTitle;

    final libraryItem = raw['libraryItem'];
    if (libraryItem is Map<String, dynamic>) {
      resolvedLibraryItemId ??= libraryItem['id'] as String?;
      resolvedBookTitle ??= libraryItem['title'] as String?;
      final media = libraryItem['media'];
      if (media is Map<String, dynamic>) {
        final metadata = media['metadata'];
        if (metadata is Map<String, dynamic>) {
          resolvedBookTitle ??= metadata['title'] as String?;
        }
      }
    }

    final libraryItemId = resolvedLibraryItemId ?? fallbackLibraryItemId;
    if (libraryItemId == null) {
      throw StateError('Bookmark missing libraryItemId');
    }
    final rawTime = raw['time'];
    double? timeSeconds;
    String? remoteTimeKey;
    if (rawTime is num) {
      timeSeconds = rawTime.toDouble();
      remoteTimeKey = _formatBookmarkTimeRaw(timeSeconds);
    } else if (rawTime is String) {
      remoteTimeKey = rawTime;
      timeSeconds = double.tryParse(rawTime);
    }
    timeSeconds ??= (fallbackPositionMs ?? 0) / 1000.0;
    remoteTimeKey ??= _formatBookmarkTimeRaw(timeSeconds);
    final positionMs = (timeSeconds * 1000).round();
    final createdAtRaw = raw['createdAt'];
    int createdAtMs;
    if (createdAtRaw is num) {
      createdAtMs = createdAtRaw.toInt();
    } else if (createdAtRaw is String) {
      createdAtMs = DateTime.tryParse(createdAtRaw)?.millisecondsSinceEpoch ??
          DateTime.now().millisecondsSinceEpoch;
    } else {
      createdAtMs = DateTime.now().millisecondsSinceEpoch;
    }
    final title = raw['title'] as String?;
    final noteValue = (raw['note'] as String?) ?? note;
    final chapterIndexValue = raw['chapterIndex'];

    return BookmarkEntry(
      localId: null,
      remoteTimeSeconds: timeSeconds,
      remoteTimeKey: remoteTimeKey,
      libraryItemId: libraryItemId,
      bookTitle: resolvedBookTitle,
      positionMs: positionMs,
      createdAtMs: createdAtMs,
      chapterTitle: title ?? fallbackChapterTitle,
      chapterIndex: chapterIndexValue is num ? chapterIndexValue.toInt() : fallbackChapterIndex,
      note: noteValue,
    );
  }

  String _formatBookmarkTime(double seconds) => _formatBookmarkTimeRaw(seconds);

  String _formatBookmarkTimeRaw(double seconds) {
    if (seconds == seconds.roundToDouble()) {
      return seconds.toInt().toString();
    }
    var value = seconds.toString();
    if (value.contains('e') || value.contains('E')) {
      value = seconds.toStringAsFixed(9);
    }
    value = value.replaceFirst(RegExp(r'0+$'), '');
    if (value.endsWith('.')) {
      value = value.substring(0, value.length - 1);
    }
    return value;
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

  /// Clear all playback history and bookmarks (used on logout)
  static Future<void> clearAll() async {
    try {
      final instance = PlaybackJournalService.instance;
      instance._bookmarkCache.clear();
      if (instance._db != null) {
        final db = instance._db!;
        await db.delete(_historyTable);
        await db.delete(_bookmarkTable);
        await db.close();
        instance._db = null;
      }
      // Also delete the database file
      try {
        final dbPath = await getDatabasesPath();
        final path = p.join(dbPath, _dbName);
        final file = File(path);
        if (await file.exists()) {
          await file.delete();
        }
      } catch (_) {}
    } catch (_) {}
  }
}

