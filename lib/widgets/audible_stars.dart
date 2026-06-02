import 'package:flutter/material.dart';

import '../core/audible_rating_service.dart';

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

  @override
  void initState() {
    super.initState();
    _rating = AudibleRatingService.instance.peek(widget.itemId);
    _load();
  }

  @override
  void didUpdateWidget(AudibleStars old) {
    super.didUpdateWidget(old);
    if (old.itemId != widget.itemId) {
      _rating = AudibleRatingService.instance.peek(widget.itemId);
      _load();
    }
  }

  Future<void> _load() async {
    final svc = AudibleRatingService.instance;
    // 1) show whatever is cached, instantly.
    final cached = await svc.loadCached(widget.itemId);
    if (!mounted) return;
    if (cached != null) setState(() => _rating = cached);
    // 2) refresh if stale/missing, then update in place.
    final fresh = await svc.resolve(
      itemId: widget.itemId,
      asin: widget.asin,
      title: widget.title,
      author: widget.author,
      narrator: widget.narrator,
      durationMs: widget.durationMs,
      region: widget.region,
    );
    if (!mounted || fresh == null) return;
    setState(() => _rating = fresh);
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
    final full = rating.floor();
    final frac = rating - full;
    return List.generate(5, (i) {
      IconData icon;
      if (i < full) {
        icon = Icons.star_rounded;
      } else if (i == full && frac >= 0.25 && frac < 0.85) {
        icon = Icons.star_half_rounded;
      } else if (i == full && frac >= 0.85) {
        icon = Icons.star_rounded;
      } else {
        icon = Icons.star_outline_rounded;
      }
      return Icon(icon, size: size, color: color);
    });
  }

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(n >= 10000 ? 0 : 1)}k';
    return '$n';
  }
}
