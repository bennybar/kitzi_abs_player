import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'dart:convert' show utf8;
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
      // Try to fetch first page from server for bandwidth efficiency
      print('BooksRepository: Attempting to fetch first page from server...');
      final fetched = await fetchBooksPage(page: 1, limit: 50);
      print('BooksRepository: Successfully fetched ${fetched.length} books from server (page 1)');
      return fetched;
    } catch (e) {
      print('BooksRepository: Server fetch failed: $e');
      print('BooksRepository: Falling back to local database...');
      
      // Fallback to local DB if server fails
      final local = await _listBooksFromDb();
      print('BooksRepository: Retrieved ${local.length} books from local database');
      
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

    final b = Book.fromLibraryItemJson(item, baseUrl: baseUrl, token: token);
    // Persist to DB for offline access
    await _upsertBooks([b]);
    // Best-effort: cache description images in background
    unawaited(_persistDescriptionImages(b));
    return b;
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
    try {
      // Delete DB file
      final dbPath = await getDatabasesPath();
      final dbFile = p.join(dbPath, 'kitzi_books.db');
      final f = File(dbFile);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}

    try {
      // Delete covers directory
      final dbPath = await getDatabasesPath();
      final coversDir = Directory(p.join(dbPath, 'kitzi_covers'));
      if (await coversDir.exists()) {
        await coversDir.delete(recursive: true);
      }
    } catch (_) {}

    try {
      // Delete description images directory tree
      final dbPath = await getDatabasesPath();
      final descDir = Directory(p.join(dbPath, 'kitzi_desc_images'));
      if (await descDir.exists()) {
        await descDir.delete(recursive: true);
      }
    } catch (_) {}
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

  /// Paged local query of books from the on-device DB with optional search and sort.
  Future<List<Book>> listBooksFromDbPaged({
    required int page,
    int limit = 50,
    String sort = 'updatedAt:desc',
    String? query,
  }) async {
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
    final where = whereParts.isEmpty ? null : whereParts.join(' AND ');

    String orderBy;
    switch (sort) {
      case 'nameAsc':
        orderBy = 'title COLLATE NOCASE ASC';
        break;
      case 'updatedAt:desc':
      default:
        orderBy = 'updatedAt DESC NULLS LAST';
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
    if (rows.isEmpty) return <Book>[];
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

  Future<int> countBooksInDb({String? query}) async {
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
    );
  }

  /// Upsert a single book into the local DB (convenience)
  Future<void> upsertBook(Book b) async {
    await _upsertBooks([b]);
  }

  // ================== Description images caching ==================
  Future<Directory> _descImagesDirFor(String bookId) async {
    final dbPath = await getDatabasesPath();
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', bookId));
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
    final dir = Directory(p.join(dbPath, 'kitzi_desc_images', bookId));
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

    final path = '/api/libraries/$libId/items?limit=50&sort=updatedAt:desc$tokenQS';
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
      
      // Do not prefetch covers here; allow UI to load covers on-demand
      return await _listBooksFromDb();
    }

    print('BooksRepository: Server request failed, falling back to local DB');
    // On error, return local DB
    return await _listBooksFromDb();
  }

  /// Fetch one page of books from server, persist to DB, and return the page
  Future<List<Book>> fetchBooksPage({required int page, int limit = 50, String sort = 'updatedAt:desc', String? query}) async {
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final base = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final encodedQ = (query != null && query.trim().isNotEmpty)
        ? Uri.encodeQueryComponent(query.trim())
        : null;

    http.Response resp;
    // Try with 'search' parameter first
    String path = (encodedQ != null)
        ? '$base&search=$encodedQ$tokenQS'
        : '$base$tokenQS';
    print('BooksRepository: fetchBooksPage path: $path');
    resp = await api.request('GET', path, headers: {});

    // If server doesn't support 'search', try 'q'
    if (resp.statusCode != 200 && encodedQ != null) {
      final alt = '$base&q=$encodedQ$tokenQS';
      print('BooksRepository: retrying with q param: $alt');
      resp = await api.request('GET', alt, headers: {});
    }

    // As a last resort, drop the query
    if (resp.statusCode != 200) {
      final fallback = '$base$tokenQS';
      print('BooksRepository: fallback without query: $fallback');
      resp = await api.request('GET', fallback, headers: {});
    }

    if (resp.statusCode != 200) {
      throw Exception('Failed to fetch page $page: ${resp.statusCode}');
    }
    final bodyStr = resp.body;
    final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
    final items = _extractItems(body);
    final books = await _toBooks(items);
    await _upsertBooks(books);
    return books;
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
