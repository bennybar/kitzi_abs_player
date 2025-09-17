import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'books_repository.dart';
import 'auth_repository.dart';

/// Background sync service for data updates
class BackgroundSyncService {
  static Timer? _syncTimer;
  static bool _isSyncing = false;
  static const Duration _syncInterval = Duration(minutes: 15);
  static const String _lastSyncKey = 'last_background_sync';
  static const String _lastFullSyncKey = 'last_full_background_sync';
  
  /// Start background sync timer
  static void start() {
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_syncInterval, (_) async {
      await _performBackgroundSync();
    });
    debugPrint('[BACKGROUND_SYNC] Started with ${_syncInterval.inMinutes} minute interval');
  }
  
  /// Stop background sync
  static void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    debugPrint('[BACKGROUND_SYNC] Stopped');
  }
  
  /// Perform background sync
  static Future<void> _performBackgroundSync() async {
    if (_isSyncing) {
      debugPrint('[BACKGROUND_SYNC] Already syncing, skipping');
      return;
    }
    
    try {
      _isSyncing = true;
      debugPrint('[BACKGROUND_SYNC] Starting background sync');
      
      // Check if we should sync
      if (!await _shouldSync()) {
        debugPrint('[BACKGROUND_SYNC] Skipping sync - conditions not met');
        return;
      }
      
      // Perform incremental sync
      await _performIncrementalSync();
      
      // Update last sync time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      
      debugPrint('[BACKGROUND_SYNC] Background sync completed');
    } catch (e) {
      debugPrint('[BACKGROUND_SYNC] Error during background sync: $e');
    } finally {
      _isSyncing = false;
    }
  }
  
  /// Check if we should perform a sync
  static Future<bool> _shouldSync() async {
    try {
      // Check if user is authenticated
      final auth = await AuthRepository.ensure();
      if (!await auth.hasValidSession()) {
        debugPrint('[BACKGROUND_SYNC] No valid session, skipping sync');
        return false;
      }
      
      // Check network connectivity
      final isOnline = await _checkConnectivity();
      if (!isOnline) {
        debugPrint('[BACKGROUND_SYNC] No network connection, skipping sync');
        return false;
      }
      
      // Check if enough time has passed since last sync
      final prefs = await SharedPreferences.getInstance();
      final lastSyncMs = prefs.getInt(_lastSyncKey);
      if (lastSyncMs != null) {
        final lastSync = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
        final timeSinceLastSync = DateTime.now().difference(lastSync);
        if (timeSinceLastSync < const Duration(minutes: 10)) {
          debugPrint('[BACKGROUND_SYNC] Too soon since last sync, skipping');
          return false;
        }
      }
      
      return true;
    } catch (e) {
      debugPrint('[BACKGROUND_SYNC] Error checking sync conditions: $e');
      return false;
    }
  }
  
  /// Perform incremental sync
  static Future<void> _performIncrementalSync() async {
    try {
      final repo = await BooksRepository.create();
      
      // Sync only the first few pages to keep it lightweight
      await repo.fetchBooksPage(page: 1, limit: 50);
      await repo.fetchBooksPage(page: 2, limit: 50);
      
      debugPrint('[BACKGROUND_SYNC] Incremental sync completed');
    } catch (e) {
      debugPrint('[BACKGROUND_SYNC] Error during incremental sync: $e');
    }
  }
  
  /// Perform full sync (called manually)
  static Future<void> performFullSync() async {
    if (_isSyncing) {
      debugPrint('[BACKGROUND_SYNC] Already syncing, skipping full sync');
      return;
    }
    
    try {
      _isSyncing = true;
      debugPrint('[BACKGROUND_SYNC] Starting full sync');
      
      final repo = await BooksRepository.create();
      await repo.syncAllBooksToDb(pageSize: 100);
      
      // Update last full sync time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastFullSyncKey, DateTime.now().millisecondsSinceEpoch);
      
      debugPrint('[BACKGROUND_SYNC] Full sync completed');
    } catch (e) {
      debugPrint('[BACKGROUND_SYNC] Error during full sync: $e');
    } finally {
      _isSyncing = false;
    }
  }
  
  /// Check network connectivity
  static Future<bool> _checkConnectivity() async {
    try {
      // Simple connectivity check - in production, use connectivity_plus
      return true; // Assume connected for now
    } catch (e) {
      return false;
    }
  }
  
  /// Get sync status
  static Future<Map<String, dynamic>> getStatus() async {
    final prefs = await SharedPreferences.getInstance();
    final lastSyncMs = prefs.getInt(_lastSyncKey);
    final lastFullSyncMs = prefs.getInt(_lastFullSyncKey);
    
    return {
      'isRunning': _syncTimer?.isActive ?? false,
      'isSyncing': _isSyncing,
      'lastSync': lastSyncMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(lastSyncMs)
          : null,
      'lastFullSync': lastFullSyncMs != null 
          ? DateTime.fromMillisecondsSinceEpoch(lastFullSyncMs)
          : null,
      'syncInterval': _syncInterval,
    };
  }
  
  /// Force sync now
  static Future<void> syncNow() async {
    await _performBackgroundSync();
  }
  
  /// Clear sync history
  static Future<void> clearHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSyncKey);
    await prefs.remove(_lastFullSyncKey);
    debugPrint('[BACKGROUND_SYNC] Sync history cleared');
  }
}
