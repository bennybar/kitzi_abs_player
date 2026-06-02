import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// A cached Audible community rating for a book.
class AudibleRating {
  final double rating; // 0..5 average
  final int? count; // number of ratings
  final String? asin; // resolved ASIN (cached for future exact lookups)
  final int tsMs; // last refresh time
  final bool found; // whether a confident rating was resolved

  const AudibleRating({
    required this.rating,
    required this.tsMs,
    required this.found,
    this.count,
    this.asin,
  });

  bool get isStale =>
      DateTime.now().millisecondsSinceEpoch - tsMs > 24 * 60 * 60 * 1000;

  Map<String, dynamic> toJson() => {
        'rating': rating,
        'count': count,
        'asin': asin,
        'ts': tsMs,
        'found': found,
      };

  factory AudibleRating.fromJson(Map j) => AudibleRating(
        rating: (j['rating'] as num?)?.toDouble() ?? 0,
        count: (j['count'] as num?)?.toInt(),
        asin: j['asin'] as String?,
        tsMs: (j['ts'] as num?)?.toInt() ?? 0,
        found: j['found'] == true,
      );
}

/// Resolves and caches Audible ratings.
///
/// Strategy: exact ASIN lookup first; if no ASIN, a STRICT heuristic search
/// (title + author similarity AND runtime within ~5%) that caches the resolved
/// ASIN. Ratings are cached for 24h (stale-while-revalidate): callers display
/// [loadCached] immediately and then await [resolve] to refresh in place.
class AudibleRatingService {
  AudibleRatingService._();
  static final AudibleRatingService instance = AudibleRatingService._();

  static const String _prefix = 'audible_rating_v1_';

  final Map<String, AudibleRating> _mem = {};
  final Map<String, Future<AudibleRating?>> _inflight = {};
  SharedPreferences? _prefs;

  Future<SharedPreferences> get _p async =>
      _prefs ??= await SharedPreferences.getInstance();

  /// In-memory cached value (null if not loaded yet this session).
  AudibleRating? peek(String itemId) => _mem[itemId];

  /// Cached value from memory or disk (does not hit the network).
  Future<AudibleRating?> loadCached(String itemId) async {
    if (_mem.containsKey(itemId)) return _mem[itemId];
    try {
      final raw = (await _p).getString('$_prefix$itemId');
      if (raw == null) return null;
      final r = AudibleRating.fromJson(jsonDecode(raw) as Map);
      _mem[itemId] = r;
      return r;
    } catch (_) {
      return null;
    }
  }

  /// Returns a rating, refreshing if the cache is stale (>24h) or missing.
  /// On network failure, returns the (possibly stale) cached value unchanged.
  Future<AudibleRating?> resolve({
    required String itemId,
    String? asin,
    required String title,
    String? author,
    String? narrator,
    int? durationMs,
    String region = 'us',
  }) async {
    final cached = await loadCached(itemId);
    if (cached != null && !cached.isStale) return cached;
    if (_inflight.containsKey(itemId)) return _inflight[itemId];

    final fut = _fetchAndCache(
      itemId: itemId,
      asin: asin ?? cached?.asin,
      title: title,
      author: author,
      narrator: narrator,
      durationMs: durationMs,
      region: region,
      fallback: cached,
    );
    _inflight[itemId] = fut;
    try {
      return await fut;
    } finally {
      _inflight.remove(itemId);
    }
  }

  Future<AudibleRating?> _fetchAndCache({
    required String itemId,
    String? asin,
    required String title,
    String? author,
    String? narrator,
    int? durationMs,
    required String region,
    AudibleRating? fallback,
  }) async {
    try {
      Map<String, dynamic>? product;
      if (asin != null && asin.isNotEmpty) {
        product = await _lookupByAsin(asin, region);
      }
      product ??= await _searchBestMatch(
        title: title,
        author: author,
        narrator: narrator,
        durationMs: durationMs,
        region: region,
      );

      final now = DateTime.now().millisecondsSinceEpoch;
      if (product == null) {
        final neg = AudibleRating(rating: 0, tsMs: now, found: false, asin: asin);
        await _store(itemId, neg);
        return neg;
      }

      final dist = (product['rating'] as Map?)?['overall_distribution'] as Map?;
      final avgRaw = dist?['display_average_rating'] ?? dist?['average_rating'];
      final rating = avgRaw is num
          ? avgRaw.toDouble()
          : double.tryParse(avgRaw?.toString() ?? '') ?? 0;
      final count = (dist?['num_ratings'] as num?)?.toInt();
      final resolvedAsin = product['asin']?.toString() ?? asin;

      final r = AudibleRating(
        rating: rating,
        count: count,
        asin: resolvedAsin,
        tsMs: now,
        found: rating > 0,
      );
      await _store(itemId, r);
      return r;
    } catch (_) {
      // Network/parse failure: keep showing the existing cached value.
      return fallback;
    }
  }

