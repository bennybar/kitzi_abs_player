// lib/core/play_history_service.dart
import 'dart:convert';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

import '../models/book.dart';
import 'auth_repository.dart';

class PlayHistoryService {
  static const String _playHistoryKey = 'play_history_v1';
  static const int _maxHistorySize = 10; // Keep last 10 for potential future use
  static const String _libIdKey = 'books_library_id';

  static Future<String> _ensureLibraryId() async {
    final prefs = await SharedPreferences.getInstance();
    final cached = prefs.getString(_libIdKey);
    if (cached != null && cached.isNotEmpty) return cached;

    final auth = await AuthRepository.ensure();
    final api = auth.api;
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
    if (libs.isEmpty) throw Exception('No libraries accessible');
    Map<String, dynamic>? chosen;
    for (final l in libs) {
      final m = (l as Map).cast<String, dynamic>();
      final mt = (m['mediaType'] ?? m['type'] ?? '').toString().toLowerCase();
      if (mt.contains('book')) {
        chosen = m; break;
      }
    }
    chosen ??= (libs.first as Map).cast<String, dynamic>();
    final id = (chosen['id'] ?? chosen['_id'] ?? '').toString();
    if (id.isEmpty) throw Exception('Invalid library id');
    await prefs.setString(_libIdKey, id);
    return id;
  }
  
  /// Add a book to play history (most recent first)
  static Future<void> addToHistory(Book book) async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getStringList(_playHistoryKey) ?? [];
    
    // Remove if already exists (to avoid duplicates)
    historyJson.removeWhere((item) {
      final data = jsonDecode(item);
      return data['id'] == book.id;
    });
    
    // Add to beginning
    final bookData = {
      'id': book.id,
      'title': book.title,
      'author': book.author,
      'coverUrl': book.coverUrl,
      'libraryId': book.libraryId, // Include library ID for filtering
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    
    historyJson.insert(0, jsonEncode(bookData));
    
    // Keep only the most recent items
    if (historyJson.length > _maxHistorySize) {
      historyJson.removeRange(_maxHistorySize, historyJson.length);
    }
    
    await prefs.setStringList(_playHistoryKey, historyJson);
  }
  
  /// Get the last N played books (most recent first)
  /// Server-priority: tries server personalized view first, then local
  static Future<List<Book>> getLastPlayedBooks(int count) async {
    try {
      print('PlayHistory: Trying server personalized view first...');
      try {
        final serverBooks = await _getLastPlayedBooksFromServer(count);
        if (serverBooks.isNotEmpty) {
          print('PlayHistory: Got ${serverBooks.length} recent played from server');
          return serverBooks;
        }
        print('PlayHistory: Server returned no recent played; falling back to local');
      } catch (e) {
        print('PlayHistory: Server request failed: $e');
      }
      print('PlayHistory: Checking local play history...');
      final localBooks = await _getLastPlayedBooksFromLocal(count);
      if (localBooks.isNotEmpty) return localBooks;
      return [];
    } catch (e) {
      print('PlayHistory: Critical error in getLastPlayedBooks: $e');
      return [];
    }
  }
  
