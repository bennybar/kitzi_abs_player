import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'books_repository.dart';
import 'auth_repository.dart';

/// Background sync service for data updates
class BackgroundSyncService {
  static Timer? _syncTimer;
  static bool _isSyncing = false;
  static bool _isAppInForeground = true;
  static const Duration _syncInterval = Duration(hours: 3);
  static const String _lastSyncKey = 'last_background_sync';
  static const String _lastFullSyncKey = 'last_full_background_sync';
  
  /// Start background sync timer
  static void start() {
    if (!_isAppInForeground) {
      // Don't start if app is in background
      return;
    }
    _syncTimer?.cancel();
    _syncTimer = Timer.periodic(_syncInterval, (_) async {
      if (_isAppInForeground) {
        await _performBackgroundSync();
      }
    });
    // Background sync started
  }
  
  /// Stop background sync
  static void stop() {
    _syncTimer?.cancel();
    _syncTimer = null;
    // Background sync stopped
  }
  
  /// Pause sync when app goes to background (to save battery)
  static void pauseForBackground() {
    _isAppInForeground = false;
    _syncTimer?.cancel();
    _syncTimer = null;
    // Background sync paused for battery optimization
  }
  
  /// Resume sync when app comes to foreground
  static void resumeForForeground() {
    _isAppInForeground = true;
    if (_syncTimer == null) {
      start();
    }
    // Background sync resumed
  }
  
  /// Perform background sync
  static Future<void> _performBackgroundSync() async {
    if (_isSyncing) {
      // Already syncing, skipping
      return;
    }
    
    try {
      _isSyncing = true;
      // Starting background sync
      
      // Check if we should sync
      if (!await _shouldSync()) {
        // Skipping sync - conditions not met
        return;
      }
      
      // Perform incremental sync
      await _performIncrementalSync();
      
      // Update last sync time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastSyncKey, DateTime.now().millisecondsSinceEpoch);
      
      // Background sync completed
    } catch (e) {
      // Error during background sync
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
        // No valid session, skipping sync
        return false;
      }
      
      // Check network connectivity
      final isOnline = await _checkConnectivity();
      if (!isOnline) {
        // No network connection, skipping sync
        return false;
      }
      
      // Check if enough time has passed since last sync (minimum 3 hours)
      final prefs = await SharedPreferences.getInstance();
      final lastSyncMs = prefs.getInt(_lastSyncKey);
      if (lastSyncMs != null) {
        final lastSync = DateTime.fromMillisecondsSinceEpoch(lastSyncMs);
        final timeSinceLastSync = DateTime.now().difference(lastSync);
        if (timeSinceLastSync < const Duration(hours: 3)) {
          // Too soon since last sync, skipping
          return false;
        }
      }
      
      return true;
    } catch (e) {
      // Error checking sync conditions
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
      
      // Incremental sync completed
    } catch (e) {
      // Error during incremental sync
    }
  }
  
  /// Perform full sync (called manually)
  static Future<void> performFullSync() async {
    if (_isSyncing) {
      // Already syncing, skipping full sync
      return;
    }
    
    try {
      _isSyncing = true;
      // Starting full sync
      
      final repo = await BooksRepository.create();
      await repo.syncAllBooksToDb(pageSize: 100);
      
      // Update last full sync time
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_lastFullSyncKey, DateTime.now().millisecondsSinceEpoch);
      
      // Full sync completed
    } catch (e) {
      // Error during full sync
    } finally {
      _isSyncing = false;
    }
  }
  
  /// Check network connectivity
  static Future<bool> _checkConnectivity() async {
    try {
      final connectivity = Connectivity();
      final result = await connectivity.checkConnectivity();
      // Check if we have any active connection
      return result.contains(ConnectivityResult.mobile) ||
          result.contains(ConnectivityResult.wifi) ||
          result.contains(ConnectivityResult.ethernet) ||
          result.contains(ConnectivityResult.vpn);
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
    // Sync history cleared
  }
}
