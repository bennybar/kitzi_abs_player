import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

void _alog(String msg) => debugPrint('[AUDIBLE] $msg');

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

  bool get isStale {
    final ageMs = DateTime.now().millisecondsSinceEpoch - tsMs;
    // Real ratings refresh daily; "not found" results retry sooner so a
    // newly-matched book (or improved matching) surfaces without a long wait.
    final ttlMs = found ? 24 * 60 * 60 * 1000 : 2 * 60 * 60 * 1000;
    return ageMs > ttlMs;
  }

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

  static const String _prefix = 'audible_rating_v3_';

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
    _alog('resolve item=$itemId title="$title" author="${author ?? ''}" '
        'durMs=$durationMs asinIn=${asin ?? '(none)'} region=$region');
    final cached = await loadCached(itemId);
    if (cached != null && !cached.isStale) {
      _alog('  -> using FRESH cache: found=${cached.found} '
          'rating=${cached.rating} count=${cached.count} asin=${cached.asin}');
      return cached;
    }
    if (cached != null) {
      _alog('  cache is STALE (found=${cached.found} rating=${cached.rating}); refreshing');
    } else {
      _alog('  no cache; fetching');
    }
    if (_inflight.containsKey(itemId)) {
      _alog('  request already in-flight; joining');
      return _inflight[itemId];
    }

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
        _alog('  path=ASIN-lookup asin=$asin');
        product = await _lookupByAsin(asin, region);
        _alog('  ASIN-lookup ${product != null ? 'HIT' : 'MISS'}');
      }
      if (product == null) {
        _alog('  path=SEARCH (no asin or asin miss)');
        product = await _searchBestMatch(
          title: title,
          author: author,
          narrator: narrator,
          durationMs: durationMs,
          region: region,
        );
      }

      final now = DateTime.now().millisecondsSinceEpoch;
      if (product == null) {
        _alog('  RESULT: no match -> caching negative (24h)');
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
      _alog('  RESULT: found=${r.found} rating=${r.rating} count=${r.count} '
          'asin=${r.asin} (matched title="${product['title']}")');
      await _store(itemId, r);
      return r;
    } catch (e) {
      // Network/parse failure: keep showing the existing cached value.
      _alog('  ERROR during fetch: $e (keeping fallback=${fallback?.rating})');
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
    _alog('    GET $uri');
    final resp = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 12),
        );
    _alog('    status=${resp.statusCode} bodyLen=${resp.body.length}');
    if (resp.statusCode != 200) return null;
    final data = jsonDecode(resp.body);
    if (data is Map && data['product'] is Map) {
      return (data['product'] as Map).cast<String, dynamic>();
    }
    _alog('    no "product" in response');
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

    // ABS titles often carry series decorations ("Daemon - Book 1",
    // "Travis Chase Book 1 - The Breach") that Audible titles never have.
    // Build query variants and match against all of them.
    final queries = _queryVariants(title);
    final matchTitles = queries.map(_norm).where((s) => s.isNotEmpty).toSet();
    _alog('    title variants: $queries');

    for (final q in queries) {
      // Try with author first; if nothing comes back, retry without it.
      var products = await _searchProducts(q, author, region);
      if (products.isEmpty && author != null && author.isNotEmpty) {
        products = await _searchProducts(q, null, region);
      }
      if (products.isEmpty) continue;
      final best = _pickBest(products, matchTitles, author, durationMs);
      if (best != null) return best;
    }
    _alog('    best match: NONE across ${queries.length} variants');
    return null;
  }

  Future<List<Map>> _searchProducts(
      String title, String? author, String region) async {
    final params = <String, String>{
      'title': title,
      'num_results': '10',
      'products_sort_by': 'Relevance',
      'response_groups': _groups,
    };
    if (author != null && author.isNotEmpty) params['author'] = author;
    final uri = Uri.https(_host(region), '/1.0/catalog/products', params);
    _alog('    SEARCH GET $uri');
    try {
      final resp =
          await http.get(uri, headers: _headers).timeout(const Duration(seconds: 12));
      _alog('    status=${resp.statusCode} bodyLen=${resp.body.length}');
      if (resp.statusCode != 200) return const [];
      final data = jsonDecode(resp.body);
      if (data is! Map || data['products'] is! List) {
        _alog('    no "products" list in response');
        return const [];
      }
      final products = (data['products'] as List).whereType<Map>().toList();
      _alog('    ${products.length} candidates returned');
      return products;
    } catch (e) {
      _alog('    search error: $e');
      return const [];
    }
  }

  Map<String, dynamic>? _pickBest(
    List<Map> products,
    Set<String> matchTitles,
    String? author,
    int? durationMs,
  ) {
    final wantMinutes = durationMs != null ? durationMs / 60000.0 : null;
    final wantAuthor =
        (author != null && author.isNotEmpty) ? _norm(author) : null;

    Map<String, dynamic>? best;
    double bestScore = 0;
    for (final raw in products) {
      final p = raw.cast<String, dynamic>();
      final pTitleRaw = (p['title'] ?? '').toString();
      final pTitle = _norm(pTitleRaw);
      final mins = (p['runtime_length_min'] as num?)?.toDouble();
      if (pTitle.isEmpty) continue;
      // Best similarity across all local title variants.
      var titleSim = 0.0;
      for (final w in matchTitles) {
        final s = _similarity(w, pTitle);
        if (s > titleSim) titleSim = s;
      }
      if (titleSim < 0.8) {
        _alog('      reject "$pTitleRaw" titleSim=${titleSim.toStringAsFixed(2)} (<0.80)');
        continue; // title must match strongly
      }

      // Duration corroboration (strong signal). If the local duration is known
      // AND the candidate reports a clearly different one, reject the wrong
      // edition; within tolerance is a positive signal.
      bool durOk = false;
      double? durDiff;
      if (wantMinutes != null) {
        if (mins != null && mins > 0) {
          durDiff = (mins - wantMinutes).abs() / wantMinutes;
          if (durDiff > 0.08) {
            _alog('      reject "$pTitleRaw" titleSim=${titleSim.toStringAsFixed(2)} '
                'durDiff=${(durDiff * 100).toStringAsFixed(0)}% (>8%, want=${wantMinutes.round()}m got=${mins.round()}m)');
            continue;
          }
          durOk = true;
        }
      }

      // Author corroboration.
      bool authorOk = false;
      if (wantAuthor != null) {
        final authors = (p['authors'] as List?)
                ?.map((a) => _norm((a is Map ? a['name'] : a).toString()))
                .toList() ??
            const [];
        authorOk = authors
            .any((a) => a.isNotEmpty && _similarity(a, wantAuthor) >= 0.5);
        // Author known but unmatched, with no duration backup -> too risky.
        if (!authorOk && !durOk) {
          _alog('      reject "$pTitleRaw" titleSim=${titleSim.toStringAsFixed(2)} '
              'author mismatch (want="$wantAuthor" got=$authors) & no duration backup');
          continue;
        }
      }

      // No corroborating signal at all -> require a near-exact title.
      if (!durOk && !authorOk && titleSim < 0.92) {
        _alog('      reject "$pTitleRaw" titleSim=${titleSim.toStringAsFixed(2)} '
            'no corroboration (need >=0.92)');
        continue;
      }

      final dist = (p['rating'] as Map?)?['overall_distribution'] as Map?;
      final hasRating = (dist?['num_ratings'] as num?) != null;
      final score = titleSim +
          (durOk ? 0.25 : 0) +
          (authorOk ? 0.25 : 0) +
          (hasRating ? 0.1 : 0);
      _alog('      candidate "$pTitleRaw" titleSim=${titleSim.toStringAsFixed(2)} '
          'durOk=$durOk authorOk=$authorOk hasRating=$hasRating score=${score.toStringAsFixed(2)}');
      if (score > bestScore) {
        bestScore = score;
        best = p;
      }
    }
    _alog('    best match: ${best != null ? '"${best['title']}"' : 'NONE'} '
        '(score=${bestScore.toStringAsFixed(2)})');
    return best;
  }

  // === matching helpers ===

  /// Ordered search-title candidates derived from a decorated ABS title.
  List<String> _queryVariants(String title) {
    final out = <String>[];
    void add(String s) {
      final t = s.trim();
      if (t.isNotEmpty && !out.contains(t)) out.add(t);
    }

    final cleaned = _cleanQueryTitle(title);
    add(cleaned);
    // "Series Book N - Title" / "Title - Subtitle": try segments around a dash.
    final dashParts = cleaned.split(RegExp(r'\s[-–—]\s'));
    if (dashParts.length > 1) {
      add(_cleanQueryTitle(dashParts.last));
      add(_cleanQueryTitle(dashParts.first));
    }
    add(title.trim()); // raw, last resort
    return out;
  }

  /// Strip series decorations ("Book 1", "Vol. 2", "(Unabridged)", trailing #N).
  String _cleanQueryTitle(String t) {
    var s = t;
    s = s.replaceAll(RegExp(r'[\(\[\{].*?[\)\]\}]'), ' '); // bracketed notes
    s = s.replaceAll(
        RegExp(r'[-–—:,]?\s*\b(book|bk|vol|volume|part|episode|ep)\b\.?\s*\d+',
            caseSensitive: false),
        ' ');
    s = s.replaceAll(RegExp(r'[-–—#]\s*\d+\s*$'), ' '); // trailing "- 3" / "#3"
    s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    s = s
        .replaceAll(RegExp(r'^[\s\-–—:,]+'), '')
        .replaceAll(RegExp(r'[\s\-–—:,]+$'), '')
        .trim();
    return s.isEmpty ? t.trim() : s;
  }

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