  /// Get recent books from server
  static Future<List<Book>> _getLastPlayedBooksFromServer(int count) async {
    try {
      // Get auth repository to access server
      print('PlayHistory: Getting auth repository...');
      final auth = await AuthRepository.ensure();
      final api = auth.api;
      
      print('PlayHistory: Getting access token...');
      final token = await api.accessToken();
      final baseUrl = api.baseUrl;
      
      print('PlayHistory: Token: ${token != null ? 'present' : 'null'}, BaseUrl: $baseUrl');
      
      if (token == null || token.isEmpty || baseUrl == null || baseUrl.isEmpty) {
        print('PlayHistory: Missing auth credentials, skipping server request');
        return [];
      }
      // Determine library id
      final libId = await _ensureLibraryId();
      
      // Preferred order:
      // 1) Me -> user.mediaProgress (true latest played)
      // 2) Personalized continue section
      // 3) Library in-progress include progress
      final meUrl = '$baseUrl/api/me?token=$token';
      final personalizedUrl = '$baseUrl/api/libraries/$libId/personalized?view=continue&limit=${count * 3}&token=$token';
      final libraryInProgressUrl = '$baseUrl/api/libraries/$libId/items?inProgress=true&include=progress&limit=${count * 3}&token=$token';

      Future<http.Response> doGet(String u) => http.get(
        Uri.parse(u),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          print('PlayHistory: Server request timed out after 10 seconds');
          throw TimeoutException('Server request timed out');
        },
      );

      // ---- 1) Me.mediaProgress path ----
      print('PlayHistory: Requesting Me: $meUrl');
      var resp = await doGet(meUrl);
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        final user = (data is Map) ? data as Map<String, dynamic> : const <String, dynamic>{};
        final mp = user['mediaProgress'];
        if (mp is List) {
          // Filter to books (episodeId == null) and items in this library (if provided on entry)
          final entries = <Map<String, dynamic>>[];
          for (final e in mp) {
            if (e is Map) {
              final m = e.cast<String, dynamic>();
              final episodeId = m['episodeId'];
              final li = m['libraryItemId'];
              final isFinished = m['isFinished'] == true;
              final progress = m['progress'] is num ? (m['progress'] as num).toDouble() : null;
              
              // Only include books (not episodes) that are not completed
              if (episodeId == null && li is String && li.isNotEmpty && !isFinished) {
                // Also exclude books that are 99%+ complete
                if (progress == null || progress < 0.99) {
                  entries.add(m);
                }
              }
            }
          }
          // Sort by lastUpdate desc
          entries.sort((a, b) {
            final ai = (a['lastUpdate'] is num) ? (a['lastUpdate'] as num).toInt() : int.tryParse('${a['lastUpdate']}') ?? 0;
            final bi = (b['lastUpdate'] is num) ? (b['lastUpdate'] as num).toInt() : int.tryParse('${b['lastUpdate']}') ?? 0;
            return bi.compareTo(ai);
          });
          final top = entries.take(count).toList();
          print('PlayHistory: Me.mediaProgress top=${top.length}');

          // Fetch each library item by id
          final books = <Book>[];
          for (final m in top) {
            final id = m['libraryItemId']?.toString();
            if (id == null || id.isEmpty) continue;
            final itemUrl = '$baseUrl/api/items/$id?token=$token';
            try {
              final itemResp = await doGet(itemUrl);
              if (itemResp.statusCode == 200) {
                final bd = jsonDecode(itemResp.body);
                Map<String, dynamic>? li;
                if (bd is Map && bd['item'] is Map) {
                  li = (bd['item'] as Map).cast<String, dynamic>();
                } else if (bd is Map) {
                  li = bd.cast<String, dynamic>();
                }
                if (li != null) {
                  // Only include books from the current library
                  final bookLibraryId = (li['libraryId'] ?? '').toString();
                  if (bookLibraryId == libId) {
                    final book = Book.fromLibraryItemJson(li, baseUrl: baseUrl, token: token);
                    books.add(book);
                  }
                }
              }
            } catch (_) {}
          }
          if (books.isNotEmpty) {
            print('PlayHistory: Returning ${books.length} from Me.mediaProgress');
            return books;
          }
        }
      } else {
        print('PlayHistory: Me endpoint failed status=${resp.statusCode}');
      }

