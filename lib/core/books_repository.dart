import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'package:crypto/crypto.dart';
import '../models/book.dart';
import '../models/series.dart';
import 'auth_repository.dart';
import 'network_service.dart';
import 'offline_first_repository.dart';

class BooksRepository {
  BooksRepository(this._auth, this._prefs);
  final AuthRepository _auth;
  final SharedPreferences _prefs;
  
  // Enable/disable verbose logging  
  static const bool _verboseLogging = true;
  Database? _db;
  String? _dbLibId; // track which library the DB connection belongs to
  
  // Query caching for better performance
  final Map<String, List<Book>> _queryCache = {};
  final Map<String, DateTime> _cacheTimestamps = {};
  static final StreamController<BookDbChange> _dbChangeCtrl = StreamController<BookDbChange>.broadcast();
  bool _disposed = false;
  final Queue<Book> _coverRetryQueue = Queue();
  final Map<String, int> _coverRetryAttempts = {};
  Timer? _coverRetryTimer;

  String _normalizedQueryKey(String sort, String? query) {
    final normalizedSort = sort.trim().toLowerCase().replaceAll(':', '_');
    final normalizedQuery = (query == null || query.trim().isEmpty)
        ? 'all'
        : base64Url.encode(utf8.encode(query.trim().toLowerCase()));
    return '${normalizedSort}_$normalizedQuery';
  }

  String _etagPrefsKey(String sort, String? query) =>
      'books_etag_${_normalizedQueryKey(sort, query)}';

  String _lastSyncPrefsKey(String sort, String? query) =>
      'books_last_sync_${_normalizedQueryKey(sort, query)}';

  String _lastUpdateCheckPrefsKey() {
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    return 'books_last_update_check_$libId';
  }

  Stream<BookDbChange> get dbChanges => _dbChangeCtrl.stream;
  static const Duration _cacheTTL = Duration(minutes: 5);
  
  /// Log debug message only if verbose logging is enabled
  void _log(String message) {
    if (_verboseLogging) {
      debugPrint('[BOOKS_REPO] $message');
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
    // Cache cleared due to memory pressure
  }

  void _notifyDbChange(BookDbChangeType type, Set<String> ids) {
    if (ids.isEmpty) return;
    if (_dbChangeCtrl.isClosed || !_dbChangeCtrl.hasListener) return;
    _dbChangeCtrl.add(BookDbChange(type: type, ids: ids));
  }

  static const _etagKey = 'books_list_etag';
  static const _cacheKey = 'books_list_cache_json';
  static const _libIdKey = 'books_library_id';
  static const _cacheMetadataKey = 'books_cache_metadata';

  Future<String> _ensureLibraryId() async {
    final cached = _prefs.getString(_libIdKey);
    if (cached != null && cached.isNotEmpty) {
      // Make sure the open DB matches the cached library before returning
      await _ensureDbForLibrary(cached);
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
    await _ensureDbForLibrary(id); // Switch DB/caches to the active library
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
      final path = p.join(dbPath, 'kitzi_books_$libId.db');
      final db = await openDatabase(path);
      await db.execute('DELETE FROM books');
      await db.close();
    } catch (_) {}

    try {
      // Delete DB file (best effort; may fail if another connection is open) for current library
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final dbFile = p.join(dbPath, 'kitzi_books_$libId.db');
      await deleteDatabase(dbFile);
    } catch (_) {}

    try {
      // Delete covers directory (current library only)
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final coversDir = Directory(p.join(dbPath, 'kitzi_covers', 'lib_$libId'));
      if (await coversDir.exists()) {
        await coversDir.delete(recursive: true);
      }
    } catch (_) {}

    try {
      // Delete description images directory tree (current library only)
      final dbPath = await getDatabasesPath();
      final prefs = await SharedPreferences.getInstance();
      final libId = prefs.getString(_libIdKey) ?? 'default';
      final descDir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_$libId'));
      if (await descDir.exists()) {
        await descDir.delete(recursive: true);
      }
    } catch (_) {}
  }

  Future<void> _openDb() async {
    final dbPath = await getDatabasesPath();
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    final path = p.join(dbPath, 'kitzi_books_$libId.db');
    _db = await openDatabase(
      path,
      version: 5, // Increment version to trigger migration
      onCreate: (db, v) async {
        await db.execute('''
          CREATE TABLE books (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            author TEXT,
            coverUrl TEXT NOT NULL,
            coverPath TEXT,
            coverUpdatedAt INTEGER,
            description TEXT,
            durationMs INTEGER,
            sizeBytes INTEGER,
            updatedAt INTEGER,
            addedAt INTEGER,
            series TEXT,
            seriesSequence REAL,
            collection TEXT,
            collectionSequence REAL,
            isAudioBook INTEGER NOT NULL DEFAULT 1,
            mediaKind TEXT,
            libraryId TEXT,
            authors TEXT,
            narrators TEXT,
            publisher TEXT,
            publishYear INTEGER,
            genres TEXT
          )
        ''');
        
        // Add indexes for better query performance
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_updatedAt ON books(updatedAt DESC)');
        await db.execute('CREATE INDEX IF NOT EXISTS idx_books_addedAt ON books(addedAt DESC)');
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
        if (oldVersion < 2) {
          await _migrateToVersion2(db);
        }
        if (oldVersion < 3) {
          await _migrateToVersion3(db);
        }
        if (oldVersion < 4) {
          await _migrateToVersion4(db);
        }
        if (oldVersion < 5) {
          await _migrateToVersion5(db);
        }
      },
    );

    _dbLibId = libId;
  }
  
  /// Migrate database from version 1 to version 2
  Future<void> _migrateToVersion2(Database db) async {
    // Migrating from version 1 to 2
    
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
    
    // Migration to version 2 completed
  }

  Future<void> _migrateToVersion3(Database db) async {
    await _addColumnIfNotExists(db, 'books', 'coverUpdatedAt', 'INTEGER');
  }

  Future<void> _migrateToVersion4(Database db) async {
    await _addColumnIfNotExists(db, 'books', 'authors', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'narrators', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'publisher', 'TEXT');
    await _addColumnIfNotExists(db, 'books', 'publishYear', 'INTEGER');
    await _addColumnIfNotExists(db, 'books', 'genres', 'TEXT');
  }

  Future<void> _migrateToVersion5(Database db) async {
    // Add addedAt column (nullable, so existing rows won't break)
    await _addColumnIfNotExists(db, 'books', 'addedAt', 'INTEGER');
    // Add index for addedAt sorting
    await db.execute('CREATE INDEX IF NOT EXISTS idx_books_addedAt ON books(addedAt DESC)');
    // Populate addedAt from updatedAt for existing books (best effort migration)
    // This gives existing books a reasonable addedAt value, but users should resync for accurate data
    await db.execute('UPDATE books SET addedAt = updatedAt WHERE addedAt IS NULL AND updatedAt IS NOT NULL');
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
      // Error adding column
    }
  }

