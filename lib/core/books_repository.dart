import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:convert' show utf8;
import 'package:crypto/crypto.dart';
import '../models/book.dart';
import 'auth_repository.dart';
import 'network_service.dart';
import 'offline_first_repository.dart';

class BooksRepository {
  BooksRepository(this._auth, this._prefs);
  final AuthRepository _auth;
  final SharedPreferences _prefs;
  
  // Enable/disable verbose logging
  static const bool _verboseLogging = false;
  Database? _db;
  String? _dbLibId; // track which library the DB connection belongs to
  
  // Query caching for better performance
  final Map<String, List<Book>> _queryCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static const Duration _cacheTTL = Duration(minutes: 5);
  
  /// Log debug message only if verbose logging is enabled
  void _log(String message) {
    if (_verboseLogging) {
      debugPrint(message);
    }
  }
  
  /// Clear expired cache entries
  void _cleanExpiredCache() {
    final now = DateTime.now();
    _cacheTimestamps.removeWhere((key, timestamp) {
      if (now.difference(timestamp) > _cacheTTL) {
        _queryCache.remove(key);
        return true;
      }
      return false;
    });
  }
  
  /// Clear all cache entries (for memory pressure)
  void _clearAllCache() {
    _queryCache.clear();
    _cacheTimestamps.clear();
    debugPrint('[BOOKS_CACHE] All cache cleared due to memory pressure');
  }

  static const _etagKey = 'books_list_etag';
  static const _cacheKey = 'books_list_cache_json';
  static const _libIdKey = 'books_library_id';
  static const _cacheMetadataKey = 'books_cache_metadata';

  Future<String> _ensureLibraryId() async {
    final cached = _prefs.getString(_libIdKey);
    if (cached != null && cached.isNotEmpty) {
      return cached;
    }

    final api = _auth.api;
    final token = await api.accessToken();
    final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
    final resp = await api.request('GET', '/api/libraries$tokenQS');
    if (resp.statusCode != 200) {
      throw Exception('Failed to list libraries: ${resp.statusCode}');
    }

    final bodyStr = resp.body;
    final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;

    final libs = (body is Map && body['libraries'] is List)
        ? (body['libraries'] as List)
        : (body is List ? body : const []);

    if (libs.isEmpty) {
      throw Exception('No libraries accessible for this user');
    }

    Map<String, dynamic>? chosen;
    for (final l in libs) {
      final m = (l as Map).cast<String, dynamic>();
      final mt = (m['mediaType'] ?? m['type'] ?? '').toString().toLowerCase();
      if (mt.contains('book')) {
        chosen = m;
        break;
      }
    }
    chosen ??= (libs.first as Map).cast<String, dynamic>();

    final id = (chosen['id'] ?? chosen['_id'] ?? '').toString();
    if (id.isEmpty) {
      throw Exception('Invalid library id from /api/libraries');
    }

    await _prefs.setString(_libIdKey, id);
    return id;
  }

