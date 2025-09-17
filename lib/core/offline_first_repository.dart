import 'dart:async';
import 'package:flutter/foundation.dart';
import 'network_service.dart';

/// Offline-first repository pattern for better offline support
abstract class OfflineFirstRepository<T> {
  /// Get data from cache first, then network with fallback
  Future<List<T>> getData({
    bool forceRefresh = false,
    Duration cacheTimeout = const Duration(hours: 1),
  });
  
  /// Get single item from cache first, then network with fallback
  Future<T?> getItem(String id, {
    bool forceRefresh = false,
    Duration cacheTimeout = const Duration(hours: 1),
  });
  
  /// Save data to cache
  Future<void> saveToCache(List<T> data);
  
  /// Get data from cache only
  Future<List<T>> getFromCache();
  
  /// Get single item from cache only
  Future<T?> getFromCacheById(String id);
  
  /// Clear cache
  Future<void> clearCache();
  
  /// Check if cache is valid (not expired)
  Future<bool> isCacheValid(Duration timeout);
  
  /// Get data from network
  Future<List<T>> getFromNetwork();
  
  /// Get single item from network
  Future<T?> getFromNetworkById(String id);
}

/// Concrete implementation for books repository
class OfflineFirstBooksRepository implements OfflineFirstRepository<dynamic> {
  // Enable/disable verbose logging
  static const bool _verboseLogging = false;
  
  /// Log debug message only if verbose logging is enabled
  void _log(String message) {
    if (_verboseLogging) {
      debugPrint(message);
    }
  }
  final Future<List<dynamic>> Function() _networkFetcher;
  final Future<List<dynamic>> Function() _cacheFetcher;
  final Future<void> Function(List<dynamic>) _cacheSaver;
  final Future<dynamic> Function(String) _networkItemFetcher;
  final Future<dynamic> Function(String) _cacheItemFetcher;
  final Future<void> Function() _cacheClearer;
  final DateTime? Function() _lastCacheTime;
  final Future<void> Function(DateTime) _saveCacheTime;
  
  OfflineFirstBooksRepository({
    required Future<List<dynamic>> Function() networkFetcher,
    required Future<List<dynamic>> Function() cacheFetcher,
    required Future<void> Function(List<dynamic>) cacheSaver,
    required Future<dynamic> Function(String) networkItemFetcher,
    required Future<dynamic> Function(String) cacheItemFetcher,
    required Future<void> Function() cacheClearer,
    required DateTime? Function() lastCacheTime,
    required Future<void> Function(DateTime) saveCacheTime,
  }) : _networkFetcher = networkFetcher,
       _cacheFetcher = cacheFetcher,
       _cacheSaver = cacheSaver,
       _networkItemFetcher = networkItemFetcher,
       _cacheItemFetcher = cacheItemFetcher,
       _cacheClearer = cacheClearer,
       _lastCacheTime = lastCacheTime,
       _saveCacheTime = saveCacheTime;
  
  @override
  Future<List<dynamic>> getData({
    bool forceRefresh = false,
    Duration cacheTimeout = const Duration(hours: 1),
  }) async {
    try {
      // If not forcing refresh, try cache first
      if (!forceRefresh) {
        final cacheValid = await isCacheValid(cacheTimeout);
        if (cacheValid) {
          final cachedData = await getFromCache();
          if (cachedData.isNotEmpty) {
            _log('[OFFLINE_FIRST] Returning cached data (${cachedData.length} items)');
            return cachedData;
          }
        }
      }
      
      // Try network with timeout and retry
      debugPrint('[OFFLINE_FIRST] Attempting network fetch...');
      final networkData = await NetworkService.withRetry(
        () => _networkFetcher(),
        timeout: const Duration(seconds: 15),
        onRetry: (attempt, error) {
          debugPrint('[OFFLINE_FIRST] Network attempt $attempt failed: $error');
        },
      );
      
      // Save to cache and return
      await saveToCache(networkData);
      _log('[OFFLINE_FIRST] Network fetch successful, saved to cache');
      return networkData;
      
    } catch (error) {
      debugPrint('[OFFLINE_FIRST] Network fetch failed, falling back to cache: $error');
      
      // Fallback to cache
      final cachedData = await getFromCache();
      if (cachedData.isNotEmpty) {
        _log('[OFFLINE_FIRST] Returning stale cached data (${cachedData.length} items)');
        return cachedData;
      }
      
      // If no cache available, rethrow the network error
      rethrow;
    }
  }
  
