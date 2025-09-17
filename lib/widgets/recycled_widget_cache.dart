import 'package:flutter/material.dart';

/// Widget recycling cache for better performance
class RecycledWidgetCache {
  static final Map<String, Widget> _cache = {};
  static final Map<String, DateTime> _timestamps = {};
  static const Duration _cacheTimeout = Duration(minutes: 10);
  
  /// Get a cached widget or create a new one
  static Widget getOrCreate<T extends StatelessWidget>(
    String key,
    T Function() builder,
  ) {
    final now = DateTime.now();
    
    // Clean expired entries
    _timestamps.removeWhere((k, timestamp) {
      if (now.difference(timestamp) > _cacheTimeout) {
        _cache.remove(k);
        return true;
      }
      return false;
    });
    
    // Return cached widget if available
    if (_cache.containsKey(key)) {
      _timestamps[key] = now; // Update timestamp
      return _cache[key]!;
    }
    
    // Create new widget and cache it
    final widget = builder();
    _cache[key] = widget;
    _timestamps[key] = now;
    
    return widget;
  }
  
  /// Clear the cache
  static void clear() {
    _cache.clear();
    _timestamps.clear();
  }
  
  /// Clear expired entries
  static void cleanExpired() {
    final now = DateTime.now();
    _timestamps.removeWhere((key, timestamp) {
      if (now.difference(timestamp) > _cacheTimeout) {
        _cache.remove(key);
        return true;
      }
      return false;
    });
  }
  
  /// Get cache stats
  static Map<String, dynamic> getStats() {
    return {
      'cachedWidgets': _cache.length,
      'oldestEntry': _timestamps.values.isEmpty 
          ? null 
          : _timestamps.values.reduce((a, b) => a.isBefore(b) ? a : b),
      'newestEntry': _timestamps.values.isEmpty 
          ? null 
          : _timestamps.values.reduce((a, b) => a.isAfter(b) ? a : b),
    };
  }
}

/// Recycled book list tile for better performance
class RecycledBookListTile extends StatelessWidget {
  final String bookId;
  final String title;
  final String? author;
  final String coverUrl;
  final VoidCallback? onTap;
  final bool isAudioBook;
  
  const RecycledBookListTile({
    super.key,
    required this.bookId,
    required this.title,
    this.author,
    required this.coverUrl,
    this.onTap,
    required this.isAudioBook,
  });
  
  @override
  Widget build(BuildContext context) {
    final cacheKey = 'book_tile_${bookId}_${title.hashCode}_${author?.hashCode ?? 0}';
    
    return RecycledWidgetCache.getOrCreate(cacheKey, () {
      final cs = Theme.of(context).colorScheme;
      final disabled = !isAudioBook;
      
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: cs.outline.withOpacity(0.08),
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                // Cover
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 72,
                    height: 72,
                    child: ColorFiltered(
                      colorFilter: disabled
                          ? ColorFilter.mode(cs.surface.withOpacity(0.12), BlendMode.saturation)
                          : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
                      child: Image.network(
                        coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(
                            Icons.menu_book_outlined,
                            color: cs.onSurfaceVariant,
                            size: 32,
                          ),
                        ),
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            color: cs.surfaceContainerHighest,
                            child: Center(
                              child: SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: cs.primary,
                                  value: loadingProgress.expectedTotalBytes != null
                                      ? loadingProgress.cumulativeBytesLoaded /
                                          loadingProgress.expectedTotalBytes!
                                      : null,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                
                // Content
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Title
                      Text(
                        title,
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: disabled ? cs.onSurfaceVariant : null,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (author != null && author!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        // Author
                        Text(
                          author!,
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                
                // Arrow
                Icon(
                  Icons.chevron_right_rounded,
                  color: disabled ? cs.onSurfaceVariant : cs.primary,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      );
    });
  }
}

/// Recycled book card for better performance
class RecycledBookCard extends StatelessWidget {
  final String bookId;
  final String title;
  final String? author;
  final String coverUrl;
  final VoidCallback? onTap;
  final bool isAudioBook;
  
  const RecycledBookCard({
    super.key,
    required this.bookId,
    required this.title,
    this.author,
    required this.coverUrl,
    this.onTap,
    required this.isAudioBook,
  });
  
  @override
  Widget build(BuildContext context) {
    final cacheKey = 'book_card_${bookId}_${title.hashCode}_${author?.hashCode ?? 0}';
    
    return RecycledWidgetCache.getOrCreate(cacheKey, () {
      final cs = Theme.of(context).colorScheme;
      final disabled = !isAudioBook;
      
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: cs.outline.withOpacity(0.08),
            width: 1,
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Cover
                AspectRatio(
                  aspectRatio: 2 / 3,
                  child: ColorFiltered(
                    colorFilter: disabled
                        ? ColorFilter.mode(cs.surface.withOpacity(0.12), BlendMode.saturation)
                        : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        coverUrl,
                        fit: BoxFit.cover,
                        width: double.infinity,
                        errorBuilder: (context, error, stackTrace) => Container(
                          color: cs.surfaceContainerHighest,
                          child: Icon(
                            Icons.menu_book_outlined,
                            color: cs.onSurfaceVariant,
                            size: 48,
                          ),
                        ),
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Container(
                            color: cs.surfaceContainerHighest,
                            child: Center(
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: CircularProgressIndicator(
                                  strokeWidth: 3,
                                  color: cs.primary,
                                  value: loadingProgress.expectedTotalBytes != null
                                      ? loadingProgress.cumulativeBytesLoaded /
                                          loadingProgress.expectedTotalBytes!
                                      : null,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                
                // Title
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: disabled ? cs.onSurfaceVariant : null,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                
                if (author != null && author!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  // Author
                  Text(
                    author!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    });
  }
}
