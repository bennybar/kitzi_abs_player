import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/book.dart';
import 'auth_repository.dart';

class BooksRepository {
  BooksRepository(this._auth, this._prefs);
  final AuthRepository _auth;
  final SharedPreferences _prefs;

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
    final api = _auth.api;
    final token = await api.accessToken();
    final libId = await _ensureLibraryId();

    // Auth via query (robust for GET on some deployments)
    final tokenQS = (token != null && token.isNotEmpty) ? '&token=$token' : '';
    final etag = _prefs.getString(_etagKey);
    final headers = <String, String>{};
    if (etag != null) headers['If-None-Match'] = etag;

    final path =
        '/api/libraries/$libId/items?limit=200&sort=updatedAt:desc$tokenQS';

    final http.Response resp = await api.request('GET', path, headers: headers);

    if (resp.statusCode == 304) {
      final cached = _prefs.getString(_cacheKey);
      if (cached != null) {
        final data = jsonDecode(cached);
        final items = _extractItems(data);
        return _toBooks(items);
      }
      return <Book>[];
    }

    if (resp.statusCode == 200) {
      final bodyStr = resp.body;
      final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;

      final newEtag = resp.headers['etag'];
      await _prefs.setString(_cacheKey, bodyStr);
      if (newEtag != null) await _prefs.setString(_etagKey, newEtag);

      final items = _extractItems(body);
      if (items.isEmpty && bodyStr.isNotEmpty) {
        final preview = bodyStr.substring(0, bodyStr.length.clamp(0, 300));
        throw Exception('Library returned no parseable items. Body preview: $preview');
      }
      return _toBooks(items);
    }

    // Fallback to cache on errors
    final cached = _prefs.getString(_cacheKey);
    if (cached != null) {
      final data = jsonDecode(cached);
      final items = _extractItems(data);
      return _toBooks(items);
    }

    throw Exception('Failed to load books: ${resp.statusCode}');
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
    return BooksRepository(auth, prefs);
  }
}