  Future<void> _ensureDbForCurrentLib() async {
    final current = _prefs.getString(_libIdKey) ?? 'default';
    if (_db == null || _dbLibId != current) {
      try { await _db?.close(); } catch (_) {}
      _db = null;
      _dbLibId = null;
      await _openDb();
    }
  }

  /// Ensure the open DB and caches are aligned to the provided library id.
  Future<void> _ensureDbForLibrary(String libId) async {
    if (_dbLibId == libId && _db != null) return;
    try { await _db?.close(); } catch (_) {}
    _db = null;
    _dbLibId = null;

    // Clear cached etags/metadata that are library-specific to avoid cross-library pollution.
    try {
      await _prefs.remove(_etagKey);
      await _prefs.remove(_cacheKey);
      await _prefs.remove(_cacheMetadataKey);
      for (final k in _prefs.getKeys()) {
        if (k.startsWith('books_etag_') || k.startsWith('books_last_sync_')) {
          await _prefs.remove(k);
        }
      }
    } catch (_) {}
    _clearAllCache();

    await _openDb();
  }

  Future<void> _upsertBooks(List<Book> items) async {
    final db = _db;
    if (db == null) {
      _log('[UPSERT_BOOKS] DB is null, cannot upsert');
      return;
    }
    _log('[UPSERT_BOOKS] Upserting ${items.length} books to DB');
    if (items.isNotEmpty) {
      _log('[UPSERT_BOOKS] First book: "${items.first.title}" (id: ${items.first.id}, updatedAt: ${items.first.updatedAt?.toIso8601String() ?? "null"})');
      _log('[UPSERT_BOOKS] Last book: "${items.last.title}" (id: ${items.last.id}, updatedAt: ${items.last.updatedAt?.toIso8601String() ?? "null"})');
    }
    
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
            'coverUpdatedAt': b.updatedAt?.millisecondsSinceEpoch,
            'description': b.description,
            'durationMs': b.durationMs,
            'sizeBytes': b.sizeBytes,
            'updatedAt': b.updatedAt?.millisecondsSinceEpoch,
            'addedAt': b.addedAt?.millisecondsSinceEpoch ?? b.updatedAt?.millisecondsSinceEpoch,
            'series': b.series,
            'seriesSequence': b.seriesSequence,
            'collection': b.collection,
            'collectionSequence': b.collectionSequence,
            'isAudioBook': b.isAudioBook ? 1 : 0,
            'mediaKind': b.mediaKind,
            'libraryId': b.libraryId ?? libId,
            'authors': b.authors != null ? jsonEncode(b.authors) : null,
            'narrators': b.narrators != null ? jsonEncode(b.narrators) : null,
            'publisher': b.publisher,
            'publishYear': b.publishYear,
            'genres': b.genres != null ? jsonEncode(b.genres) : null,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
    
    _log('[UPSERT_BOOKS] Transaction committed successfully');
    
    // Update cache metadata
    await _updateCacheMetadata(items.length);
    _clearAllCache();
    final changedIds = items.map((b) => b.id).where((id) => id.isNotEmpty).toSet();
    _log('[UPSERT_BOOKS] Notifying ${changedIds.length} changed book IDs');
    _notifyDbChange(BookDbChangeType.upsert, changedIds);
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
      // Failed to update cache metadata
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
      // Failed to get cache metadata
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
      case 'addedAt:desc':
      case 'addedDesc':
        // Use addedAt, fallback to updatedAt for old books that don't have addedAt
        orderBy = 'addedAt IS NULL, addedAt DESC, updatedAt DESC';
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
        addedAt: (m['addedAt'] as int?) != null
            ? DateTime.fromMillisecondsSinceEpoch((m['addedAt'] as int), isUtc: true)
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

  Future<void> incrementalSync({
    String sort = 'updatedAt:desc',
    String? query,
    int pageSize = 50,
    int maxPages = 4,
    bool forceCheck = false,
  }) async {
    // For detecting new books, use addedAt sorting
    final syncSort = forceCheck ? 'addedAt&desc=1' : sort;
    final lastSyncKey = _lastSyncPrefsKey(syncSort, query);
    int? lastSyncMs;
    DateTime? cutoffTime;
    if (!forceCheck) {
      lastSyncMs = _prefs.getInt(lastSyncKey);
    } else {
      // When force checking, get the newest book's updatedAt from DB as cutoff
      // We'll stop when we hit books older than this
      // Use updatedAt:desc for DB query since that's what we store
      try {
        final newestBooks = await listBooksFromDbPaged(page: 1, limit: 1, sort: 'updatedAt:desc', query: query);
        if (newestBooks.isNotEmpty && newestBooks.first.updatedAt != null) {
          cutoffTime = newestBooks.first.updatedAt;
          _log('[INCREMENTAL_SYNC] forceCheck=true, using cutoff time: ${cutoffTime!.toIso8601String()}');
        }
      } catch (_) {}
    }
    final lastSync = lastSyncMs != null
        ? DateTime.fromMillisecondsSinceEpoch(lastSyncMs, isUtc: true)
        : null;
    _log('[INCREMENTAL_SYNC] Starting (forceCheck=$forceCheck, lastSync=${lastSync?.toIso8601String() ?? "null"}, cutoffTime=${cutoffTime?.toIso8601String() ?? "null"}, query=${query ?? "null"}, maxPages=$maxPages)');
    int page = 1;
    int pagesFetched = 0;
    int totalBooksFetched = 0;
    while (pagesFetched < maxPages) {
      _log('[INCREMENTAL_SYNC] Fetching page $page...');
      final books = await fetchBooksPage(
        page: page,
        limit: pageSize,
        sort: syncSort,
        query: query,
        forceRefresh: forceCheck,
      );
      _log('[INCREMENTAL_SYNC] Page $page returned ${books.length} books');
      if (books.isEmpty) {
        _log('[INCREMENTAL_SYNC] Empty page, stopping');
        break;
      }
      totalBooksFetched += books.length;
      pagesFetched++;
      if (books.isNotEmpty) {
        final firstBook = books.first;
        final lastBook = books.last;
        _log('[INCREMENTAL_SYNC] Page $page: first book "${firstBook.title}" (updatedAt: ${firstBook.updatedAt?.toIso8601String() ?? "null"}), last book "${lastBook.title}" (updatedAt: ${lastBook.updatedAt?.toIso8601String() ?? "null"})');
      }
      if (lastSync != null) {
        // Check if the newest book (first in desc-sorted list) is newer than lastSync
        // Since we sort by updatedAt:desc, if the first book isn't newer, none are
        final firstBook = books.isNotEmpty ? books.first : null;
        if (firstBook?.updatedAt == null || !firstBook!.updatedAt!.isAfter(lastSync)) {
          // No new books on this page, we can stop
          _log('[INCREMENTAL_SYNC] First book (${firstBook?.updatedAt?.toIso8601String() ?? "null"}) is not newer than lastSync (${lastSync.toIso8601String()}), stopping');
          break;
        } else {
          _log('[INCREMENTAL_SYNC] First book is newer than lastSync, continuing');
        }
      } else if (forceCheck && cutoffTime != null) {
        // When forcing check, stop when the newest book on this page (first in desc-sorted list)
        // is older than or equal to the cutoff (meaning we've reached old books we already have)
        // Since books are sorted desc by updatedAt, if the newest on this page is <= cutoff,
        // all books on this and later pages are old
        final newestBookOnPage = books.isNotEmpty ? books.first : null;
        if (newestBookOnPage?.updatedAt != null) {
          // Stop if newest book is older than or equal to cutoff (we've reached old books)
          if (!newestBookOnPage!.updatedAt!.isAfter(cutoffTime!)) {
            _log('[INCREMENTAL_SYNC] Newest book on page (${newestBookOnPage.updatedAt!.toIso8601String()}) is not newer than cutoff (${cutoffTime!.toIso8601String()}), reached old books, stopping');
            break;
          }
          _log('[INCREMENTAL_SYNC] Newest book on page (${newestBookOnPage.updatedAt!.toIso8601String()}) is newer than cutoff, continuing');
        } else {
          _log('[INCREMENTAL_SYNC] Newest book has no updatedAt, continuing');
        }
      } else {
        _log('[INCREMENTAL_SYNC] No lastSync timestamp or cutoff time, continuing to fetch');
      }
      if (books.length < pageSize) {
        _log('[INCREMENTAL_SYNC] Page has fewer than $pageSize books, stopping');
        break;
      }
      page++;
    }
    _log('[INCREMENTAL_SYNC] Completed: fetched $pagesFetched pages, $totalBooksFetched total books');
    // Save last sync time using the sort key we actually used
    await _prefs.setInt(
      lastSyncKey,
      DateTime.now().toUtc().millisecondsSinceEpoch,
    );
  }

  /// Incremental sync for book updates (changed titles, album art, etc.)
  /// Fetches books sorted by updatedAt in batches of 10, only books updated after lastUpdateCheck
  Future<void> incrementalUpdateSync() async {
    final lastUpdateCheckKey = _lastUpdateCheckPrefsKey();
    int? lastUpdateCheckMs = _prefs.getInt(lastUpdateCheckKey);
    
    DateTime lastUpdateCheck;
    if (lastUpdateCheckMs != null) {
      lastUpdateCheck = DateTime.fromMillisecondsSinceEpoch(lastUpdateCheckMs, isUtc: true);
    } else {
      // Initial value: 5 days ago
      lastUpdateCheck = DateTime.now().toUtc().subtract(const Duration(days: 5));
      _log('[INCREMENTAL_UPDATE_SYNC] No previous check, using initial value: ${lastUpdateCheck.toIso8601String()}');
    }
    
    final startTime = DateTime.now().toUtc();
    _log('[INCREMENTAL_UPDATE_SYNC] Starting (lastUpdateCheck: ${lastUpdateCheck.toIso8601String()})');
    
    int page = 1;
    int pagesFetched = 0;
    int totalBooksFetched = 0;
    const pageSize = 10;
    const sort = 'updatedAt&desc=1';
    
    while (true) {
      _log('[INCREMENTAL_UPDATE_SYNC] Fetching page $page (batch size: $pageSize)...');
      
      try {
        final books = await fetchBooksPage(
          page: page,
          limit: pageSize,
          sort: sort,
          query: null,
          forceRefresh: false,
        );
        
        _log('[INCREMENTAL_UPDATE_SYNC] Page $page returned ${books.length} books');
        
        if (books.isEmpty) {
          _log('[INCREMENTAL_UPDATE_SYNC] Empty page, stopping');
          break;
        }
        
        // Check if any books on this page are newer than lastUpdateCheck
        final hasUpdates = books.any((b) => 
          b.updatedAt != null && b.updatedAt!.isAfter(lastUpdateCheck)
        );
        
        if (!hasUpdates) {
          // All books on this page are older than lastUpdateCheck, we can stop
          _log('[INCREMENTAL_UPDATE_SYNC] All books on page $page are older than lastUpdateCheck, stopping');
          break;
        }
        
        // Filter to only books newer than lastUpdateCheck and upsert them
        final booksToUpdate = books.where((b) => 
          b.updatedAt != null && b.updatedAt!.isAfter(lastUpdateCheck)
        ).toList();
        
        if (booksToUpdate.isNotEmpty) {
          await _upsertBooks(booksToUpdate);
          totalBooksFetched += booksToUpdate.length;
          _log('[INCREMENTAL_UPDATE_SYNC] Updated ${booksToUpdate.length} books from page $page');
        }
        
        pagesFetched++;
        
        // Check if we should continue (if the newest book on page is still newer than lastUpdateCheck)
        final newestBookOnPage = books.first;
        if (newestBookOnPage.updatedAt == null || !newestBookOnPage.updatedAt!.isAfter(lastUpdateCheck)) {
          _log('[INCREMENTAL_UPDATE_SYNC] Newest book on page (${newestBookOnPage.updatedAt?.toIso8601String() ?? "null"}) is not newer than lastUpdateCheck, stopping');
          break;
        }
        
        // If we got fewer books than pageSize, we've reached the end
        if (books.length < pageSize) {
          _log('[INCREMENTAL_UPDATE_SYNC] Page has fewer than $pageSize books, stopping');
          break;
        }
        
        page++;
      } catch (e) {
        _log('[INCREMENTAL_UPDATE_SYNC] Error fetching page $page: $e');
        break;
      }
    }
    
    // Save new lastUpdateCheck as startTime minus 12 hours (to handle timezones)
    final newLastUpdateCheck = startTime.subtract(const Duration(hours: 12));
    await _prefs.setInt(
      lastUpdateCheckKey,
      newLastUpdateCheck.millisecondsSinceEpoch,
    );
    
    _log('[INCREMENTAL_UPDATE_SYNC] Completed: fetched $pagesFetched pages, $totalBooksFetched total books updated. New lastUpdateCheck: ${newLastUpdateCheck.toIso8601String()}');
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
    // Parse JSON fields for lists
    List<String>? authorsList;
    try {
      final authorsStr = m['authors'] as String?;
      if (authorsStr != null && authorsStr.isNotEmpty) {
        final decoded = jsonDecode(authorsStr);
        if (decoded is List) {
          authorsList = decoded.cast<String>();
        }
      }
    } catch (_) {}
    
    List<String>? narratorsList;
    try {
      final narratorsStr = m['narrators'] as String?;
      if (narratorsStr != null && narratorsStr.isNotEmpty) {
        final decoded = jsonDecode(narratorsStr);
        if (decoded is List) {
          narratorsList = decoded.cast<String>();
        }
      }
    } catch (_) {}
    
    List<String>? genresList;
    try {
      final genresStr = m['genres'] as String?;
      if (genresStr != null && genresStr.isNotEmpty) {
        final decoded = jsonDecode(genresStr);
        if (decoded is List) {
          genresList = decoded.cast<String>();
        }
      }
    } catch (_) {}
    
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
      authors: authorsList,
      narrators: narratorsList,
      publisher: m['publisher'] as String?,
      publishYear: m['publishYear'] as int?,
      genres: genresList,
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
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_$libId', bookId));
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
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', 'lib_$libId', bookId));
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
    // Clearing ETag cache to force fresh data
    await _prefs.remove(_etagKey);
    await _prefs.remove(_cacheKey);
  }

  /// Explicit refresh from server; persists to DB and cache, returns fresh list
  Future<List<Book>> refreshFromServer() async {
    _log('[REFRESH_FROM_SERVER] Starting...');
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) {
      headers['If-None-Match'] = etag;
      _log('[REFRESH_FROM_SERVER] Using ETag: $etag');
    } else {
      _log('[REFRESH_FROM_SERVER] No ETag found');
    }
    final path = '/api/libraries/$libId/items?limit=50&sort=addedAt&desc=1$tokenQS';
    final bool localEmpty = await _isDbEmpty();
    _log('[REFRESH_FROM_SERVER] Requesting: $path (localEmpty=$localEmpty)');
    http.Response resp = await api.request('GET', path, headers: headers);
    _log('[REFRESH_FROM_SERVER] Response status: ${resp.statusCode}');

    if (resp.statusCode == 304) {
      _log('[REFRESH_FROM_SERVER] 304 Not Modified, forcing refetch without ETag...');
      // Force a network fetch without ETag to get fresh data
      resp = await api.request('GET', path, headers: {});
      _log('[REFRESH_FROM_SERVER] Forced refetch status: ${resp.statusCode}');
    }

    if (resp.statusCode == 200) {
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final newEtag = resp.headers['etag'];
      await _prefs.setString(_cacheKey, bodyStr);
      if (newEtag != null) await _prefs.setString(_etagKey, newEtag);

      final items = _extractItems(body);
      _log('[REFRESH_FROM_SERVER] Extracted ${items.length} items from response');
      List<Book> books = await _toBooks(items);
      _log('[REFRESH_FROM_SERVER] Converted to ${books.length} books');
      // Keep only audiobooks
      books = books.where((b) => b.isAudioBook).toList();
      _log('[REFRESH_FROM_SERVER] After filtering audiobooks: ${books.length} books');
      if (books.isNotEmpty) {
        _log('[REFRESH_FROM_SERVER] First book: "${books.first.title}" (id: ${books.first.id}, updatedAt: ${books.first.updatedAt?.toIso8601String() ?? "null"})');
      }
      // Write DB immediately so UI can render without delay
      _log('[REFRESH_FROM_SERVER] Upserting ${books.length} books to DB...');
      await _upsertBooks(books);
      _log('[REFRESH_FROM_SERVER] Upsert complete, loading from DB...');
      // Do not prefetch covers here; allow UI to load covers on-demand
      final dbBooks = await _listBooksFromDb();
      _log('[REFRESH_FROM_SERVER] Loaded ${dbBooks.length} books from DB');
      return dbBooks;
    }
    // On error, return local DB
    _log('[REFRESH_FROM_SERVER] Error or non-200 status, returning local DB');
    final localBooks = await _listBooksFromDb();
    _log('[REFRESH_FROM_SERVER] Returning ${localBooks.length} books from local DB');
    return localBooks;
  }

