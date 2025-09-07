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

    // Clear DB contents even if another connection is open
    try {
      final dbPath = await getDatabasesPath();
      final path = p.join(dbPath, 'kitzi_books.db');
      final db = await openDatabase(path);
      await db.execute('DELETE FROM books');
      await db.close();
    } catch (_) {}

    try {
      // Delete DB file (best effort; may fail if another connection is open)
      final dbPath = await getDatabasesPath();
      final dbFile = p.join(dbPath, 'kitzi_books.db');
      await deleteDatabase(dbFile);
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
    final rows = await db.query('books', orderBy: 'updatedAt IS NULL, updatedAt DESC');
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
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;
    final path = '/api/libraries/$libId/items?limit=50&sort=updatedAt:desc$tokenQS';
    final bool localEmpty = await _isDbEmpty();
    http.Response resp = await api.request('GET', path, headers: headers);

    if (resp.statusCode == 304) {
      // Force a network fetch without ETag to get fresh data
      resp = await api.request('GET', path, headers: {});
    }

    if (resp.statusCode == 200) {
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final newEtag = resp.headers['etag'];
      await _prefs.setString(_cacheKey, bodyStr);
      if (newEtag != null) await _prefs.setString(_etagKey, newEtag);

      final items = _extractItems(body);
      final books = await _toBooks(items);
      // Write DB immediately so UI can render without delay
      await _upsertBooks(books);
      // Do not prefetch covers here; allow UI to load covers on-demand
      return await _listBooksFromDb();
    }
    // On error, return local DB
    return await _listBooksFromDb();
  }

  /// Fetch one page of books from server, persist to DB, and return the page
  Future<List<Book>> fetchBooksPage({required int page, int limit = 50, String sort = 'updatedAt:desc', String? query}) async {
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final encodedQ = (query != null && query.trim().isNotEmpty)
        ? Uri.encodeQueryComponent(query.trim())
        : null;

    Future<List<Book>> requestAndParse(String path) async {
      final resp = await api.request('GET', path, headers: {});
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch: ${resp.statusCode}');
      }
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final items = _extractItems(body);
      final books = await _toBooks(items);
      return books;
    }

    // 1) Try page-based
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final pathPage = (encodedQ != null)
        ? '$basePage&search=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    List<Book> books = await requestAndParse(pathPage).catchError((e) async {
      if (encodedQ != null) {
        final alt = '$basePage&q=$encodedQ$tokenQS';
        return requestAndParse(alt);
      }
      return Future.error(e);
    });

    // If page > 1 and all IDs already exist (server ignored page), try offset
    if (page > 1 && await _allIdsExistInDb(books.map((b) => b.id))) {
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
    return books;
  }

  /// Perform a full-library sync into the local database by iterating pages
  /// until exhaustion. Returns the total number of items synced. Optionally
  /// reports progress via [onProgress] with (currentPage, totalSynced).
  Future<int> syncAllBooksToDb({
    int pageSize = 100,
    String sort = 'updatedAt:desc',
    String? query,
    void Function(int page, int totalSynced)? onProgress,
  }) async {
    int total = 0;
    int offset = 0;
    int page = 1;
    final Set<String> seenIds = <String>{};
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
        break;
      }
      if (chunk.isEmpty) break;
      final ids = chunk.map((b) => b.id).where((id) => id.isNotEmpty).toSet();
      final before = seenIds.length;
      seenIds.addAll(ids);
      final added = seenIds.length - before;
      total += added;
      if (added == 0) {
        noProgressStreak += 1;
      } else {
        noProgressStreak = 0;
      }
      if (noProgressStreak >= 2) break;
      if (onProgress != null) onProgress(page, total);
      if (chunk.length < pageSize) break;
      offset += pageSize;
      page += 1;
    }
    return total;
  }

  Future<bool> _isDbEmpty() async {
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
      final resp = await api.request('GET', path, headers: {});
      if (resp.statusCode != 200) {
        throw Exception('Failed to fetch: ${resp.statusCode}');
      }
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
      final items = _extractItems(body);
      final books = await _toBooks(items);
      await _upsertBooks(books);
      return books;
    }

    // Try offset
    final baseOffset = '/api/libraries/$libId/items?limit=$limit&offset=$offset&sort=$sort';
    final pathOffset = (encodedQ != null)
        ? '$baseOffset&search=$encodedQ$tokenQS'
        : '$baseOffset$tokenQS';
    try {
      return await requestAndParse(pathOffset);
    } catch (_) {}

    // Try skip
    final baseSkip = '/api/libraries/$libId/items?limit=$limit&skip=$offset&sort=$sort';
    final pathSkip = (encodedQ != null)
        ? '$baseSkip&search=$encodedQ$tokenQS'
        : '$baseSkip$tokenQS';
    try {
      return await requestAndParse(pathSkip);
    } catch (_) {}

    // Fall back to page-based
    final page = (offset ~/ limit) + 1;
    final basePage = '/api/libraries/$libId/items?limit=$limit&page=$page&sort=$sort';
    final pathPage = (encodedQ != null)
        ? '$basePage&search=$encodedQ$tokenQS'
        : '$basePage$tokenQS';
    return await requestAndParse(pathPage);
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
