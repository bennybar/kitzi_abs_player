// lib/core/analytics_service.dart
import 'package:aptabase_flutter/aptabase_flutter.dart';
import 'package:flutter/foundation.dart';

/// Usage analytics, backed by Aptabase.
///
/// Aptabase is privacy-friendly and anonymous: there is no user id and no
/// device fingerprint, so events cannot be tied back to a person.
class AnalyticsService {
  static AnalyticsService? _instance;
  static AnalyticsService get instance => _instance ??= AnalyticsService._();

  AnalyticsService._();

  static const _appKey = 'A-US-4608344463';

  bool _ready = false;

  /// Must be awaited before any event is tracked.
  Future<void> initialize() async {
    try {
      await Aptabase.init(_appKey);
      _ready = true;
      if (kDebugMode) debugPrint('[Analytics] Aptabase initialized');
    } catch (e) {
      // Analytics must never take the app down.
      if (kDebugMode) debugPrint('[Analytics] init failed: $e');
    }
  }

  Future<void> logEvent({
    required String name,
    Map<String, Object>? parameters,
  }) async {
    if (!_ready) return;
    try {
      Aptabase.instance.trackEvent(name, parameters);
      if (kDebugMode) debugPrint('[Analytics] $name');
    } catch (e) {
      if (kDebugMode) debugPrint('[Analytics] Error logging $name: $e');
    }
  }

  /// Daily active user.
  Future<void> logAppOpen() => logEvent(name: 'app_open');

  Future<void> logScreenView({required String screenName}) =>
      logEvent(name: 'screen_view', parameters: {'screen': screenName});

  Future<void> logBookPlay({
    required String bookId,
    required String bookTitle,
  }) => logEvent(
    name: 'book_play',
    parameters: {'book_id': bookId, 'book_title': bookTitle},
  );

  Future<void> logBookDownload({required String bookId}) =>
      logEvent(name: 'book_download', parameters: {'book_id': bookId});
}
