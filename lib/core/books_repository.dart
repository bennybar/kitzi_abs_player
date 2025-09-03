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
    final cached = _prefs.getString(_libIdKey);
    if (cached != null && cached.isNotEmpty) return cached;

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
    if (id.isEmpty) throw Exception('Invalid library id from /api/libraries');

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
    // Always prefer local DB first and do not hit network on app start when DB has data
    final local = await _listBooksFromDb();
    if (local.isNotEmpty) {
      // Best-effort: ensure covers exist locally in background
      // without blocking UI. Missing covers will be fetched once.
      // This avoids network list fetches at startup.
      unawaited(_persistCovers(local));
      return local;
    }

    // If DB empty, do an initial network fetch and persist
    final fetched = await refreshFromServer();
    return fetched;
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

  /// Explicit refresh from server; persists to DB and cache, returns fresh list
  Future<List<Book>> refreshFromServer() async {
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();

    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;

    final path = '/api/libraries/$libId/items?limit=200&sort=updatedAt:desc$tokenQS';
    final bool localEmpty = await _isDbEmpty();
    http.Response resp = await api.request('GET', path, headers: headers);

    if (resp.statusCode == 304) {
      // If DB has data, return it; otherwise attempt to use cache or force fetch
      if (!localEmpty) {
        return await _listBooksFromDb();
      }
      // Try cache
      final cached = _prefs.getString(_cacheKey);
      if (cached != null && cached.isNotEmpty) {
        try {
          final body = jsonDecode(cached);
          final items = _extractItems(body);
          final books = await _toBooks(items);
          await _upsertBooks(books);
          return await _listBooksFromDb();
        } catch (_) {}
      }
      // Force a network fetch without ETag since local is empty
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
      // Persist covers in background, then update DB with coverPath when done
      unawaited(_persistCovers(books).then((_) => _upsertBooks(books)));
      return await _listBooksFromDb();
    }

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