  @override
  Future<dynamic> getItem(String id, {
    bool forceRefresh = false,
    Duration cacheTimeout = const Duration(hours: 1),
  }) async {
    try {
      // If not forcing refresh, try cache first
      if (!forceRefresh) {
        final cachedItem = await getFromCacheById(id);
        if (cachedItem != null) {
          debugPrint('[OFFLINE_FIRST] Returning cached item: $id');
          return cachedItem;
        }
      }
      
      // Try network with timeout and retry
      debugPrint('[OFFLINE_FIRST] Attempting network fetch for item: $id');
      final networkItem = await NetworkService.withRetry(
        () => _networkItemFetcher(id),
        timeout: const Duration(seconds: 10),
      );
      
      debugPrint('[OFFLINE_FIRST] Network fetch successful for item: $id');
      return networkItem;
      
    } catch (error) {
      debugPrint('[OFFLINE_FIRST] Network fetch failed for item $id, falling back to cache: $error');
      
      // Fallback to cache
      final cachedItem = await getFromCacheById(id);
      if (cachedItem != null) {
        debugPrint('[OFFLINE_FIRST] Returning stale cached item: $id');
        return cachedItem;
      }
      
      // If no cache available, rethrow the network error
      rethrow;
    }
  }
  
  @override
  Future<void> saveToCache(List<dynamic> data) async {
    await _cacheSaver(data);
    await _saveCacheTime(DateTime.now());
    debugPrint('[OFFLINE_FIRST] Saved ${data.length} items to cache');
  }
  
  @override
  Future<List<dynamic>> getFromCache() async {
    return await _cacheFetcher();
  }
  
  @override
  Future<dynamic> getFromCacheById(String id) async {
    return await _cacheItemFetcher(id);
  }
  
  @override
  Future<void> clearCache() async {
    await _cacheClearer();
    debugPrint('[OFFLINE_FIRST] Cache cleared');
  }
  
  @override
  Future<bool> isCacheValid(Duration timeout) async {
    final lastTime = _lastCacheTime();
    if (lastTime == null) return false;
    
    final now = DateTime.now();
    final isValid = now.difference(lastTime) < timeout;
    debugPrint('[OFFLINE_FIRST] Cache valid: $isValid (age: ${now.difference(lastTime).inMinutes} minutes)');
    return isValid;
  }
  
  @override
  Future<List<dynamic>> getFromNetwork() async {
    return await _networkFetcher();
  }
  
  @override
  Future<dynamic> getFromNetworkById(String id) async {
    return await _networkItemFetcher(id);
  }
}

/// Offline-first service for managing offline state
class OfflineFirstService {
  static final StreamController<bool> _offlineController = 
      StreamController<bool>.broadcast();
  
  static Stream<bool> get offlineStream => _offlineController.stream;
  
  static bool _isOffline = false;
  static bool get isOffline => _isOffline;
  
  static void setOffline(bool offline) {
    if (_isOffline != offline) {
      _isOffline = offline;
      _offlineController.add(offline);
      debugPrint('[OFFLINE_FIRST] Offline state changed: $offline');
    }
  }
  
  /// Check network connectivity and update offline state
  static Future<void> checkConnectivity() async {
    try {
      // Simple connectivity check - in production, use connectivity_plus
      final result = await NetworkService.withRetry(
        () async {
          // Make a lightweight request to check connectivity
          // This could be a ping to your server or a simple HTTP request
          return true;
        },
        maxRetries: 1,
        timeout: const Duration(seconds: 3),
      );
      
      setOffline(!result);
    } catch (e) {
      setOffline(true);
    }
  }
  
  static void dispose() {
    _offlineController.close();
  }
}

/// Cache metadata for tracking cache state
class CacheMetadata {
  final DateTime lastUpdated;
  final int itemCount;
  final String? version;
  final Map<String, dynamic>? extra;
  
  const CacheMetadata({
    required this.lastUpdated,
    required this.itemCount,
    this.version,
    this.extra,
  });
  
  Map<String, dynamic> toJson() => {
    'lastUpdated': lastUpdated.millisecondsSinceEpoch,
    'itemCount': itemCount,
    'version': version,
    'extra': extra,
  };
  
  factory CacheMetadata.fromJson(Map<String, dynamic> json) => CacheMetadata(
    lastUpdated: DateTime.fromMillisecondsSinceEpoch(json['lastUpdated']),
    itemCount: json['itemCount'],
    version: json['version'],
    extra: json['extra'],
  );
}