  List<Map<String, dynamic>> _extractItems(dynamic body) {
    if (body is Map) {
      // common shapes seen in the wild
      final keys = ['items', 'libraryItems', 'results', 'data'];
      for (final k in keys) {
        final v = body[k];
        if (v is List) {
          return v.cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
        }
      }
    }
    if (body is List) {
      return body.cast<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  Future<List<Book>> listBooks() async {
    try {
      final fetched = await fetchBooksPage(page: 1, limit: 50);
      return fetched;
    } catch (e) {
      // Fallback to local DB if server fails
      final local = await _listBooksFromDb();
      // Do not prefetch covers here; they will load on-demand as displayed
      return local;
    }
  }

  Future<List<Book>> _toBooks(List<Map<String, dynamic>> items) async {
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken(); // nullable OK
    return items
        .map((e) => Book.fromLibraryItemJson(e, baseUrl: baseUrl, token: token))
        .where((b) => b.title.isNotEmpty)
        .toList();
  }

  Future<Book> getBook(String id) async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final baseUrl = _auth.api.baseUrl ?? '';
      final token = await _auth.api.accessToken();
      final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';

      final resp = await api.request('GET', '/api/items/$id$tokenQS');
      if (resp.statusCode != 200) {
        throw Exception('Failed to load book $id: ${resp.statusCode}');
      }

      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final item = (body is Map && body['item'] is Map)
          ? (body['item'] as Map).cast<String, dynamic>()
          : (body as Map).cast<String, dynamic>();

      // Prefer preserving locally cached fields (e.g., sizeBytes/durationMs) when server omits them
      Book b = Book.fromLibraryItemJson(item, baseUrl: baseUrl, token: token);
      // If server explicitly flags mediaType as 'ebook' or item has no audio tracks, mark non-audiobook
      try {
        final mediaType = (item['mediaType'] ?? item['type'] ?? '').toString().toLowerCase();
        if (mediaType.contains('ebook')) {
          b = Book(
            id: b.id,
            title: b.title,
            author: b.author,
            coverUrl: b.coverUrl,
            description: b.description,
            durationMs: b.durationMs,
            sizeBytes: b.sizeBytes,
            updatedAt: b.updatedAt,
            authors: b.authors,
            narrators: b.narrators,
            publisher: b.publisher,
            publishYear: b.publishYear,
            genres: b.genres,
            mediaKind: mediaType,
            isAudioBook: false,
          );
        }
      } catch (_) {}
      try {
        final prev = await getBookFromDb(id);
        if (prev != null) {
          final merged = Book(
            id: b.id,
            title: b.title,
            author: b.author,
            coverUrl: b.coverUrl,
            description: b.description,
            durationMs: b.durationMs ?? prev.durationMs,
            sizeBytes: b.sizeBytes ?? prev.sizeBytes,
            updatedAt: b.updatedAt ?? prev.updatedAt,
            authors: b.authors ?? prev.authors,
            narrators: b.narrators ?? prev.narrators,
            publisher: b.publisher ?? prev.publisher,
            publishYear: b.publishYear ?? prev.publishYear,
            genres: b.genres ?? prev.genres,
          );
          b = merged;
        }
      } catch (_) {}

      // Persist to DB for offline access
      await _upsertBooks([b]);
      // Best-effort: cache description images in background
      unawaited(_persistDescriptionImages(b));
      return b;
    });
  }

  static Future<BooksRepository> create() async {
    final auth = await AuthRepository.ensure();
    final prefs = await SharedPreferences.getInstance();
    final repo = BooksRepository(auth, prefs);
    await repo._openDb();
    return repo;
  }

  /// Remove all locally cached book data: DB, covers, and description images.
  static Future<void> wipeLocalCache() async {
    // Best-effort: clear any persisted caches/metadata first
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_etagKey);
      await prefs.remove(_cacheKey);
      await prefs.remove(_libIdKey);
    } catch (_) {}

    // Clear DB contents even if another connection is open (current library only)
    try {
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final path = p.join(dbPath, 'kitzi_books_' + libId + '.db');
      final db = await openDatabase(path);
      await db.execute('DELETE FROM books');
      await db.close();
    } catch (_) {}

    try {
      // Delete DB file (best effort; may fail if another connection is open) for current library
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final dbFile = p.join(dbPath, 'kitzi_books_' + libId + '.db');
      await deleteDatabase(dbFile);
    } catch (_) {}

    try {
      // Delete covers directory (current library only)
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final coversDir = Directory(p.join(dbPath, 'kitzi_covers', 'lib_' + libId));
      if (await coversDir.exists()) {
        await coversDir.delete(recursive: true);
      }
    } catch (_) {}

    try {
      // Delete description images directory tree (current library only)
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final descDir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_' + libId));
      if (await descDir.exists()) {
        await descDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _openDb() async {
    final dbPath = await getDatabasesPath();
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    final path = p.join(dbPath, 'kitzi_books_' + libId + '.db');
    _db = await openDatabase(
      path,
      version: 2, // Increment version to trigger migration
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE books (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            author TEXT,
            coverUrl TEXT NOT NULL,
            coverPath TEXT,
            description TEXT,
            durationMs INTEGER,
            sizeBytes INTEGER,
            updatedAt INTEGER,
            series TEXT,
            seriesSequence REAL,
            collection TEXT,
            collectionSequence REAL,
            isAudioBook INTEGER NOT NULL DEFAULT 1,
            mediaKind TEXT,
            libraryId TEXT
          )
        ''');
        
        // Add indexes for better query performance
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_updatedAt ON books(updatedAt DESC)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_title ON books(title COLLATE NOCASE)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_author ON books(author COLLATE NOCASE)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_isAudioBook ON books(isAudioBook)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_libraryId ON books(libraryId)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_series ON books(series)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_collection ON books(collection)');
        
        // Composite indexes for common query patterns
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_search ON books(title COLLATE NOCASE, author COLLATE NOCASE, isAudioBook)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_recent ON books(updatedAt DESC, isAudioBook)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_series_collection ON books(series, collection, seriesSequence)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_audio_updated ON books(isAudioBook, updatedAt DESC)');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        // Only run migrations if upgrading from version 1
        if (oldVersion < 2) {
          await _migrateToVersion2(db);
        }
      },
    );

    _dbLibId = libId;
  }
  
  /// Migrate database from version 1 to version 2
  Future<void> _migrateToVersion2(Database db) async {
    debugPrint('[BOOKS_DB] Migrating from version 1 to 2');
    
    // Add new columns only if they don't exist
    await _addColumnIfNotExists(db, 'books', 'coverPath', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'isAudioBook', 'INTEGER');
    await _addColumnIfNotExists(db, 'books', 'mediaKind', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'libraryId', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'series', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'seriesSequence', 'REAL');
    await _addColumnIfNotExists(db, 'books', 'collection', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'collectionSequence', 'REAL');
    
    // Add new indexes
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_updatedAt ON books(updatedAt DESC)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_title ON books(title COLLATE NOCASE)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_author ON books(author COLLATE NOCASE)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_isAudioBook ON books(isAudioBook)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_libraryId ON books(libraryId)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_series ON books(series)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_collection ON books(collection)');
    
    // Add composite indexes for better performance
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_search ON books(title COLLATE NOCASE, author COLLATE NOCASE, isAudioBook)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_recent ON books(updatedAt DESC, isAudioBook)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_series_collection ON books(series, collection, seriesSequence)');
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_audio_updated ON books(isAudioBook, updatedAt DESC)');
    
    debugPrint('[BOOKS_DB] Migration to version 2 completed');
  }
  
  /// Add a column to a table only if it doesn't already exist
  Future<void> _addColumnIfNotExists(Database db, String tableName, String columnName, String columnType) async {
    try {
      // Check if column exists by querying table info
      final result = await db.rawQuery('PRAGMA table_info($tableName)');
      final columnExists = result.any((column) => column['name'] == columnName);
      
      if (!columnExists) {
        await db.execute('ALTER TABLE $tableName ADD COLUMN $columnName $columnType');
        _log('[BOOKS_DB] Added column $columnName to $tableName');
      } else {
        _log('[BOOKS_DB] Column $columnName already exists in $tableName');
      }
    } catch (e) {
      debugPrint('[BOOKS_DB] Error adding column $columnName to $tableName: $e');
    }
  }

  Future<void> _ensureDbForCurrentLib() async {
    final current = _prefs.getString(_libIdKey) ?? 'default';
    if (_db == null || _dbLibId != current) {
      try { await _db?.close(); } catch (_) {}
      await _openDb();
    }
  }

  Future<void> _upsertBooks(List<Book> items) async {
    final db = _db;
    if (db == null) return;
    
    // Use transaction for better performance and atomicity
    await db.transaction((txn) async {
      final batch = txn.batch();
      final libId = _prefs.getString(_libIdKey) ?? 'default';
      
      for (final b in items) {
        final coverFile = await _coverFileForId(b.id);
        final hasLocal = await coverFile.exists();
        
        batch.insert(
          'books',
          {
            'id': b.id,
            'title': b.title,
            'author': b.author,
            'coverUrl': b.coverUrl,
            'coverPath': hasLocal ? coverFile.path : null,
            'description': b.description,
            'durationMs': b.durationMs,
            'sizeBytes': b.sizeBytes,
            'updatedAt': b.updatedAt?.millisecondsSinceEpoch,
            'series': b.series,
            'seriesSequence': b.seriesSequence,
            'collection': b.collection,
            'collectionSequence': b.collectionSequence,
            'isAudioBook': b.isAudioBook ? 1 : 0,
            'mediaKind': b.mediaKind,
            'libraryId': b.libraryId ?? libId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    
    // Update cache metadata
    await _updateCacheMetadata(items.length);
  }
  
  /// Update cache metadata when books are saved
  Future<void> _updateCacheMetadata(int itemCount) async {
    try {
      final metadata = CacheMetadata(
        lastUpdated: DateTime.now(),
        itemCount: itemCount,
        version: '1.0',
      );
      await _prefs.setString(_cacheMetadataKey, jsonEncode(metadata.toJson()));
    } catch (e) {
      debugPrint('Failed to update cache metadata: $e');
    }
  }
  
  /// Get cache metadata
  CacheMetadata? _getCacheMetadata() {
    try {
      final jsonStr = _prefs.getString(_cacheMetadataKey);
      if (jsonStr == null) return null;
      final json = jsonDecode(jsonStr);
      return CacheMetadata.fromJson(json);
    } catch (e) {
      debugPrint('Failed to get cache metadata: $e');
      return null;
    }
  }
  
  /// Check if cache is valid based on metadata
  Future<bool> isCacheValid(Duration timeout) async {
    final metadata = _getCacheMetadata();
    if (metadata == null) return false;
    
    final now = DateTime.now();
    final isValid = now.difference(metadata.lastUpdated) < timeout;
    _log('[BOOKS_CACHE] Cache valid: $isValid (age: ${now.difference(metadata.lastUpdated).inMinutes} minutes)');
    return isValid;
  }

  Future<List<Book>> _listBooksFromDb() async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return <Book>[];
    final rows = await db.query(
      'books',
      where: '((isAudioBook = 1) OR (isAudioBook IS NULL AND durationMs IS NOT NULL AND durationMs > 0))',
      orderBy: 'updatedAt IS NULL, updatedAt DESC',
    );
    if (rows.isEmpty) return <Book>[];
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();
    return rows.map((m) {
      final id = (m['id'] as String);
      final localPath = (m['coverPath'] as String?);
      var coverUrl = '$baseUrl/api/items/$id/cover';
      if (token != null && token.isNotEmpty) coverUrl = '$coverUrl?token=$token';
      if (localPath != null && File(localPath).existsSync()) {
        coverUrl = 'file://$localPath';
      }
      final isAudioRaw = m['isAudioBook'] as int?;
      final durationRaw = m['durationMs'] as int?;
      final computedIsAudio = (isAudioRaw != null)
          ? (isAudioRaw != 0)
          : (durationRaw != null && durationRaw > 0);
      return Book(
        id: id,
        title: (m['title'] as String),
        author: m['author'] as String?,
        coverUrl: coverUrl,
        description: m['description'] as String?,
        durationMs: m['durationMs'] as int?,
        sizeBytes: m['sizeBytes'] as int?,
        updatedAt: (m['updatedAt'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch((m['updatedAt'] as int), isUtc: true)
            : null,
        series: m['series'] as String?,
        seriesSequence: (m['seriesSequence'] is num)
            ? (m['seriesSequence'] as num).toDouble()
            : (m['seriesSequence'] is String ? double.tryParse((m['seriesSequence'] as String)) : null),
        collection: m['collection'] as String?,
        collectionSequence: (m['collectionSequence'] is num)
            ? (m['collectionSequence'] as num).toDouble()
            : (m['collectionSequence'] is String ? double.tryParse((m['collectionSequence'] as String)) : null),
        mediaKind: m['mediaKind'] as String?,
        isAudioBook: computedIsAudio,
        libraryId: m['libraryId'] as String?,
      );
    }).toList();
  }

  /// Paged local query of books from the on-device DB with optional search and sort.
  Future<List<Book>> listBooksFromDbPaged({
    required int page,
    int limit = 50,
    String sort = 'updatedAt:desc',
    String? query,
  }) async {
    // Check cache first
    _cleanExpiredCache();
    final cacheKey = 'books_paged_${page}_${limit}_${sort}_${query ?? 'all'}';
    final cached = _queryCache[cacheKey];
    final timestamp = _cacheTimestamps[cacheKey];
    
    if (cached != null && timestamp != null && 
        DateTime.now().difference(timestamp) < _cacheTTL) {
      _log('[BOOKS_CACHE] Cache hit for $cacheKey: ${cached.length} items');
      return cached;
    }
    
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return <Book>[];
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();

    final offset = (page <= 1) ? 0 : (page - 1) * limit;
    final whereParts = <String>[];
    final whereArgs = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      final q = '%${query.trim().toLowerCase()}%';
      whereParts.add('(LOWER(title) LIKE ? OR LOWER(author) LIKE ?)');
      whereArgs..add(q)..add(q);
    }
    // Only audiobooks
    whereParts.add('((isAudioBook = 1) OR (isAudioBook IS NULL AND durationMs IS NOT NULL AND durationMs > 0))');
    final where = whereParts.isEmpty ? null : whereParts.join(' AND ');

    String orderBy;
    switch (sort) {
      case 'nameAsc':
        orderBy = 'title COLLATE NOCASE ASC';
        break;
      case 'updatedAt:desc':
      default:
        orderBy = 'updatedAt IS NULL, updatedAt DESC';
        break;
    }

    final rows = await db.query(
      'books',
      where: where,
      whereArgs: whereArgs,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );
    if (rows.isEmpty) {
      final emptyResult = <Book>[];
      // Cache empty results too
      _queryCache[cacheKey] = emptyResult;
      _cacheTimestamps[cacheKey] = DateTime.now();
      return emptyResult;
    }
    final books = rows.map((m) {
      final id = (m['id'] as String);
      final localPath = (m['coverPath'] as String?);
      var coverUrl = '$baseUrl/api/items/$id/cover';
      if (token != null && token.isNotEmpty) coverUrl = '$coverUrl?token=$token';
      if (localPath != null && File(localPath).existsSync()) {
        coverUrl = 'file://$localPath';
      }
      final isAudioRaw = m['isAudioBook'] as int?;
      final durationRaw = m['durationMs'] as int?;
      final computedIsAudio = (isAudioRaw != null)
          ? (isAudioRaw != 0)
          : (durationRaw != null && durationRaw > 0);
      return Book(
        id: id,
        title: (m['title'] as String),
        author: m['author'] as String?,
        coverUrl: coverUrl,
        description: m['description'] as String?,
        durationMs: m['durationMs'] as int?,
        sizeBytes: m['sizeBytes'] as int?,
        updatedAt: (m['updatedAt'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch((m['updatedAt'] as int), isUtc: true)
            : null,
        series: m['series'] as String?,
        seriesSequence: (m['seriesSequence'] is num)
            ? (m['seriesSequence'] as num).toDouble()
            : (m['seriesSequence'] is String ? double.tryParse((m['seriesSequence'] as String)) : null),
        collection: m['collection'] as String?,
        collectionSequence: (m['collectionSequence'] is num)
            ? (m['collectionSequence'] as num).toDouble()
            : (m['collectionSequence'] is String ? double.tryParse((m['collectionSequence'] as String)) : null),
        mediaKind: m['mediaKind'] as String?,
        isAudioBook: computedIsAudio,
        libraryId: m['libraryId'] as String?,
      );
    }).toList();
    
    // Cache the results
    _queryCache[cacheKey] = books;
    _cacheTimestamps[cacheKey] = DateTime.now();
    
    _log('[BOOKS_DB] listBooksFromDbPaged: page=$page limit=$limit sort=$sort query=$query -> ${books.length} items (cached)');
    return books;
  }

  Future<int> countBooksInDb({String? query}) async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return 0;
    final whereParts = <String>[];
    final whereArgs = <Object?>[];
    if (query != null && query.trim().isNotEmpty) {
      final q = '%${query.trim().toLowerCase()}%';
      whereParts.add('(LOWER(title) LIKE ? OR LOWER(author) LIKE ?)');
      whereArgs..add(q)..add(q);
    }
    final where = whereParts.isEmpty ? '' : 'WHERE ${whereParts.join(' AND ')}';
    final rows = await db.rawQuery('SELECT COUNT(*) as c FROM books $where', whereArgs);
    final n = rows.isNotEmpty ? rows.first['c'] as int? : 0;
    return n ?? 0;
  }

  /// Ensure the given page exists in local DB; if not, fetch from server and upsert.
  Future<void> ensureServerPageIntoDb({required int page, int limit = 50, String? query, String sort = 'updatedAt:desc'}) async {
    // Simple heuristic: if DB has fewer than page*limit rows matching query, fetch page
    final have = await countBooksInDb(query: query);
    if (have >= page * limit) return;
    try {
      await fetchBooksPage(page: page, limit: limit, query: query, sort: sort);
    } catch (_) {}
  }

  /// Get a single book from local database (offline fallback). Returns null if not found.
  Future<Book?> getBookFromDb(String id) async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return null;
    final rows = await db.query('books', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    final m = rows.first;
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();
    final localPath = (m['coverPath'] as String?);
    var coverUrl = '$baseUrl/api/items/$id/cover';
    if (token != null && token.isNotEmpty) coverUrl = '$coverUrl?token=$token';
    if (localPath != null && File(localPath).existsSync()) {
      coverUrl = 'file://$localPath';
    }
    return Book(
      id: id,
      title: (m['title'] as String),
      author: m['author'] as String?,
      coverUrl: coverUrl,
      description: m['description'] as String?,
      durationMs: m['durationMs'] as int?,
      sizeBytes: m['sizeBytes'] as int?,
      updatedAt: (m['updatedAt'] as int?) != null
          ? DateTime.fromMillisecondsSinceEpoch((m['updatedAt'] as int), isUtc: true)
          : null,
      series: m['series'] as String?,
      seriesSequence: (m['seriesSequence'] is num)
          ? (m['seriesSequence'] as num).toDouble()
          : (m['seriesSequence'] is String ? double.tryParse((m['seriesSequence'] as String)) : null),
      collection: m['collection'] as String?,
      collectionSequence: (m['collectionSequence'] is num)
          ? (m['collectionSequence'] as num).toDouble()
          : (m['collectionSequence'] is String ? double.tryParse((m['collectionSequence'] as String)) : null),
      mediaKind: m['mediaKind'] as String?,
      isAudioBook: ((m['isAudioBook'] as int?) != null)
          ? (((m['isAudioBook'] as int?) ?? 0) != 0)
          : (((m['durationMs'] as int?) ?? 0) > 0),
      libraryId: m['libraryId'] as String?,
    );
  }

  /// Upsert a single book into the local DB (convenience)
  Future<void> upsertBook(Book b) async {
    await _upsertBooks([b]);
  }

  // ================== Description images caching ==================
  Future<Directory> _descImagesDirFor(String bookId) async {
    final dbPath = await getDatabasesPath();
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_' + libId, bookId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static String _hashUrl(String url) {
    final d = sha1.convert(utf8.encode(url));
    return d.toString();
  }

  static String _extensionFromUrl(String url) {
    final lower = url.toLowerCase();
    // Look for extension before optional query string
    final re = RegExp(r'\.((?:jpg|jpeg|png|webp|gif))(?:\?|$)', caseSensitive: false);
    final m = re.firstMatch(lower);
    if (m != null && m.groupCount >= 1) return m.group(1)!.toLowerCase();
    return 'img';
  }

  static String _extensionFromContentType(String? ct) {
    if (ct == null) return 'img';
    final lower = ct.toLowerCase();
    if (lower.contains('jpeg')) return 'jpg';
    if (lower.contains('png')) return 'png';
    if (lower.contains('webp')) return 'webp';
    if (lower.contains('gif')) return 'gif';
    return 'img';
  }

  Future<void> _persistDescriptionImages(Book b) async {
    final urls = _extractImageUrlsFromDescription(b.description);
    if (urls.isEmpty) return;
    final dir = await _descImagesDirFor(b.id);
    final client = http.Client();
    try {
      for (final u in urls) {
        try {
          final name = _hashUrl(u);
          // Try any existing ext variants first
          File file = File(p.join(dir.path, '$name.jpg'));
          if (!await file.exists()) file = File(p.join(dir.path, '$name.jpeg'));
          if (!await file.exists()) file = File(p.join(dir.path, '$name.png'));
          if (!await file.exists()) file = File(p.join(dir.path, '$name.webp'));
          if (!await file.exists()) file = File(p.join(dir.path, '$name.gif'));
          if (!await file.exists()) file = File(p.join(dir.path, '$name.img'));
          if (await file.exists()) continue;
          final resp = await client.get(Uri.parse(u));
          if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
            final ct = resp.headers['content-type'];
            final extCt = _extensionFromContentType(ct);
            final extUrl = _extensionFromUrl(u);
            final chosen = extCt != 'img' ? extCt : extUrl;
            final out = File(p.join(dir.path, '$name.$chosen'));
            await out.writeAsBytes(resp.bodyBytes, flush: true);
          }
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }

  List<String> _extractImageUrlsFromDescription(String? description) {
    if (description == null || description.isEmpty) return const [];
    final urls = <String>{};
    // Try JSON shapes first
    try {
      final parsed = jsonDecode(description);
      if (parsed is Map<String, dynamic>) {
        final cand = parsed['images'] ?? parsed['imageUrls'] ?? parsed['imagesUrls'];
        if (cand is List) {
          for (final it in cand) {
            if (it is String && _looksLikeImageUrl(it)) urls.add(it);
          }
        }
        // generic scan over all string values
        for (final v in parsed.values) {
          if (v is String && _looksLikeImageUrl(v)) urls.add(v);
        }
      } else if (parsed is List) {
        for (final it in parsed) {
          if (it is String && _looksLikeImageUrl(it)) urls.add(it);
          if (it is Map) {
            for (final v in it.values) {
              if (v is String && _looksLikeImageUrl(v)) urls.add(v);
            }
          }
        }
      }
    } catch (_) {
      // Not JSON; fall back to regex
      final re = RegExp(r'https?://[^\s"\)]+\.(?:png|jpg|jpeg|webp|gif)', caseSensitive: false);
      for (final m in re.allMatches(description)) {
        urls.add(m.group(0)!);
      }
    }
    return urls.toList();
  }

  bool _looksLikeImageUrl(String s) {
    final lower = s.toLowerCase();
    return lower.startsWith('http') && (lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp') || lower.endsWith('.gif'));
  }

  static Future<Uri> localOrRemoteDescriptionImageUri(String bookId, String url) async {
    final dbPath = await getDatabasesPath();
    final prefs = await SharedPreferences.getInstance();
    final libId = prefs.getString(_libIdKey) ?? 'default';
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_' + libId, bookId));
    final name = _hashUrl(url);
    for (final ext in ['jpg','jpeg','png','webp','gif','img']) {
      final file = File(p.join(dir.path, '$name.$ext'));
      if (await file.exists()) {
        return Uri.file(file.path);
      }
    }
    return Uri.parse(url);
  }

  /// Clear ETag cache to force fresh data on next request
  Future<void> _clearEtagCache() async {
    debugPrint('BooksRepository: Clearing ETag cache to force fresh data');
    await _prefs.remove(_etagKey);
    await _prefs.remove(_cacheKey);
  }

  /// Explicit refresh from server; persists to DB and cache, returns fresh list
  Future<List<Book>> refreshFromServer() async {
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;
    final path = '/api/libraries/$libId/items?limit=50&sort=updatedAt:desc$tokenQS';
    final bool localEmpty = await _isDbEmpty();
    debugPrint('[BOOKS] refreshFromServer: GET $path headers=${headers.keys.toList()}');
    http.Response resp = await api.request('GET', path, headers: headers);

    if (resp.statusCode == 304) {
      // Force a network fetch without ETag to get fresh data
      resp = await api.request('GET', path, headers: {});
    }

    if (resp.statusCode == 200) {
      final bodyStr = resp.body;
      debugPrint('[BOOKS] refreshFromServer: 200 etag=${resp.headers['etag']} len=${bodyStr.length}');
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final newEtag = resp.headers['etag'];
      await _prefs.setString(_cacheKey, bodyStr);
      if (newEtag != null) await _prefs.setString(_etagKey, newEtag);

      final items = _extractItems(body);
      List<Book> books = await _toBooks(items);
      // Keep only audiobooks
      books = books.where((b) => b.isAudioBook).toList();
      // Write DB immediately so UI can render without delay
      await _upsertBooks(books);
      // Do not prefetch covers here; allow UI to load covers on-demand
      return await _listBooksFromDb();
    }
    // On error, return local DB
    debugPrint('[BOOKS] refreshFromServer: non-200=${resp.statusCode} -> returning local');
    return await _listBooksFromDb();
  }

  /// Fetch one page of books from server, persist to DB, and return the page
  Future<List<Book>> fetchBooksPage({required int page, int limit = 50, String sort = 'updatedAt:desc', String? query}) async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final token = await api.accessToken();
      final libId = await _ensureLibraryId();
      final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
      final encodedQ = (query != null && query.trim().isNotEmpty)
          ? Uri.encodeQueryComponent(query.trim())
          : null;

      Future<List<Book>> requestAndParse(String path) async {
        _log('[BOOKS] fetchBooksPage: GET $path');
        final resp = await api.request('GET', path, headers: {});
        if (resp.statusCode != 200) {
          throw Exception('Failed to fetch: ${resp.statusCode}');
        }
        final bodyStr = resp.body;
        final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
        final items = _extractItems(body);
        List<Book> books = await _toBooks(items);
        // Keep only audiobooks
        books = books.where((b) => b.isAudioBook).toList();
        _log('[BOOKS] fetchBooksPage: page=$page limit=$limit sort=$sort query=${encodedQ != null} -> items=${books.length}');
        return books;
      }

    // 1) Try page-based
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final pathPage = (encodedQ != null)
        ? '$basePage&search=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    List<Book> books = await requestAndParse(pathPage).catchError((e) async {
      debugPrint('[BOOKS] fetchBooksPage: primary failed -> trying q= fallback. err=$e');
      if (encodedQ != null) {
        final alt = '$basePage&q=$encodedQ$tokenQS';
        return requestAndParse(alt);
      }
      return Future.error(e);
    });

    // If page > 1 and all IDs already exist (server ignored page), try offset
    if (page > 1 && await _allIdsExistInDb(books.map((b) => b.id))) {
      debugPrint('[BOOKS] fetchBooksPage: page ignored? all ids known -> trying offset');
      final offset = (page - 1) * limit;
      final baseOffset = '/api/libraries/$libId/items?limit=$limit&offset=$offset&sort=$sort';
      final pathOffset = (encodedQ != null)
          ? '$baseOffset&search=$encodedQ$tokenQS'
          : '$baseOffset$tokenQS';
      try {
        final altBooks = await requestAndParse(pathOffset);
        if (!await _allIdsExistInDb(altBooks.map((b) => b.id))) {
          books = altBooks;
        }
      } catch (_) {
        // Try skip as last resort
        debugPrint('[BOOKS] fetchBooksPage: offset failed -> trying skip');
        final baseSkip = '/api/libraries/$libId/items?limit=$limit&skip=$offset&sort=$sort';
        final pathSkip = (encodedQ != null)
            ? '$baseSkip&search=$encodedQ$tokenQS'
            : '$baseSkip$tokenQS';
        try {
          final altBooks2 = await requestAndParse(pathSkip);
          if (!await _allIdsExistInDb(altBooks2.map((b) => b.id))) {
            books = altBooks2;
          }
        } catch (_) {}
      }
    }

      await _upsertBooks(books);
      _log('[BOOKS] fetchBooksPage: upserted=${books.length} page=$page');
      return books;
    });
  }

  /// Perform a full-library sync into the local database by iterating pages
  /// until exhaustion. Returns the total number of items synced. Optionally
  /// reports progress via [onProgress] with (currentPage, totalSynced).
  /// If [removeDeleted] is true, removes books that exist locally but not on server.
  Future<int> syncAllBooksToDb({
    int pageSize = 100,
    String sort = 'updatedAt:desc',
    String? query,
    void Function(int page, int totalSynced)? onProgress,
    bool removeDeleted = false,
  }) async {
    int total = 0;
    int offset = 0;
    int page = 1;
    final Set<String> seenIds = <String>{};
    final List<Book> allServerBooks = <Book>[];
    int noProgressStreak = 0;
    
    while (true) {
      List<Book> chunk = const <Book>[];
      try {
        chunk = await _fetchBooksChunkPreferOffset(
          offset: offset,
          limit: pageSize,
          sort: sort,
          query: query,
        );
      } catch (e) {
        debugPrint('[BOOKS] syncAll: error: $e at page=$page offset=$offset');
        break;
      }
      if (chunk.isEmpty) break;
      
      // Collect all server books for deletion check
      if (removeDeleted) {
        allServerBooks.addAll(chunk);
      }
      
      final ids = chunk.map((b) => b.id).where((id) => id.isNotEmpty).toSet();
      final before = seenIds.length;
      seenIds.addAll(ids);
      final added = seenIds.length - before;
      total += added;
      debugPrint('[BOOKS] syncAll: page=$page chunk=${chunk.length} new=$added total=$total');
      if (added == 0) {
        // Try page-based as fallback when offset/skip made no progress
        try {
          final pageChunk = await fetchBooksPage(page: page, limit: pageSize, sort: sort, query: query);
          if (removeDeleted) {
            allServerBooks.addAll(pageChunk);
          }
          final before2 = seenIds.length;
          seenIds.addAll(pageChunk.map((b) => b.id));
          final added2 = seenIds.length - before2;
          if (added2 > 0) {
            debugPrint('[BOOKS] syncAll: fallback page-based yielded new=$added2');
            noProgressStreak = 0;
          } else {
            noProgressStreak += 1;
          }
        } catch (_) {
          noProgressStreak += 1;
        }
      } else {
        noProgressStreak = 0;
      }
      if (noProgressStreak >= 2) break;
      if (onProgress != null) onProgress(page, total);
      if (chunk.length < pageSize) break;
      offset += pageSize;
      page += 1;
    }
    
    // Handle deletions if requested and we have a complete server list
    if (removeDeleted && query == null) { // Only remove deleted books for full library sync (not search)
      await _removeDeletedBooks(allServerBooks);
    }
    
    return total;
  }

  /// Remove books that exist locally but not on the server
  Future<void> _removeDeletedBooks(List<Book> serverBooks) async {
    final db = _db;
    if (db == null) return;

    // Get current local book IDs
    final localRows = await db.query('books', columns: ['id']);
    final localIds = localRows.map((row) => row['id'] as String).toSet();
    
    // Get server book IDs
    final serverIds = serverBooks.map((book) => book.id).toSet();
    
    // Find books to delete (exist locally but not on server)
    final toDelete = localIds.difference(serverIds);
    
    if (toDelete.isNotEmpty) {
      debugPrint('[BOOKS] Removing ${toDelete.length} deleted books from local DB');
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in toDelete) {
          batch.delete('books', where: 'id = ?', whereArgs: [id]);
          debugPrint('[BOOKS] Removing deleted book: $id');
        }
        await batch.commit(noResult: true);
      });
    }
  }

  /// Manual cleanup: Check each cached book against server and remove deleted/broken ones
  /// Returns the number of books cleaned up
  Future<int> cleanupDeletedAndBrokenBooks({
    void Function(int checked, int total, String? currentTitle)? onProgress,
    bool Function()? shouldContinue,
  }) async {
    final db = _db;
    if (db == null) return 0;

    // Get all local books
    final localRows = await db.query('books', columns: ['id', 'title']);
    final totalBooks = localRows.length;
    
    if (totalBooks == 0) return 0;
    
    debugPrint('[BOOKS] Starting cleanup of ${totalBooks} cached books');
    
    final api = _auth.api;
    final toDelete = <String>[];
    int checked = 0;
    
    for (final row in localRows) {
      // Check if cancelled
      if (shouldContinue != null && !shouldContinue()) {
        debugPrint('[BOOKS] Cleanup cancelled by user');
        break;
      }
      
      final bookId = row['id'] as String;
      final bookTitle = row['title'] as String;
      checked++;
      
      // Report progress
      onProgress?.call(checked, totalBooks, bookTitle);
      
      try {
        // Check if book still exists on server
        final resp = await api.request('GET', '/api/items/$bookId');
        
        if (resp.statusCode == 404) {
          // Book deleted from server
          toDelete.add(bookId);
          debugPrint('[BOOKS] Book deleted on server: $bookTitle ($bookId)');
        } else if (resp.statusCode != 200) {
          // Other error - could be network issue, don't delete
          debugPrint('[BOOKS] Server error ${resp.statusCode} for book: $bookTitle ($bookId) - keeping');
        }
        // If 200, book exists and is fine
        
      } catch (e) {
        // Network error or other issue - don't delete, could be temporary
        debugPrint('[BOOKS] Network error checking book: $bookTitle ($bookId) - keeping. Error: $e');
      }
      
      // Small delay to avoid overwhelming the server
      if (checked % 10 == 0) {
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Check cancellation after delay too
        if (shouldContinue != null && !shouldContinue()) {
          debugPrint('[BOOKS] Cleanup cancelled by user');
          break;
        }
      }
    }
    
    // Remove deleted books
    if (toDelete.isNotEmpty) {
      debugPrint('[BOOKS] Cleaning up ${toDelete.length} deleted/broken books');
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in toDelete) {
          batch.delete('books', where: 'id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });
      
      // Update cache metadata
      await _updateCacheMetadata(totalBooks - toDelete.length);
    }
    
    debugPrint('[BOOKS] Cleanup completed: ${toDelete.length} books removed');
    return toDelete.length;
  }

  Future<bool> _isDbEmpty() async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return true;
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books')) ?? 0;
    return count == 0;
  }

  Future<bool> _allIdsExistInDb(Iterable<String> ids) async {
    final list = ids.where((e) => e.isNotEmpty).toList();
    if (list.isEmpty) return true;
    final db = _db;
    if (db == null) return false;
    // Build placeholders (?, ?, ...)
    final placeholders = List.filled(list.length, '?').join(',');
    final rows = await db.rawQuery('SELECT id FROM books WHERE id IN ($placeholders)', list);
    return rows.length >= list.length;
  }

  /// Fetch a chunk of books preferring offset/skip; falls back to page-based.
  Future<List<Book>> _fetchBooksChunkPreferOffset({
    required int offset,
    required int limit,
    String sort = 'updatedAt:desc',
    String? query,
  }) async {
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final encodedQ = (query != null && query.trim().isNotEmpty)
        ? Uri.encodeQueryComponent(query.trim())
        : null;

    Future<List<Book>> requestAndParse(String path) async {
      debugPrint('[BOOKS] chunk: GET $path');
      final resp = await api.request('GET', path, headers: {});
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch: ${resp.statusCode}');
      }
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final items = _extractItems(body);
      final books = await _toBooks(items);
      debugPrint('[BOOKS] chunk: offset=$offset limit=$limit items=${books.length}');
      await _upsertBooks(books);
      return books;
    }

    // Try offset
    final baseOffset = '/api/libraries/$libId/items?limit=$limit&offset=$offset&sort=$sort';
    final pathOffset = (encodedQ != null)
        ? '$baseOffset&search=$encodedQ$tokenQS'
        : '$baseOffset$tokenQS';
    try {
      final books = await requestAndParse(pathOffset);
      if (offset > 0 && await _allIdsExistInDb(books.map((b) => b.id))) {
        debugPrint('[BOOKS] chunk: offset returned known items, trying skip');
      } else {
        return books;
      }
    } catch (_) {}

    // Try skip
    final baseSkip = '/api/libraries/$libId/items?limit=$limit&skip=$offset&sort=$sort';
    final pathSkip = (encodedQ != null)
        ? '$baseSkip&search=$encodedQ$tokenQS'
        : '$baseSkip$tokenQS';
    try {
      final books = await requestAndParse(pathSkip);
      if (offset > 0 && await _allIdsExistInDb(books.map((b) => b.id))) {
        debugPrint('[BOOKS] chunk: skip returned known items, falling back to page');
      } else {
        return books;
      }
    } catch (_) {}

    // Fall back to page-based
    final page = (offset ~/ limit) + 1;
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final pathPage = (encodedQ != null)
        ? '$basePage&search=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    List<Book> pageBooks = await requestAndParse(pathPage);
    // Already filtered to audiobooks inside requestAndParse
    return pageBooks;
  }

  // ---- Offline covers ----
  Future<Directory> _coversDir() async {
    final dbPath = await getDatabasesPath();
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    // Use the same base root as database to avoid extra permissions
    final dir = Directory(p.join(dbPath, 'kitzi_covers', 'lib_' + libId));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _coverFileForId(String id) async {
    final dir = await _coversDir();
    return File(p.join(dir.path, '$id.jpg'));
  }

  Future<void> _persistCovers(List<Book> books) async {
    final client = http.Client();
    try {
      for (final b in books) {
        final file = await _coverFileForId(b.id);
        if (await file.exists()) continue;
        try {
          // Always fetch from server for highest quality; strip any file:// fallback
          var src = b.coverUrl;
          if (src.startsWith('file://')) {
            final baseUrl = _auth.api.baseUrl ?? '';
            final token = await _auth.api.accessToken();
            src = '$baseUrl/api/items/${b.id}/cover';
            if (token != null && token.isNotEmpty) src = '$src?token=$token';
          }
          final resp = await client.get(Uri.parse(src));
          if (resp.statusCode == 200 && resp.bodyBytes.isNotEmpty) {
            await file.writeAsBytes(resp.bodyBytes, flush: true);
            // Update DB row's coverPath
            final db = _db;
            if (db != null) {
              await db.update('books', {'coverPath': file.path}, where: 'id = ?', whereArgs: [b.id]);
            }
          }
        } catch (_) {}
      }
    } finally {
      client.close();
    }
  }
}