  /// Fetch one page of books from server, persist to DB, and return the page
  Future<List<Book>> fetchBooksPage({required int page, int limit = 50, String sort = 'updatedAt:desc', String? query, bool forceRefresh = false}) async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final token = await api.accessToken();
      final libId = await _ensureLibraryId();
      final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
      final encodedQ = (query != null && query.trim().isNotEmpty)
          ? Uri.encodeQueryComponent(query.trim())
          : null;

      Future<List<Book>> requestAndParse(String path, {Map<String, String>? extraHeaders}) async {
        _log('[BOOKS] fetchBooksPage: GET $path (forceRefresh=$forceRefresh)');
        final headers = extraHeaders ?? const <String, String>{};
        http.Response resp = await api.request('GET', path, headers: headers);
        if (resp.statusCode == 304 && !forceRefresh) {
          // Only use cached data if not forcing refresh
          final cachedPage = await listBooksFromDbPaged(
            page: page,
            limit: limit,
            sort: sort,
            query: query,
          );
          if (cachedPage.isNotEmpty) {
            _log('[BOOKS] fetchBooksPage: cache hit via ETag for page=$page query=${query ?? 'all'}');
            return cachedPage;
          }
          _log('[BOOKS] fetchBooksPage: ETag miss but DB empty, forcing refetch');
          resp = await api.request('GET', path, headers: {});
        } else if (resp.statusCode == 304 && forceRefresh) {
          // Force refresh: ignore 304 and fetch fresh data
          _log('[BOOKS] fetchBooksPage: 304 but forceRefresh=true, forcing fresh fetch');
          resp = await api.request('GET', path, headers: {});
        }
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
        final newEtag = resp.headers['etag'];
        if (newEtag != null) {
          final etagKey = _etagPrefsKey(sort, query);
          await _prefs.setString(etagKey, newEtag);
        }
        unawaited(_persistCovers(books));
        return books;
      }

