// lib/core/firebase_analytics_service.dart
import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:flutter/foundation.dart';

/// Service for tracking analytics using Firebase Analytics
class FirebaseAnalyticsService {
  static FirebaseAnalyticsService? _instance;
  static FirebaseAnalyticsService get instance => _instance ??= FirebaseAnalyticsService._();
  
  FirebaseAnalyticsService._();
  
  FirebaseAnalytics? _analytics;
  
  /// Initialize Firebase Analytics
  void initialize(FirebaseAnalytics analytics) {
    _analytics = analytics;
    if (kDebugMode) {
      debugPrint('[FirebaseAnalytics] Initialized');
    }
  }
  
  /// Track app open (daily active user)
  Future<void> logAppOpen() async {
    try {
      await _analytics?.logAppOpen();
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] App open logged');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] Error logging app open: $e');
      }
    }
  }
  
  /// Track screen view
  Future<void> logScreenView({required String screenName}) async {
    try {
      await _analytics?.logScreenView(screenName: screenName);
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] Screen view logged: $screenName');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] Error logging screen view: $e');
      }
    }
  }
  
  /// Track custom event
  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
  }) async {
    try {
      await _analytics?.logEvent(
        name: name,
        parameters: parameters,
      );
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] Event logged: $name');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[FirebaseAnalytics] Error logging event: $e');
      }
    }
  }
  
  /// Track book play
  Future<void> logBookPlay({required String bookId, required String bookTitle}) async {
    await logEvent(
      name: 'book_play',
      parameters: {
        'book_id': bookId,
        'book_title': bookTitle,
      },
    );
  }
  
  /// Track book download
  Future<void> logBookDownload({required String bookId}) async {
    await logEvent(
      name: 'book_download',
      parameters: {
        'book_id': bookId,
      },
    );
  }
  
  /// Get the FirebaseAnalytics instance (for advanced usage)
  FirebaseAnalytics? get analytics => _analytics;
}