  Future<void> _store(String itemId, AudibleRating r) async {
    _mem[itemId] = r;
    try {
      await (await _p).setString('$_prefix$itemId', jsonEncode(r.toJson()));
    } catch (_) {}
  }

  // === Audible catalog API ===

  String _host(String region) {
    switch (region.toLowerCase()) {
      case 'uk':
        return 'api.audible.co.uk';
      case 'de':
        return 'api.audible.de';
      case 'fr':
        return 'api.audible.fr';
      case 'au':
        return 'api.audible.com.au';
      case 'ca':
        return 'api.audible.ca';
      case 'it':
        return 'api.audible.it';
      case 'es':
        return 'api.audible.es';
      case 'jp':
        return 'api.audible.co.jp';
      case 'in':
        return 'api.audible.in';
      default:
        return 'api.audible.com';
    }
  }

  static const Map<String, String> _headers = {'User-Agent': 'Kitzi/1.0'};
  static const String _groups =
      'rating,product_attrs,product_desc,contributors';

  Future<Map<String, dynamic>?> _lookupByAsin(String asin, String region) async {
    final uri = Uri.https(_host(region), '/1.0/catalog/products/$asin',
        {'response_groups': _groups});
    final resp = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    if (data is Map && data['product'] is Map) {
      return (data['product'] as Map).cast<String, dynamic>();
    }
    return null;
  }

  Future<Map<String, dynamic>?> _searchBestMatch({
    required String title,
    String? author,
    String? narrator,
    int? durationMs,
    required String region,
  }) async {
    if (title.trim().isEmpty) return null;
    final params = <String, String>{
      'title': title,
      'num_results': '10',
      'products_sort_by': 'Relevance',
      'response_groups': _groups,
    };
    if (author != null && author.isNotEmpty) params['author'] = author;
    final uri =
        Uri.https(_host(region), '/1.0/catalog/products', params);
    final resp = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    if (data is! Map || data['products'] is! List) return null;
    final products = (data['products'] as List).whereType<Map>().toList();

    final wantTitle = _norm(title);
    final wantMinutes = durationMs != null ? durationMs / 60000.0 : null;

    Map<String, dynamic>? best;
    double bestScore = 0;
    for (final raw in products) {
      final p = raw.cast<String, dynamic>();
      final pTitle = _norm((p['title'] ?? '').toString());
      if (pTitle.isEmpty) continue;
      final titleSim = _similarity(wantTitle, pTitle);
      if (titleSim < 0.8) continue; // strict title gate

      // Strict duration gate when we know the local duration.
      if (wantMinutes != null) {
        final mins = (p['runtime_length_min'] as num?)?.toDouble();
        if (mins == null || mins <= 0) continue;
        final diff = (mins - wantMinutes).abs() / wantMinutes;
        if (diff > 0.05) continue;
      }

      // Author gate when we know the author.
      if (author != null && author.isNotEmpty) {
        final authors = (p['authors'] as List?)
                ?.map((a) => _norm((a is Map ? a['name'] : a).toString()))
                .toList() ??
            const [];
        final wantAuthor = _norm(author);
        final authorOk = authors.any((a) =>
            a.isNotEmpty && (_similarity(a, wantAuthor) >= 0.6));
        if (!authorOk) continue;
      }

      // Score: prefer best title match, then having a rating.
      final dist =
          (p['rating'] as Map?)?['overall_distribution'] as Map?;
      final hasRating = (dist?['num_ratings'] as num?) != null;
      final score = titleSim + (hasRating ? 0.1 : 0);
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    return best;
  }

  // === matching helpers ===

  String _norm(String s) {
    var t = s.toLowerCase();
    final colon = t.indexOf(':');
    if (colon > 3) t = t.substring(0, colon); // drop subtitle
    t = t
        .replaceAll(RegExp(r'\(.*?\)'), ' ')
        .replaceAll('unabridged', ' ')
        .replaceAll('abridged', ' ')
        .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    return t;
  }

  /// Token-set Jaccard similarity (0..1).
  double _similarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    if (a == b) return 1;
    final sa = a.split(' ').where((w) => w.isNotEmpty).toSet();
    final sb = b.split(' ').where((w) => w.isNotEmpty).toSet();
    if (sa.isEmpty || sb.isEmpty) return 0;
    final inter = sa.intersection(sb).length;
    final union = sa.union(sb).length;
    return inter / union;
  }
}