      // ---- 2) Personalized continue ----
      print('PlayHistory: Requesting personalized continue: $personalizedUrl');
      resp = await doGet(personalizedUrl);
      List<dynamic> items = [];
      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body);
        List<dynamic> sections;
        if (data is Map && data['results'] is List) {
          sections = data['results'] as List;
        } else if (data is List) {
          sections = data;
        } else {
          sections = const [];
        }
        Map<String, dynamic>? continueSection;
        for (final s in sections) {
          if (s is Map) {
            final slug = (s['slug'] ?? s['id'] ?? s['name'] ?? '').toString().toLowerCase();
            if (slug.contains('continue')) { continueSection = s.cast<String, dynamic>(); break; }
            if (slug.contains('continue-listening')) { continueSection = s.cast<String, dynamic>(); break; }
          }
        }
        if (continueSection != null && continueSection['items'] is List) {
          items = (continueSection['items'] as List);
          print('PlayHistory: Using personalized continue section items=${items.length}');
        }
      }

      if (items.isEmpty) {
        // ---- 3) Library in-progress include progress ----
        print('PlayHistory: Falling back to library in-progress: $libraryInProgressUrl');
        resp = await doGet(libraryInProgressUrl);
        if (resp.statusCode == 200) {
          final fb = jsonDecode(resp.body);
          if (fb is Map && fb['results'] is List) {
            items = fb['results'] as List;
          } else if (fb is List) items = fb;
        }
      }

      if (items.isEmpty) return [];

      Map<String, dynamic>? asLibraryItem(dynamic entry) {
        if (entry is Map<String, dynamic>) {
          if (entry['libraryItem'] is Map) {
            return (entry['libraryItem'] as Map).cast<String, dynamic>();
          }
          if (entry.containsKey('media') || entry.containsKey('libraryId')) {
            return entry.cast<String, dynamic>();
          }
        }
        return null;
      }

      // Flatten nested section entries and normalize
      final flat = <dynamic>[];
      for (final e in items) {
        if (e is Map && e['items'] is List) {
          flat.addAll((e['items'] as List));
        } else {
          flat.add(e);
        }
      }

      final normalized = <Map<String, dynamic>>[];
      for (final e in flat) {
        final li = asLibraryItem(e);
        if (li == null) continue;
        final id = (li['id'] ?? li['_id'] ?? '').toString();
        if (id.isEmpty) continue;
        normalized.add(li);
      }

      int toIntTs(dynamic v) {
        if (v is String) return int.tryParse(v) ?? 0;
        if (v is num) return v.toInt();
        return 0;
      }
      int bestTs(Map<String, dynamic> m) {
        final mp = (m['mediaProgress'] is Map) ? (m['mediaProgress'] as Map)['lastUpdate'] : (m['progress'] is Map) ? (m['progress'] as Map)['lastUpdate'] : null;
        final bip = m['bookInProgressLastUpdate'];
        final lpa = m['lastPlayedAt'];
        final upd = m['updatedAt'];
        final cands = [mp, bip, lpa, upd].map(toIntTs).toList();
        return cands.fold<int>(0, (p, e) => e > p ? e : p);
      }

      print('PlayHistory: candidates=${normalized.length}');
      for (int i = 0; i < normalized.length; i++) {
        final n = normalized[i];
        final title = (n['title'] ?? n['media']?['metadata']?['title'] ?? 'Unknown').toString();
        final mp = (n['mediaProgress'] is Map) ? (n['mediaProgress'] as Map)['lastUpdate'] : (n['progress'] is Map) ? (n['progress'] as Map)['lastUpdate'] : null;
        final bip = n['bookInProgressLastUpdate'];
        final lpa = n['lastPlayedAt'];
        final upd = n['updatedAt'];
        print('PlayHistory: Candidate[$i] "$title" mp=$mp bip=$bip lpa=$lpa upd=$upd');
      }

      normalized.sort((a, b) => bestTs(b).compareTo(bestTs(a)));
      final trimmed = normalized.take(count).toList();

      print('PlayHistory: Ordered preview:');
      for (int i = 0; i < trimmed.length; i++) {
        final n = trimmed[i];
        final title = (n['title'] ?? n['media']?['metadata']?['title'] ?? 'Unknown').toString();
        print('PlayHistory: Ordered[$i] "$title" ts=${bestTs(n)}');
      }

      final books = <Book>[];
      for (final item in trimmed) {
        try {
          // Check if book is from the current library
          final bookLibraryId = (item['libraryId'] ?? '').toString();
          if (bookLibraryId != libId) continue;
          
          // Check if book is completed
          final isFinished = item['isFinished'] == true;
          final progress = item['progress'] is num ? (item['progress'] as num).toDouble() : null;
          if (isFinished || (progress != null && progress >= 0.99)) continue;
          
          final book = Book.fromLibraryItemJson(
            item,
            baseUrl: baseUrl,
            token: token,
          );
          books.add(book);
        } catch (e) {
          print('PlayHistory: Failed to parse book item: $e');
          continue;
        }
      }

      print('PlayHistory: Returning ${books.length} books');
      return books;
    } catch (e) {
      print('PlayHistory: Error fetching recent books from server: $e');
    }
    
    return [];
  }
  
  /// Get recent books from local database
  static Future<List<Book>> _getLastPlayedBooksFromLocal(int count) async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getStringList(_playHistoryKey) ?? [];
    
    print('PlayHistory: Local history contains ${historyJson.length} entries');
    
    // Get current library ID for filtering
    final libId = await _ensureLibraryId();
    
    final books = <Book>[];
    for (int i = 0; i < historyJson.length && i < count; i++) {
      try {
        final data = jsonDecode(historyJson[i]);
        final book = Book(
          id: data['id'],
          title: data['title'],
          author: data['author'],
          coverUrl: data['coverUrl'] ?? '',
          description: null,
          durationMs: null,
          sizeBytes: null,
          libraryId: data['libraryId'], // Include library ID if available
        );
        
        // Only include books from the current library if library ID is available
        if (book.libraryId == null || book.libraryId == libId) {
          books.add(book);
          print('PlayHistory: Local book $i: ${book.title}');
        } else {
          print('PlayHistory: Skipping local book $i (${book.title}) - different library');
        }
      } catch (e) {
        print('PlayHistory: Failed to parse local book $i: $e');
        // Skip corrupted entries
        continue;
      }
    }
    
    print('PlayHistory: Successfully loaded ${books.length} books from local history');
    return books;
  }
  
  /// Clear play history
  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_playHistoryKey);
  }
  
  /// Remove a specific book from history
  static Future<void> removeFromHistory(String bookId) async {
    final prefs = await SharedPreferences.getInstance();
    final historyJson = prefs.getStringList(_playHistoryKey) ?? [];
    
    historyJson.removeWhere((item) {
      try {
        final data = jsonDecode(item);
        return data['id'] == bookId;
      } catch (e) {
        return false;
      }
    });
    
    await prefs.setStringList(_playHistoryKey, historyJson);
  }
}
