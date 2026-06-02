import 'dart:convert';

import 'package:flutter/material.dart';

import '../core/api_client.dart';
import '../core/audible_rating_service.dart';
import '../main.dart';

/// Shows a cached Audible star rating for a book. Displays the cached value
/// immediately and refreshes in place when it's older than 24h
/// (stale-while-revalidate). Renders nothing until a confident rating exists.
class AudibleStars extends StatefulWidget {
  const AudibleStars({
    super.key,
    required this.itemId,
    required this.title,
    this.asin,
    this.author,
    this.narrator,
    this.durationMs,
    this.region = 'us',
    this.starSize = 16,
    this.color,
    this.showCount = true,
    this.alignment = MainAxisAlignment.start,
  });

  final String itemId;
  final String title;
  final String? asin;
  final String? author;
  final String? narrator;
  final int? durationMs;
  final String region;
  final double starSize;
  final Color? color;
  final bool showCount;
  final MainAxisAlignment alignment;

  @override
  State<AudibleStars> createState() => _AudibleStarsState();
}

class _AudibleStarsState extends State<AudibleStars> {
  AudibleRating? _rating;
  ApiClient? _api;
  String? _loadedFor; // itemId we've already kicked a load for

  @override
  void initState() {
    super.initState();
    _rating = AudibleRatingService.instance.peek(widget.itemId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Safe place to read inherited services; needed to ask ABS for the ASIN.
    _api = ServicesScope.of(context).services.auth.api;
    if (_loadedFor != widget.itemId) {
      _loadedFor = widget.itemId;
      _load();
    }
  }

  @override
  void didUpdateWidget(AudibleStars old) {
    super.didUpdateWidget(old);
    if (old.itemId != widget.itemId) {
      _rating = AudibleRatingService.instance.peek(widget.itemId);
      _loadedFor = widget.itemId;
      _load();
    }
  }

  Future<void> _load() async {
    final svc = AudibleRatingService.instance;
    // 1) show whatever is cached, instantly.
    final cached = await svc.loadCached(widget.itemId);
    if (!mounted) return;
    if (cached != null) setState(() => _rating = cached);
    if (cached != null && !cached.isStale) return; // fresh enough; done.

    // 2) Make sure we have an ASIN. Prefer the one passed in; else the one we
    // resolved before; else ask the ABS server directly (works for downloaded
    // items too, whose cached Book carries no ASIN). The ungated ASIN lookup is
    // far more reliable than the heuristic search.
    var asin = widget.asin;
    if (asin == null || asin.isEmpty) asin = cached?.asin;
    if (asin == null || asin.isEmpty) {
      asin = await _fetchAbsAsin();
      debugPrint('[AUDIBLE] widget item=${widget.itemId} title="${widget.title}" '
          'ABS-asin=${asin ?? '(none found)'}');
    }

    // 3) refresh if stale/missing, then update in place.
    final fresh = await svc.resolve(
      itemId: widget.itemId,
      asin: asin,
      title: widget.title,
      author: widget.author,
      narrator: widget.narrator,
      durationMs: widget.durationMs,
      region: widget.region,
    );
    if (!mounted || fresh == null) return;
    setState(() => _rating = fresh);
  }

  /// Read the Audible ASIN straight from the ABS item metadata (online only).
  Future<String?> _fetchAbsAsin() async {
    final api = _api;
    if (api == null) return null;
    try {
      final resp = await api.request('GET', '/api/items/${widget.itemId}');
      if (resp.statusCode != 200 || resp.body.isEmpty) {
        debugPrint('[AUDIBLE] ABS /api/items/${widget.itemId} '
            'status=${resp.statusCode} bodyLen=${resp.body.length} -> no asin');
        return null;
      }
      final parsed = jsonDecode(resp.body);
      final item = (parsed is Map && parsed['item'] is Map)
          ? (parsed['item'] as Map)
          : (parsed is Map ? parsed : null);
      final media = item?['media'];
      final meta = media is Map ? media['metadata'] : null;
      final asin = meta is Map ? meta['asin']?.toString() : null;
      debugPrint('[AUDIBLE] ABS /api/items/${widget.itemId} '
          'status=${resp.statusCode} metaAsin=${asin ?? '(null)'}');
      if (asin != null && asin.trim().isNotEmpty) return asin.trim();
    } catch (e) {
      debugPrint('[AUDIBLE] ABS asin fetch error for ${widget.itemId}: $e');
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final r = _rating;
    if (r == null || !r.found || r.rating <= 0) {
      return const SizedBox.shrink();
    }
    final cs = Theme.of(context).colorScheme;
    final starColor = widget.color ?? const Color(0xFFF6A609); // Audible amber
    final textColor = widget.color ?? cs.onSurfaceVariant;

    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: widget.alignment,
      children: [
        ..._buildStars(r.rating, widget.starSize, starColor),
        const SizedBox(width: 6),
        Text(
          r.rating.toStringAsFixed(1),
          style: TextStyle(
            fontSize: widget.starSize * 0.85,
            fontWeight: FontWeight.w700,
            color: textColor,
          ),
        ),
        if (widget.showCount && r.count != null && r.count! > 0) ...[
          const SizedBox(width: 4),
          Text(
            '(${_formatCount(r.count!)})',
            style: TextStyle(
              fontSize: widget.starSize * 0.78,
              color: textColor.withOpacity(0.85),
            ),
          ),
        ],
      ],
    );
  }

  List<Widget> _buildStars(double rating, double size, Color color) {
    // Five stars; fill the number that matches the score (filled / half /
    // outline). Filled stars use the accent colour, empties a faint outline.
    final full = rating.floor();
    final frac = rating - full;
    final empty = color.withOpacity(0.30);
    return List.generate(5, (i) {
      if (i < full) {
        return Icon(Icons.star_rounded, size: size, color: color);
      }
      if (i == full && frac >= 0.75) {
        return Icon(Icons.star_rounded, size: size, color: color);
      }
      if (i == full && frac >= 0.25) {
        return Icon(Icons.star_half_rounded, size: size, color: color);
      }
      return Icon(Icons.star_outline_rounded, size: size, color: empty);
    });
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }
}
