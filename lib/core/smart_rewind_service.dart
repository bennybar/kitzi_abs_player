import 'package:shared_preferences/shared_preferences.dart';

/// Provides Smart Rewind behavior based on pause duration.
///
/// Rules (can be extended later):
/// - < 10s pause: rewind 3s
/// - 10s - 30s pause: rewind 5s (inclusive)
/// - >= 2 minutes pause: rewind 30s
/// - Otherwise: 0s
///
/// Rewind is applied when resuming/playing after a pause. Feature is disabled by default.
class SmartRewindService {
  static const String _kEnabled = 'smart_rewind_enabled';
  static const String _kLastPauseMs = 'smart_rewind_last_pause_ms';

  SmartRewindService._();
  static final SmartRewindService instance = SmartRewindService._();

  /// Whether smart rewind is enabled (stored in SharedPreferences). Default false.
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_kEnabled) ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Set smart rewind enabled/disabled.
  Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kEnabled, enabled);
    } catch (_) {}
  }

  /// Persist the last pause timestamp (millisecondsSinceEpoch).
  Future<void> recordPauseNow() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kLastPauseMs, DateTime.now().millisecondsSinceEpoch);
    } catch (_) {}
  }

  /// Compute rewind to apply based on the elapsed time since last pause.
  /// Returns a Duration that should be subtracted (nudge backwards) on resume/play.
  Future<Duration> computeRewind() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastPauseMs = prefs.getInt(_kLastPauseMs);
      if (lastPauseMs == null || lastPauseMs <= 0) return Duration.zero;

      final elapsed = DateTime.now().millisecondsSinceEpoch - lastPauseMs;
      if (elapsed < 0) return Duration.zero;

      final elapsedDur = Duration(milliseconds: elapsed);

      if (elapsedDur < const Duration(seconds: 10)) {
        return const Duration(seconds: 3);
      }
      if (elapsedDur <= const Duration(seconds: 30)) {
        return const Duration(seconds: 5);
      }
      if (elapsedDur >= const Duration(minutes: 2)) {
        return const Duration(seconds: 30);
      }
      return Duration.zero;
    } catch (_) {
      return Duration.zero;
    }
  }
}

// (Duplicate implementation removed)