    // 1) Try page-based (API uses 1-based page indexing)
    // Format sort parameter correctly for API
    String sortParam;
    if (sort.contains('&desc=')) {
      // Already in format: addedAt&desc=1
      sortParam = sort;
    } else if (sort == 'updatedAt:desc') {
      // Convert to addedAt format for new book detection
      sortParam = 'addedAt&desc=1';
    } else {
      sortParam = sort;
    }
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sortParam';
    final pathPage = (encodedQ != null)
        ? '$basePage&q=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    final etagKey = _etagPrefsKey(sort, query);
    final cachedEtag = _prefs.getString(etagKey);
    final headers = <String, String>{};
    // Only use ETag if not forcing refresh
    if (cachedEtag != null && page == 1 && !forceRefresh) {
      headers['If-None-Match'] = cachedEtag;
    }
    List<Book> books = await requestAndParse(pathPage, extraHeaders: headers).catchError((e) async {
      // Primary failed, trying fallback
      if (encodedQ != null) {
        final alt = '$basePage&q=$encodedQ$tokenQS';
        return requestAndParse(alt);
      }
      return Future.error(e);
    });

    // If page > 1 and all IDs already exist (server ignored page), try offset
    if (page > 1 && await _allIdsExistInDb(books.map((b) => b.id))) {
      // Page ignored, trying offset
      final offset = (page - 1) * limit;
      final baseOffset = '/api/libraries/$libId/items?limit=$limit&offset=$offset&sort=$sortParam';
      final pathOffset = (encodedQ != null)
          ? '$baseOffset&q=$encodedQ$tokenQS'
          : '$baseOffset$tokenQS';
      try {
        final altBooks = await requestAndParse(pathOffset);
        if (!await _allIdsExistInDb(altBooks.map((b) => b.id))) {
          books = altBooks;
        }
      } catch (_) {
        // Try skip as last resort
        // Offset failed, trying skip
        final baseSkip = '/api/libraries/$libId/items?limit=$limit&skip=$offset&sort=$sortParam';
        final pathSkip = (encodedQ != null)
            ? '$baseSkip&q=$encodedQ$tokenQS'
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
  /// Fetch series directly from the audiobookshelf series endpoint
  Future<List<Map<String, dynamic>>> fetchSeries({
    int limit = 100,
    int page = 0, // Series endpoint still uses 0-based indexing
    String sort = 'name',
    bool desc = false,
    String filter = 'all',
    bool minified = true,
  }) async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final token = await api.accessToken();
      final libId = await _ensureLibraryId();
      final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
      
      final descParam = desc ? '1' : '0';
      final minifiedParam = minified ? '1' : '0';
      final includes = 'rssfeed,numEpisodesIncomplete,share';
      
      final path = '/api/libraries/$libId/series?sort=$sort&desc=$descParam&filter=$filter&limit=$limit&page=$page&minified=$minifiedParam&include=$includes$tokenQS';
      
      _log('[BOOKS] fetchSeries: GET $path');
      final resp = await api.request('GET', path, headers: {});
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch series: ${resp.statusCode}');
      }
      
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      
      if (body is Map) {
        // Handle paginated response format
        if (body['results'] is List) {
          return (body['results'] as List).cast<Map<String, dynamic>>();
        }
        // Handle direct results format
        if (body['series'] is List) {
          return (body['series'] as List).cast<Map<String, dynamic>>();
        }
      }
      
      // Handle direct list response
      if (body is List) {
        return body.cast<Map<String, dynamic>>();
      }
      
      _log('[BOOKS] fetchSeries: unexpected response format');
      return <Map<String, dynamic>>[];
    });
  }

  /// Fetch all series by paginating through the series endpoint
  Future<List<Map<String, dynamic>>> fetchAllSeries({
    String sort = 'name',
    bool desc = false,
    String filter = 'all',
  }) async {
    final allSeries = <Map<String, dynamic>>[];
    int page = 0; // Series endpoint is 0-based
    const pageSize = 100;
    
    while (true) {
      try {
        final seriesChunk = await fetchSeries(
          limit: pageSize,
          page: page,
          sort: sort,
          desc: desc,
          filter: filter,
        );
        
        if (seriesChunk.isEmpty) break;
        
        allSeries.addAll(seriesChunk);
        _log('[BOOKS] fetchAllSeries: page=$page loaded=${seriesChunk.length} total=${allSeries.length}');
        
        // If we got less than the page size, we've reached the end
        if (seriesChunk.length < pageSize) break;
        
        page++;
      } catch (e) {
        _log('[BOOKS] fetchAllSeries: error at page=$page: $e');
        break;
      }
    }
    
    _log('[BOOKS] fetchAllSeries: completed with ${allSeries.length} total series');
    return allSeries;
  }

  /// Convert series JSON to Series objects with proper URL construction
  Future<List<Series>> _seriesToObjects(List<Map<String, dynamic>> seriesData) async {
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();
    return seriesData
        .map((s) => Series.fromJson(s, baseUrl: baseUrl, token: token))
        .where((s) => s.name.isNotEmpty)
        .toList();
  }

  /// Get all series as Series objects
  Future<List<Series>> getAllSeries({
    String sort = 'name',
    bool desc = false,
    String filter = 'all',
  }) async {
    try {
      final seriesData = await fetchAllSeries(sort: sort, desc: desc, filter: filter);
      return await _seriesToObjects(seriesData);
    } catch (e) {
      _log('[BOOKS] getAllSeries error: $e');
      return <Series>[];
    }
  }

  /// Get books for a specific series by fetching all books that belong to that series
  Future<List<Book>> getBooksForSeries(Series series) async {
    final seen = <String>{};
    final books = <Book>[];
    
    if (series.bookIds.isNotEmpty) {
      try {
        final local = await _loadBooksByIds(series.bookIds);
        for (final book in local) {
          if (seen.add(book.id)) books.add(book);
        }
      } catch (e) {
        _log('[BOOKS] getBooksForSeries: DB error loading ids: $e');
      }
      
      final missing = series.bookIds.where((id) => !seen.contains(id)).toList();
      if (missing.isNotEmpty) {
        for (final bookId in missing) {
          try {
            final book = await getBook(bookId);
            if (seen.add(book.id)) books.add(book);
          } catch (e) {
            _log('[BOOKS] getBooksForSeries: server fetch error for $bookId: $e');
          }
        }
      }
    } else {
      final fromDb = await _loadBooksBySeriesName(series.name);
      for (final book in fromDb) {
        if (seen.add(book.id)) books.add(book);
      }
      
      if (books.isEmpty && series.id.isNotEmpty) {
        final remote = await _fetchBooksForSeriesRemote(series);
        for (final book in remote) {
          if (seen.add(book.id)) books.add(book);
        }
      }
    }
    
    if (books.isEmpty) return const [];
    return _sortSeriesBooks(books, series);
  }

  Future<List<Book>> _loadBooksByIds(List<String> ids) async {
    if (ids.isEmpty) return const [];
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return const [];
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();
    final placeholders = List.filled(ids.length, '?').join(',');
    final rows = await db.query(
      'books',
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
    return rows.map((m) => _bookFromDbRow(m, baseUrl, token)).toList();
  }

  Future<List<Book>> _loadBooksBySeriesName(String? seriesName) async {
    if (seriesName == null || seriesName.trim().isEmpty) return const [];
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return const [];
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();
    final rows = await db.query(
      'books',
      where: 'series = ?',
      whereArgs: [seriesName],
      orderBy: 'seriesSequence IS NULL, seriesSequence ASC, title COLLATE NOCASE ASC',
    );
    return rows.map((m) => _bookFromDbRow(m, baseUrl, token)).toList();
  }

  Future<List<Book>> _fetchBooksForSeriesRemote(Series series) async {
    try {
      final libId = await _ensureLibraryId();
      final resp = await _auth.api.request('GET', '/api/libraries/$libId/series/${series.id}');
      if (resp.statusCode != 200 || resp.body.isEmpty) return const [];
      final body = jsonDecode(resp.body);
      List items = const [];
      if (body is Map) {
        if (body['books'] is List) {
          items = body['books'] as List;
        } else if (body['items'] is List) {
          items = body['items'] as List;
        }
      } else if (body is List) {
        items = body;
      }
      if (items.isEmpty) return const [];
      final baseUrl = _auth.api.baseUrl ?? '';
      final token = await _auth.api.accessToken();
      final books = items
          .whereType<Map>()
          .map((m) => Book.fromLibraryItemJson(m.cast<String, dynamic>(), baseUrl: baseUrl, token: token))
          .where((b) => b.id.isNotEmpty)
          .toList();
      if (books.isNotEmpty) {
        await _upsertBooks(books);
      }
      return books;
    } catch (e) {
      _log('[BOOKS] _fetchBooksForSeriesRemote error: $e');
      return const [];
    }
  }

  List<Book> _sortSeriesBooks(List<Book> books, Series series) {
    books.sort((a, b) {
      final sa = a.seriesSequence;
      final sb = b.seriesSequence;
      final aHasSeq = sa != null && !sa.isNaN;
      final bHasSeq = sb != null && !sb.isNaN;
      
      // Primary sort: by seriesSequence if both have it
      if (aHasSeq && bHasSeq) {
        final cmp = sa!.compareTo(sb!);
        if (cmp != 0) return cmp;
        // If sequences are equal, fall through to title comparison
      } else if (aHasSeq && !bHasSeq) {
        // Books with sequence come before books without
        return -1;
      } else if (!aHasSeq && bHasSeq) {
        // Books with sequence come before books without
        return 1;
      }
      // If neither has sequence, or both have the same sequence, fall through
      
      // Secondary sort: by book title (alphabetically)
      return a.title.toLowerCase().compareTo(b.title.toLowerCase());
    });
    
    return books;
  }

  Book _bookFromDbRow(Map<String, Object?> m, String baseUrl, String? token) {
    final id = (m['id'] as String);
    var coverUrl = '$baseUrl/api/items/$id/cover';
    if (token != null && token.isNotEmpty) coverUrl = '$coverUrl?token=$token';
    final localPath = m['coverPath'] as String?;
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
      addedAt: (m['addedAt'] as int?) != null
          ? DateTime.fromMillisecondsSinceEpoch((m['addedAt'] as int), isUtc: true)
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
  }

  /// Get server status information including version
  /// Optimized - only uses endpoints that work on your server
  Future<Map<String, dynamic>> getServerStatus() async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final token = await api.accessToken();
      final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      
      // Use /status (without /api/) - we know this works and has serverVersion
      try {
        _log('[BOOKS] Getting server version from /status');
        final resp = await api.request('GET', '/status$tokenQS');
        if (resp.statusCode == 200) {
          final bodyStr = resp.body;
          final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : <String, dynamic>{};
          if (body is Map<String, dynamic> && body.isNotEmpty) {
            final serverVersion = body['serverVersion'];
            if (serverVersion != null) {
              _log('[BOOKS] Found server version: $serverVersion');
              return {'serverVersion': serverVersion, 'source': 'status'};
            }
          }
        }
      } catch (e) {
        _log('[BOOKS] /status failed: $e');
      }
      
      // Return empty if no version found
      return <String, dynamic>{};
    });
  }

  /// Get library statistics including total count
  /// Optimized - only uses endpoint that works on your server
  Future<Map<String, dynamic>> getLibraryStats() async {
    return await NetworkService.withRetry(() async {
      final api = _auth.api;
      final token = await api.accessToken();
      final libId = await _ensureLibraryId();
      final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      
      // Use /api/libraries/{id}/stats - we know this works and returns library data
      try {
        _log('[BOOKS] Getting library stats from /api/libraries/$libId/stats');
        final resp = await api.request('GET', '/api/libraries/$libId/stats$tokenQS');
        if (resp.statusCode == 200) {
          final bodyStr = resp.body;
          final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : <String, dynamic>{};
          if (body is Map<String, dynamic> && body.isNotEmpty) {
            _log('[BOOKS] Library stats loaded successfully');
            return body;
          }
        }
      } catch (e) {
        _log('[BOOKS] Library stats failed: $e');
      }
      
      // Fallback to /api/libraries endpoint if stats fails
      return await _getLibraryStatsFromLibrariesEndpoint();
    });
  }

  /// Fallback method to get library stats from the libraries endpoint
  Future<Map<String, dynamic>> _getLibraryStatsFromLibrariesEndpoint() async {
    try {
      final api = _auth.api;
      final token = await api.accessToken();
      final libId = await _ensureLibraryId();
      final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      
      final resp = await api.request('GET', '/api/libraries$tokenQS');
      if (resp.statusCode != 200) {
        return <String, dynamic>{};
      }
      
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      
      // Look for the current library in the response
      List<dynamic> libraries = const [];
      if (body is Map && body['libraries'] is List) {
        libraries = body['libraries'] as List;
      } else if (body is List) {
        libraries = body;
      }
      
      for (final lib in libraries) {
        if (lib is Map) {
          final m = lib.cast<String, dynamic>();
          final id = (m['id'] ?? m['_id'] ?? '').toString();
          if (id == libId) {
            // Extract useful stats from library info
            return {
              'totalItems': m['stats']?['totalItems'] ?? m['numItems'] ?? 0,
              'totalSize': m['stats']?['totalSize'] ?? m['size'] ?? 0,
              'totalDuration': m['stats']?['totalDuration'] ?? m['duration'] ?? 0,
              'numAuthors': m['stats']?['numAuthors'] ?? 0,
              'numGenres': m['stats']?['numGenres'] ?? 0,
              'name': m['name'] ?? 'Unknown Library',
              'mediaType': m['mediaType'] ?? 'Unknown',
              'source': 'libraries_fallback'
            };
          }
        }
      }
      
      return <String, dynamic>{};
    } catch (e) {
      _log('[BOOKS] _getLibraryStatsFromLibrariesEndpoint error: $e');
      return <String, dynamic>{};
    }
  }

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
        // Error during sync
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

  /// Resync all book metadata from server (fetches all books sorted by addedAt to populate addedAt field)
  /// This will update all books with fresh metadata including the addedAt field
  Future<int> resyncBookMetadata({
    void Function(int page, int totalSynced)? onProgress,
  }) async {
    _log('[RESYNC_METADATA] Starting full metadata resync...');
    // Use addedAt sorting to get all books and populate the addedAt field
    final total = await syncAllBooksToDb(
      pageSize: 100,
      sort: 'addedAt&desc=1',
      query: null,
      onProgress: onProgress,
      removeDeleted: false, // Don't delete books during metadata resync
    );
    _log('[RESYNC_METADATA] Completed: synced $total books');
    // Clear cache to ensure fresh data is shown
    _clearAllCache();
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
      await db.transaction((txn) async {
        final batch = txn.batch();
        for (final id in toDelete) {
          batch.delete('books', where: 'id = ?', whereArgs: [id]);
        }
        await batch.commit(noResult: true);
      });
      _clearAllCache();
      _notifyDbChange(BookDbChangeType.delete, toDelete);
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
    
    
    final api = _auth.api;
    final toDelete = <String>[];
    int checked = 0;
    
    for (final row in localRows) {
      // Check if cancelled
      if (shouldContinue != null && !shouldContinue()) {
        // Cleanup cancelled by user
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
        } else if (resp.statusCode != 200) {
          // Other error - could be network issue, don't delete
        }
        // If 200, book exists and is fine
        
      } catch (e) {
        // Network error or other issue - don't delete, could be temporary
        // Network error checking book - keeping
      }
      
      // Small delay to avoid overwhelming the server
      if (checked % 10 == 0) {
        await Future.delayed(const Duration(milliseconds: 100));
        
        // Check cancellation after delay too
        if (shouldContinue != null && !shouldContinue()) {
          // Cleanup cancelled by user
          break;
        }
      }
    }
    
    // Remove deleted books
    if (toDelete.isNotEmpty) {
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

    Future<List<Book>> requestAndParse(String path, {Map<String, String>? extraHeaders}) async {
      final resp = await api.request('GET', path, headers: extraHeaders ?? const {});
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch: ${resp.statusCode}');
      }
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final items = _extractItems(body);
      final books = await _toBooks(items);
      await _upsertBooks(books);
      unawaited(_persistCovers(books));
      return books;
    }

    // Try offset - convert sort parameter format for API
    String sortParam;
    if (sort.contains('&desc=')) {
      sortParam = sort;
    } else if (sort == 'updatedAt:desc') {
      sortParam = 'addedAt&desc=1';
    } else {
      sortParam = sort;
    }
    final baseOffset = '/api/libraries/$libId/items?limit=$limit&offset=$offset&sort=$sortParam';
    final pathOffset = (encodedQ != null)
        ? '$baseOffset&q=$encodedQ$tokenQS'
        : '$baseOffset$tokenQS';
    try {
      final books = await requestAndParse(pathOffset);
      if (offset > 0 && await _allIdsExistInDb(books.map((b) => b.id))) {
        // Offset returned known items, trying skip
      } else {
        return books;
      }
    } catch (_) {}

    // Try skip
    final baseSkip = '/api/libraries/$libId/items?limit=$limit&skip=$offset&sort=$sortParam';
    final pathSkip = (encodedQ != null)
        ? '$baseSkip&q=$encodedQ$tokenQS'
        : '$baseSkip$tokenQS';
    try {
      final books = await requestAndParse(pathSkip);
      if (offset > 0 && await _allIdsExistInDb(books.map((b) => b.id))) {
        // Skip returned known items, falling back to page
      } else {
        return books;
      }
    } catch (_) {}

    // Fall back to page-based (API uses 1-based page indexing)
    final page = (offset ~/ limit) + 1;
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final pathPage = (encodedQ != null)
        ? '$basePage&q=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    final etagKey = _etagPrefsKey(sort, query);
    final cachedEtag = _prefs.getString(etagKey);
    final headers = <String, String>{};
    if (cachedEtag != null && page == 1) {
      headers['If-None-Match'] = cachedEtag;
    }
    List<Book> pageBooks = await requestAndParse(pathPage, extraHeaders: headers);
    // Already filtered to audiobooks inside requestAndParse
    return pageBooks;
  }

  // ---- Offline covers ----
  Future<Directory> _coversDir() async {
    final dbPath = await getDatabasesPath();
    final libId = _prefs.getString(_libIdKey) ?? 'default';
    // Use the same base root as database to avoid extra permissions
    final dir = Directory(p.join(dbPath, 'kitzi_covers', 'lib_$libId'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  Future<File> _coverFileForId(String id) async {
    final dir = await _coversDir();
    final primary = File(p.join(dir.path, '$id.jpg'));
    if (await primary.exists()) return primary;
    for (final ext in ['png', 'jpeg', 'webp', 'gif', 'img']) {
      final candidate = File(p.join(dir.path, '$id.$ext'));
      if (await candidate.exists()) {
        return candidate;
      }
    }
    return primary;
  }

  Future<void> _persistCovers(List<Book> books) async {
    if (books.isEmpty) return;
    final unique = {
      for (final b in books)
        if (b.id.isNotEmpty) b.id: b
    };
    if (unique.isEmpty) return;
    final db = _db;
    final storedUpdated = <String, int?>{};
    final storedPaths = <String, String?>{};
    if (db != null) {
      final ids = unique.keys.toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      final rows = await db.query(
        'books',
        columns: ['id', 'coverUpdatedAt', 'coverPath'],
        where: 'id IN ($placeholders)',
        whereArgs: ids,
      );
      for (final row in rows) {
        final id = row['id'] as String? ?? '';
        if (id.isEmpty) continue;
        storedUpdated[id] = row['coverUpdatedAt'] as int?;
        storedPaths[id] = row['coverPath'] as String?;
      }
    }
    final client = http.Client();
    try {
      final dir = await _coversDir();
      for (final entry in unique.entries) {
        final b = entry.value;
        final updatedAtMs = b.updatedAt?.millisecondsSinceEpoch;
        final storedCoverUpdatedAt = storedUpdated[b.id];
        final storedPath = storedPaths[b.id];
        final existingFile = storedPath != null ? File(storedPath) : null;
        final exists = existingFile != null && await existingFile.exists();
        final shouldRefresh = !exists ||
            (updatedAtMs != null &&
                (storedCoverUpdatedAt == null || updatedAtMs > storedCoverUpdatedAt));
        if (!shouldRefresh) {
          _coverRetryAttempts.remove(b.id);
          continue;
        }
        final src = await _resolveCoverUrl(b);
        if (src == null) continue;
        try {
          final resp = await client.get(Uri.parse(src));
          if (resp.statusCode != 200 || resp.bodyBytes.isEmpty) {
            throw Exception('cover status ${resp.statusCode}');
          }
          final headerExt = _extensionFromContentType(resp.headers['content-type']);
          final urlExt = _extensionFromUrl(src);
          final resolvedExt = (headerExt != 'img' ? headerExt : urlExt) ?? 'jpg';
          final safeExt = (resolvedExt.isEmpty || resolvedExt == 'img') ? 'jpg' : resolvedExt;
          final target = File(p.join(dir.path, '${b.id}.$safeExt'));
          if (await target.exists()) {
            await target.delete();
          }
          await target.writeAsBytes(resp.bodyBytes, flush: true);
          if (storedPath != null && storedPath != target.path) {
            final oldFile = File(storedPath);
            if (await oldFile.exists()) {
              await oldFile.delete();
            }
          }
          if (db != null) {
            await db.update(
              'books',
              {
                'coverPath': target.path,
                'coverUpdatedAt': updatedAtMs,
              },
              where: 'id = ?',
              whereArgs: [b.id],
            );
          }
          _coverRetryAttempts.remove(b.id);
        } catch (e) {
          _scheduleCoverRetry(b);
        }
      }
    } finally {
      client.close();
      await _enforceCoverCacheLimit();
    }
  }

  Future<String?> _resolveCoverUrl(Book book) async {
    var src = book.coverUrl;
    if (src.isEmpty) return null;
    if (!src.startsWith('file://')) {
      return src;
    }
    final baseUrl = _auth.api.baseUrl ?? '';
    if (baseUrl.isEmpty) return null;
    final token = await _auth.api.accessToken();
    src = '$baseUrl/api/items/${book.id}/cover';
    if (token != null && token.isNotEmpty) src = '$src?token=$token';
    return src;
  }

  void _scheduleCoverRetry(Book book) {
    final nextAttempt = (_coverRetryAttempts[book.id] ?? 0) + 1;
    if (nextAttempt > 3) {
      _coverRetryAttempts.remove(book.id);
      return;
    }
    _coverRetryAttempts[book.id] = nextAttempt;
    _coverRetryQueue.removeWhere((b) => b.id == book.id);
    _coverRetryQueue.add(book);
    _coverRetryTimer ??=
        Timer(const Duration(seconds: 45), () => _flushCoverRetryQueue());
  }

  Future<void> _flushCoverRetryQueue() async {
    _coverRetryTimer?.cancel();
    _coverRetryTimer = null;
    if (_coverRetryQueue.isEmpty) return;
    final tasks = _coverRetryQueue.toList();
    _coverRetryQueue.clear();
    await _persistCovers(tasks);
  }

  Future<void> _enforceCoverCacheLimit({
    int maxBytes = 200 * 1024 * 1024,
    int maxFiles = 2000,
  }) async {
    final dir = await _coversDir();
    if (!await dir.exists()) return;
    final files = <File>[];
    await for (final entity in dir.list()) {
      if (entity is File) {
        files.add(entity);
      }
    }
    if (files.isEmpty) return;
    files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
    final lengths = <File, int>{};
    var totalBytes = 0;
    for (final file in files) {
      final len = await file.length();
      lengths[file] = len;
      totalBytes += len;
    }
    var remainingFiles = files.length;
    if (totalBytes <= maxBytes && remainingFiles <= maxFiles) return;
    for (final file in files) {
      if (totalBytes <= maxBytes && remainingFiles <= maxFiles) break;
      final length = lengths[file] ?? await file.length();
      await file.delete();
      totalBytes -= length;
      remainingFiles -= 1;
      final baseName = p.basenameWithoutExtension(file.path);
      if (_db != null) {
        await _db!.update(
          'books',
          {'coverPath': null},
          where: 'id = ? AND coverPath = ?',
          whereArgs: [baseName, file.path],
        );
      }
    }
  }

  /// Search for all books by a specific author
  Future<List<Book>> searchBooksByAuthor(String authorName) async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return <Book>[];
    
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();

    // Search for books where the author field matches (case insensitive)
    final rows = await db.query(
      'books',
      where: 'LOWER(author) LIKE ?',
      whereArgs: ['%${authorName.toLowerCase()}%'],
      orderBy: 'title COLLATE NOCASE ASC',
    );

    if (rows.isEmpty) return <Book>[];

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

  /// Get all unique authors with their books
  Future<List<AuthorInfo>> getAllAuthors() async {
    await _ensureDbForCurrentLib();
    final db = _db;
    if (db == null) return <AuthorInfo>[];
    
    final baseUrl = _auth.api.baseUrl ?? '';
    final token = await _auth.api.accessToken();

    // Get all unique authors with their book counts
    final rows = await db.rawQuery('''
      SELECT author, COUNT(*) as book_count
      FROM books 
      WHERE author IS NOT NULL AND author != ''
      GROUP BY author
      ORDER BY author COLLATE NOCASE ASC
    ''');

    if (rows.isEmpty) return <AuthorInfo>[];

    final authors = <AuthorInfo>[];
    for (final row in rows) {
      final authorName = row['author'] as String;
      
      // Get all books for this author
      final bookRows = await db.query(
        'books',
        where: 'author = ?',
        whereArgs: [authorName],
        orderBy: 'title COLLATE NOCASE ASC',
      );

      final books = bookRows.map((m) {
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

      authors.add(AuthorInfo(name: authorName, books: books));
    }

    return authors;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _coverRetryTimer?.cancel();
    _coverRetryQueue.clear();
    _coverRetryAttempts.clear();
    try {
      await _db?.close();
    } catch (_) {}
    _db = null;
  }
}

class AuthorInfo {
  final String name;
  final List<Book> books;
  final int bookCount;

  AuthorInfo({
    required this.name,
    required this.books,
  }) : bookCount = books.length;
}

enum BookDbChangeType { upsert, delete }

class BookDbChange {
  const BookDbChange({required this.type, required this.ids});
  final BookDbChangeType type;
  final Set<String> ids;
}
