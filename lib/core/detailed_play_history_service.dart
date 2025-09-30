// lib/core/detailed_play_history_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

/// Detailed play session entry
class PlaySession {
  final String bookId;
  final String bookTitle;
  final String? author;
  final String? narrator;
  final String? coverUrl;
  final double startPositionSeconds;
  final double playDurationSeconds;
  final DateTime timestamp;

  PlaySession({
    required this.bookId,
    required this.bookTitle,
    this.author,
    this.narrator,
    this.coverUrl,
    required this.startPositionSeconds,
    required this.playDurationSeconds,
    required this.timestamp,
  });

  Map<String, dynamic> toJson() => {
        'bookId': bookId,
        'bookTitle': bookTitle,
        'author': author,
        'narrator': narrator,
        'coverUrl': coverUrl,
        'startPositionSeconds': startPositionSeconds,
        'playDurationSeconds': playDurationSeconds,
        'timestamp': timestamp.millisecondsSinceEpoch,
      };

  factory PlaySession.fromJson(Map<String, dynamic> json) => PlaySession(
        bookId: json['bookId'] as String,
        bookTitle: json['bookTitle'] as String,
        author: json['author'] as String?,
        narrator: json['narrator'] as String?,
        coverUrl: json['coverUrl'] as String?,
        startPositionSeconds: (json['startPositionSeconds'] as num).toDouble(),
        playDurationSeconds: (json['playDurationSeconds'] as num).toDouble(),
        timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      );
}

/// Service to track detailed play sessions
class DetailedPlayHistoryService {
  static const String _sessionHistoryKey = 'detailed_play_sessions_v1';
  static const String _enabledKey = 'detailed_play_history_enabled';
  static const int _maxHistorySize = 30;

  /// Check if detailed play history is enabled
  static Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(_enabledKey) ?? false; // Disabled by default
    } catch (_) {
      return false;
    }
  }

  /// Enable or disable detailed play history
  static Future<void> setEnabled(bool enabled) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_enabledKey, enabled);
    } catch (_) {}
  }

  /// Add a new play session
  static Future<void> addSession(PlaySession session) async {
    // Only track if enabled
    if (!await isEnabled()) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getStringList(_sessionHistoryKey) ?? [];

      // Add new session to the beginning
      historyJson.insert(0, jsonEncode(session.toJson()));

      // Keep only the most recent sessions
      if (historyJson.length > _maxHistorySize) {
        historyJson.removeRange(_maxHistorySize, historyJson.length);
      }

      await prefs.setStringList(_sessionHistoryKey, historyJson);
    } catch (e) {
      print('Failed to add play session: $e');
    }
  }

  /// Get all play sessions (most recent first)
  static Future<List<PlaySession>> getSessions() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyJson = prefs.getStringList(_sessionHistoryKey) ?? [];

      final sessions = <PlaySession>[];
      for (final item in historyJson) {
        try {
          final data = jsonDecode(item) as Map<String, dynamic>;
          sessions.add(PlaySession.fromJson(data));
        } catch (e) {
          print('Failed to parse play session: $e');
          continue;
        }
      }

      return sessions;
    } catch (e) {
      print('Failed to get play sessions: $e');
      return [];
    }
  }

  /// Clear all play sessions
  static Future<void> clearHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_sessionHistoryKey);
    } catch (_) {}
  }

  /// Get total play time for a specific book (in seconds)
  static Future<double> getTotalPlayTimeForBook(String bookId) async {
    try {
      final sessions = await getSessions();
      double total = 0;
      for (final session in sessions) {
        if (session.bookId == bookId) {
          total += session.playDurationSeconds;
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Get number of times a book was played
  static Future<int> getPlayCountForBook(String bookId) async {
    try {
      final sessions = await getSessions();
      return sessions.where((s) => s.bookId == bookId).length;
    } catch (_) {
      return 0;
    }
  }
}

