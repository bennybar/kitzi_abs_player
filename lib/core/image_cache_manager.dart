import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path_provider/path_provider.dart';

/// Custom image cache manager for optimized cover loading
class ImageCacheManager {
  static const int maxCacheSize = 100 * 1024 * 1024; // 100MB
  static const Duration maxCacheDuration = Duration(days: 30);
  
  static CacheManager? _cacheManager;
  static final Set<String> _preloadingUrls = <String>{};
  
  static CacheManager get _instance {
    _cacheManager ??= CacheManager(
      Config(
        'kitzi_covers',
        maxNrOfCacheObjects: 1000,
        stalePeriod: maxCacheDuration,
        repo: JsonCacheInfoRepository(databaseName: 'kitzi_covers'),
        fileService: HttpFileService(),
      ),
    );
    return _cacheManager!;
  }
  
  /// Preload images for better user experience
  static Future<void> preloadImages(List<String> urls, BuildContext context) async {
    final futures = <Future<void>>[];
    
    for (final url in urls.take(10)) { // Limit to 10 concurrent preloads
      if (!_preloadingUrls.contains(url)) {
        _preloadingUrls.add(url);
        futures.add(_preloadSingleImage(url, context));
      }
    }
    
    try {
      await Future.wait(futures);
    } finally {
      _preloadingUrls.clear();
    }
  }
  
  static Future<void> _preloadSingleImage(String url, BuildContext context) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri != null && uri.scheme == 'file') {
        // Handle local file URLs
        final file = File(uri.toFilePath());
        if (await file.exists()) {
          await precacheImage(FileImage(file), context);
        }
      } else {
        // Handle network URLs
        await precacheImage(
          CachedNetworkImageProvider(url, cacheManager: _instance),
          context,
        );
      }
    } catch (e) {
      debugPrint('Failed to preload image: $url - $e');
    }
  }
  
  /// Clear cache when storage is low
  static Future<void> clearCache() async {
    try {
      await _instance.emptyCache();
      debugPrint('Image cache cleared');
    } catch (e) {
      debugPrint('Failed to clear image cache: $e');
    }
  }
  
  /// Get cache size for storage management
  static Future<int> getCacheSize() async {
    try {
      final cacheDir = await getTemporaryDirectory();
      final kitziCacheDir = Directory('${cacheDir.path}/kitzi_covers');
      
      if (!await kitziCacheDir.exists()) return 0;
      
      int totalSize = 0;
      await for (final entity in kitziCacheDir.list(recursive: true)) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      
      return totalSize;
    } catch (e) {
      debugPrint('Failed to get cache size: $e');
      return 0;
    }
  }
  
  /// Check if cache is getting too large
  static Future<bool> shouldClearCache() async {
    final size = await getCacheSize();
    return size > maxCacheSize;
  }
}

/// Enhanced cover widget with better error handling and loading states
class EnhancedCoverImage extends StatelessWidget {
  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? errorWidget;
  
  const EnhancedCoverImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.errorWidget,
  });
  
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    
    final defaultPlaceholder = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: cs.onSurfaceVariant,
          size: (width != null ? width! * 0.4 : 32).clamp(16, 64).toDouble(),
        ),
      ),
    );
    
    final defaultErrorWidget = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: cs.errorContainer.withOpacity(0.1),
        borderRadius: radius,
        border: Border.all(
          color: cs.error.withOpacity(0.2),
          width: 1,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.broken_image_outlined,
          color: cs.error,
          size: (width != null ? width! * 0.3 : 24).clamp(16, 48).toDouble(),
        ),
      ),
    );

    // Handle offline file URLs
    final uri = Uri.tryParse(url);
    Widget child;
    if (uri != null && uri.scheme == 'file') {
      final filePath = uri.toFilePath();
      final file = File(filePath);
      child = file.existsSync()
          ? ClipRRect(
              borderRadius: radius,
              child: Image.file(
                file,
                width: width,
                height: height,
                fit: fit,
              ),
            )
          : defaultErrorWidget;
    } else {
      // Handle network URLs with custom cache manager
      child = ClipRRect(
        borderRadius: radius,
        child: CachedNetworkImage(
          imageUrl: url,
          width: width,
          height: height,
          fit: fit,
          cacheManager: ImageCacheManager._instance,
          memCacheWidth: width != null ? (width! * MediaQuery.of(context).devicePixelRatio).round() : null,
          memCacheHeight: height != null ? (height! * MediaQuery.of(context).devicePixelRatio).round() : null,
          placeholder: (_, __) => placeholder ?? defaultPlaceholder,
          errorWidget: (_, __, ___) => errorWidget ?? defaultErrorWidget,
          fadeInDuration: const Duration(milliseconds: 200),
          fadeOutDuration: const Duration(milliseconds: 100),
        ),
      );
    }

    return SizedBox(
      width: width,
      height: height,
      child: child,
    );
  }
}
