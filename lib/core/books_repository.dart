import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import '../models/book.dart';
import 'auth_repository.dart';

class BooksRepository {
  BooksRepository(this._auth, this._prefs);
  final AuthRepository _auth;
  final SharedPreferences _prefs;
  Database? _db;

  static const _etagKey = 'books_list_etag';
  static const _cacheKey = 'books_list_cache_json';
  static const _libIdKey = 'books_library_id';

  Future<String> _ensureLibraryId() async {
    print('BooksRepository: _ensureLibraryId() called');
    
    final cached = _prefs.getString(_libIdKey);
    if (cached != null && cached.isNotEmpty) {
      print('BooksRepository: Using cached library ID: $cached');
      return cached;
    }

    print('BooksRepository: No cached library ID, fetching from server...');
    final api = _auth.api;
    final token = await api.accessToken();
    final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
    final resp = await api.request('GET', '/api/libraries$tokenQS');

    print('BooksRepository: Libraries API response status: ${resp.statusCode}');
    if (resp.statusCode != 200) {
      print('BooksRepository: Failed to list libraries: ${resp.statusCode}');
      throw Exception('Failed to list libraries: ${resp.statusCode}');
    }

    final bodyStr = resp.body;
    final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;

    final libs = (body is Map && body['libraries'] is List)
        ? (body['libraries'] as List)
        : (body is List ? body : const []);

    print('BooksRepository: Found ${libs.length} libraries');

    if (libs.isEmpty) {
      print('BooksRepository: No libraries accessible for this user');
      throw Exception('No libraries accessible for this user');
    }

    Map<String, dynamic>? chosen;
    for (final l in libs) {
      final m = (l as Map).cast<String, dynamic>();
      final mt = (m['mediaType'] ?? m['type'] ?? '').toString().toLowerCase();
      if (mt.contains('book')) {
        chosen = m;
        print('BooksRepository: Selected book library: ${m['name'] ?? 'unnamed'} (ID: ${m['id'] ?? m['_id']})');
        break;
      }
    }
    chosen ??= (libs.first as Map).cast<String, dynamic>();

    final id = (chosen['id'] ?? chosen['_id'] ?? '').toString();
    if (id.isEmpty) {
      print('BooksRepository: Invalid library id from /api/libraries');
      throw Exception('Invalid library id from /api/libraries');
    }

    print('BooksRepository: Setting library ID: $id');

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
    print('BooksRepository: listBooks() called - checking server first');
    
    try {
      // Always try to get fresh data from server first
      print('BooksRepository: Attempting to fetch fresh data from server...');
      final fetched = await refreshFromServer();
      print('BooksRepository: Successfully fetched ${fetched.length} books from server');
      return fetched;
    } catch (e) {
      print('BooksRepository: Server fetch failed: $e');
      print('BooksRepository: Falling back to local database...');
      
      // Fallback to local DB if server fails
      final local = await _listBooksFromDb();
      print('BooksRepository: Retrieved ${local.length} books from local database');
      
      // Best-effort: ensure covers exist locally in background
      // without blocking UI. Missing covers will be fetched once.
      unawaited(_persistCovers(local));
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

    return Book.fromLibraryItemJson(item, baseUrl: baseUrl, token: token);
  }

  static Future<BooksRepository> create() async {
    final auth = await AuthRepository.ensure();
    final prefs = await SharedPreferences.getInstance();
    final repo = BooksRepository(auth, prefs);
    await repo._openDb();
    return repo;
  }

  Future<void> _openDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, 'kitzi_books.db');
    _db = await openDatabase(
      path,
      version: 1,
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
            updatedAt INTEGER
          )
        ''');
      },
    );

    // Best-effort migration for existing installs
    try {
      await _db!.execute('ALTER TABLE books ADD COLUMN coverPath TEXT');
    } catch (_) {
      // ignore duplicate column errors
    }
  }

  Future<void> _upsertBooks(List<Book> items) async {
    final db = _db;
    if (db == null) return;
    final batch = db.batch();
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
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
    await batch.commit(noResult: true);
  }

  Future<List<Book>> _listBooksFromDb() async {
    final db = _db;
    if (db == null) return <Book>[];
    final rows = await db.query('books', orderBy: 'updatedAt DESC NULLS LAST');
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
      );
    }).toList();
  }

  /// Clear ETag cache to force fresh data on next request
  Future<void> _clearEtagCache() async {
    print('BooksRepository: Clearing ETag cache to force fresh data');
    await _prefs.remove(_etagKey);
    await _prefs.remove(_cacheKey);
  }

  /// Explicit refresh from server; persists to DB and cache, returns fresh list
  Future<List<Book>> refreshFromServer() async {
    print('BooksRepository: refreshFromServer() called');
    
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    
    print('BooksRepository: Library ID: $libId, Token present: ${token != null && token.isNotEmpty}');

    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;

    final path = '/api/libraries/$libId/items?limit=200&sort=updatedAt:desc$tokenQS';
    print('BooksRepository: Requesting from path: $path');
    
    final bool localEmpty = await _isDbEmpty();
    print('BooksRepository: Local DB empty: $localEmpty');
    
    http.Response resp = await api.request('GET', path, headers: headers);
    print('BooksRepository: Server response status: ${resp.statusCode}');

    if (resp.statusCode == 304) {
      print('BooksRepository: Server returned 304 (Not Modified)');
      print('BooksRepository: WARNING: 304 response detected - this might indicate stale ETag');
      print('BooksRepository: Forcing fresh data fetch to ensure we have the latest books');
      
      // Force a network fetch without ETag to get fresh data
      // This ensures we always get the latest book list, even if ETag is stale
      print('BooksRepository: Forcing network fetch without ETag');
      resp = await api.request('GET', path, headers: {});
      print('BooksRepository: Force fetch response status: ${resp.statusCode}');
    }

    if (resp.statusCode == 200) {
      print('BooksRepository: Processing successful response');
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final newEtag = resp.headers['etag'];
      await _prefs.setString(_cacheKey, bodyStr);
      if (newEtag != null) await _prefs.setString(_etagKey, newEtag);

      final items = _extractItems(body);
      print('BooksRepository: Extracted ${items.length} items from response');
      final books = await _toBooks(items);
      print('BooksRepository: Converted to ${books.length} Book objects');
      
      // Write DB immediately so UI can render without delay
      await _upsertBooks(books);
      print('BooksRepository: Books persisted to database');
      
      // Persist covers in background, then update DB with coverPath when done
      unawaited(_persistCovers(books).then((_) => _upsertBooks(books)));
      return await _listBooksFromDb();
    }

    print('BooksRepository: Server request failed, falling back to local DB');
    // On error, return local DB
    return await _listBooksFromDb();
  }

  Future<bool> _isDbEmpty() async {
    final db = _db;
    if (db == null) return true;
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM books')) ?? 0;
    return count == 0;
  }

  // ---- Offline covers ----
  Future<Directory> _coversDir() async {
    final dbPath = await getDatabasesPath();
    // Use the same base root as database to avoid extra permissions
    final dir = Directory(p.join(dbPath, 'kitzi_covers'));
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
