import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

/// Represents a single play history entry
class PlayHistoryEntry {
  final int id;
  final String bookId;
  final String bookTitle;
  final String? author;
  final String? narrator;
  final double progress; // 0.0 to 1.0
  final double currentTime; // seconds played
  final double totalDuration; // total seconds
  final String? coverUrl;
  final DateTime timestamp;

  PlayHistoryEntry({
    required this.id,
    required this.bookId,
    required this.bookTitle,
    this.author,
    this.narrator,
    required this.progress,
    required this.currentTime,
    required this.totalDuration,
    this.coverUrl,
    required this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'book_id': bookId,
      'book_title': bookTitle,
      'author': author,
      'narrator': narrator,
      'progress': progress,
      'current_time': currentTime,
      'total_duration': totalDuration,
      'cover_url': coverUrl,
      'timestamp': timestamp.toIso8601String(),
    };
  }

  factory PlayHistoryEntry.fromMap(Map<String, dynamic> map) {
    return PlayHistoryEntry(
      id: map['id'] as int,
      bookId: map['book_id'] as String,
      bookTitle: map['book_title'] as String,
      author: map['author'] as String?,
      narrator: map['narrator'] as String?,
      progress: (map['progress'] as num?)?.toDouble() ?? 0.0,
      currentTime: (map['current_time'] as num?)?.toDouble() ?? 0.0,
      totalDuration: (map['total_duration'] as num?)?.toDouble() ?? 0.0,
      coverUrl: map['cover_url'] as String?,
      timestamp: DateTime.parse(map['timestamp'] as String),
    );
  }
}

/// Repository for managing play history
class PlayHistoryRepository {
  Database? _db;
  SharedPreferences? _prefs;

  static const String _tableName = 'play_history';
  static const String _limitKey = 'play_history_limit';
  static const int _defaultLimit = 30;

  /// Initialize the database
  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'kitzi_play_history.db');

    _db = await openDatabase(
      path,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE $_tableName (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            book_id TEXT NOT NULL,
            book_title TEXT NOT NULL,
            author TEXT,
            narrator TEXT,
            progress REAL NOT NULL,
            current_time REAL NOT NULL,
            total_duration REAL NOT NULL,
            cover_url TEXT,
            timestamp TEXT NOT NULL
          )
        ''');
        // Create index on timestamp for efficient sorting
        await db.execute(
          'CREATE INDEX idx_timestamp ON $_tableName (timestamp DESC)',
        );
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // Add new columns for existing installations
          await db.execute('ALTER TABLE $_tableName ADD COLUMN current_time REAL DEFAULT 0');
          await db.execute('ALTER TABLE $_tableName ADD COLUMN total_duration REAL DEFAULT 0');
          await db.execute('ALTER TABLE $_tableName ADD COLUMN cover_url TEXT');
        }
      },
      version: 2,
    );
  }

  /// Get the current history limit setting
  int getHistoryLimit() {
    return _prefs?.getInt(_limitKey) ?? _defaultLimit;
  }

  /// Set the history limit
  Future<void> setHistoryLimit(int limit) async {
    await _prefs?.setInt(_limitKey, limit);
    // Trim to new limit
    await _trimHistory(limit);
  }

  /// Add a new play history entry (always creates new entry, no deduplication)
  Future<void> addEntry({
    required String bookId,
    required String bookTitle,
    String? author,
    String? narrator,
    required double progress,
    required double currentTime,
    required double totalDuration,
    String? coverUrl,
  }) async {
    if (_db == null) {
      debugPrint('PlayHistory: DB not initialized');
      return;
    }

    try {
      // Always insert new entry (never replace - save every play() call)
      await _db!.insert(
        _tableName,
        {
          'book_id': bookId,
          'book_title': bookTitle,
          'author': author,
          'narrator': narrator,
          'progress': progress,
          'current_time': currentTime,
          'total_duration': totalDuration,
          'cover_url': coverUrl,
          'timestamp': DateTime.now().toIso8601String(),
        },
      );

      // Trim to limit
      final limit = getHistoryLimit();
      await _trimHistory(limit);
    } catch (e) {
      debugPrint('PlayHistory: Error adding entry: $e');
    }
  }

  /// Get all history entries (newest first)
  Future<List<PlayHistoryEntry>> getHistory() async {
    if (_db == null) return [];

    try {
      final maps = await _db!.query(
        _tableName,
        orderBy: 'timestamp DESC',
        limit: getHistoryLimit(),
      );

      return maps.map((map) => PlayHistoryEntry.fromMap(map)).toList();
    } catch (e) {
      debugPrint('PlayHistory: Error getting history: $e');
      return [];
    }
  }

  /// Delete a specific entry
  Future<void> deleteEntry(int id) async {
    if (_db == null) return;

    try {
      await _db!.delete(
        _tableName,
        where: 'id = ?',
        whereArgs: [id],
      );
    } catch (e) {
      debugPrint('PlayHistory: Error deleting entry: $e');
    }
  }

  /// Clear all history
  Future<void> clearAll() async {
    if (_db == null) return;

    try {
      await _db!.delete(_tableName);
    } catch (e) {
      debugPrint('PlayHistory: Error clearing history: $e');
    }
  }

  /// Trim history to the specified limit
  Future<void> _trimHistory(int limit) async {
    if (_db == null) return;

    try {
      // Delete entries beyond the limit
      await _db!.execute('''
        DELETE FROM $_tableName
        WHERE id NOT IN (
          SELECT id FROM $_tableName
          ORDER BY timestamp DESC
          LIMIT ?
        )
      ''', [limit]);
    } catch (e) {
      debugPrint('PlayHistory: Error trimming history: $e');
    }
  }

  /// Close the database
  Future<void> dispose() async {
    await _db?.close();
    _db = null;
  }
}
