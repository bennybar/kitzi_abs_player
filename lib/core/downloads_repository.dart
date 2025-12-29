// lib/core/downloads_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_repository.dart';
import 'playback_repository.dart';
import 'download_storage.dart';
import 'notification_service.dart';
import 'books_repository.dart';
import 'streaming_cache_service.dart';
import 'session_logger_service.dart';

class ItemProgress {
  final String libraryItemId;
  final String status; // queued | running | complete | canceled | failed | none
  final double progress; // 0..1
  final int totalTasks; // total tracks for this item
  final int completed; // number of locally downloaded tracks

  const ItemProgress({
    required this.libraryItemId,
    required this.status,
    required this.progress,
    required this.totalTasks,
    required this.completed,
  });
}

class _DlTrack {
  final int index;
  final String fileId;
  final String mimeType;
  _DlTrack({required this.index, required this.fileId, required this.mimeType});
}

class DownloadsRepository {
  DownloadsRepository(this._auth, this._playback, {BooksRepository? booksRepo})
      : _booksRepo = booksRepo;
  final AuthRepository _auth;
  final PlaybackRepository _playback;
  final BooksRepository? _booksRepo;
  
  static const String _lastCleanupKey = 'downloads_last_orphan_cleanup';
  static const String _cleanupLogKey = 'downloads_cleanup_log';
  static const Duration _cleanupInterval = Duration(hours: 24);
  static const int _maxLogEntries = 50; // Keep last 50 cleanup log entries

  static const _wifiOnlyKey = 'downloads_wifi_only';

  void _d(String m) {
    // Logging removed for cleaner console output
  }
  
  // Progress notification tracking
  final Map<String, String> _progressNotificationTitles = {};
  final Map<String, Timer> _progressNotificationTimers = {};

  // Plugin updates -> broadcast for UI
  Stream<TaskUpdate>? _broadcastUpdates;
  Stream<TaskUpdate> progressStream() {
    _broadcastUpdates ??= FileDownloader().updates.asBroadcastStream();
    return _broadcastUpdates!;
  }

  // Last known per-item task update cache for UI stabilization
  final Map<String, TaskUpdate> _lastItemUpdate = <String, TaskUpdate>{};
  // Last known progress (0..1) for the current running track per item
  final Map<String, double> _lastRunningProgress = <String, double>{};
  // Known taskIds per item from live updates (DB may lag)
  final Map<String, Set<String>> _itemTaskIds = <String, Set<String>>{};
  // Last time we received any update for an item
  final Map<String, DateTime> _lastUpdateAt = <String, DateTime>{};

  // Per-item aggregated progress streams
  final Map<String, StreamController<ItemProgress>> _itemCtrls = {};
  // Demux listener (UI progress)
  StreamSubscription<TaskUpdate>? _demuxSub;
  // Chaining listener (enqueue next)
  StreamSubscription<TaskUpdate>? _chainSub;
  // Prevent concurrent scheduling/enqueue for the same item
  final Set<String> _schedulingItems = <String>{};
  // Keep a short-lived queued state until task records appear
  final Map<String, DateTime> _pendingQueuedUntil = <String, DateTime>{};
  // Items explicitly canceled/blocked from auto-chaining
  final Set<String> _blockedItems = <String>{};
  static const String _blockedItemsPrefsKey = 'downloads_blocked_items_v2';
  // Per-item throttle for scheduling attempts to avoid rapid loops
  final Map<String, DateTime> _nextAllowedSchedule = <String, DateTime>{};
  // Track whether an item currently has an in-flight task we enqueued (even if DB has no record yet)
  final Set<String> _inFlightItems = <String>{};
  // Track UI-active state for an item based on live updates
  final Map<String, bool> _uiActive = <String, bool>{};
  // Items we explicitly allow to run (opt-in when user taps Download)
  final Set<String> _activeItems = <String>{};
  // Brief global halt after cancel to avoid race with plugin updates
  DateTime? _globalHaltUntil;
  // Foreground path removed; we use background_downloader exclusively
  
  // Global download queue management
  final Queue<MapEntry<String, String?>> _globalDownloadQueue = Queue<MapEntry<String, String?>>();
  bool _isProcessingGlobalQueue = false;
  final Set<String> _itemsInGlobalQueue = <String>{};
  // Track active download session ids per item to enable closing on cancel
  final Map<String, String> _downloadSessionByItem = <String, String>{};
  // Cached per-item download plan (fileIds, indices, mimeTypes) to avoid sessions entirely
  final Map<String, List<_DlTrack>> _downloadPlanByItem = <String, List<_DlTrack>>{};

  Future<void> init() async {
    // Ensure the native holding queue only releases one task at a time so we
    // never have multiple files downloading in parallel.
    try {
      await FileDownloader().configure(
        globalConfig: [
          (Config.holdingQueue, (1, 1, 1)),
        ],
      );
    } catch (e) {
      // '[DL] Error configuring holding queue: $e');
    }

    // Load persistent blocked items (ensures hard-stop even across restarts)
    await _loadBlockedItemsFromPrefs();

    // Do not auto-resume pending downloads on startup; user can resume explicitly from UI
    // Additionally, cancel any persisted tasks from previous sessions to avoid battery/storage drain
    try {
      final all = await _getAllRecordsCached(forceRefresh: true);
      final ids = all.map((r) => r.taskId).toList();
      if (ids.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(ids);
      }
      // Batch deletions with delays
      for (final r in all) {
        try { 
          await FileDownloader().database.deleteRecordWithId(r.taskId);
          if (all.length > 1) {
            await Future.delayed(const Duration(milliseconds: 10));
          }
        } catch (_) {}
      }
      // Invalidate cache after bulk deletion
      _cachedAllRecords = null;
      _cacheTimestamp = null;
    } catch (_) {}

    // Ensure global listener is active so chaining continues even when UI is closed
    _ensureChainListener();
    
    // Check for orphaned downloads (daily or on first run after 24h)
    unawaited(_checkAndCleanupOrphanedDownloads());
  }
  
  /// Cleanup orphaned download directories that are not linked to any book in the database.
  /// Runs daily or when app opens after 24 hours without cleanup.
  Future<void> _checkAndCleanupOrphanedDownloads() async {
    if (_booksRepo == null) return; // Skip if BooksRepository not available
    
    try {
      final prefs = await SharedPreferences.getInstance();
      final lastCleanupStr = prefs.getString(_lastCleanupKey);
      final now = DateTime.now();
      
      // Check if cleanup is needed (24 hours have passed or never run)
      bool shouldCleanup = false;
      if (lastCleanupStr == null) {
        shouldCleanup = true; // First run
      } else {
        try {
          final lastCleanup = DateTime.parse(lastCleanupStr);
          if (now.difference(lastCleanup) >= _cleanupInterval) {
            shouldCleanup = true;
          }
        } catch (_) {
          shouldCleanup = true; // Invalid date, run cleanup
        }
      }
      
      if (!shouldCleanup) return;
      
      _d('Starting orphaned downloads cleanup...');
      
      // Get all directories in the download base directory
      final baseDir = await DownloadStorage.baseDir();
      if (!await baseDir.exists()) {
        await prefs.setString(_lastCleanupKey, now.toIso8601String());
        return;
      }
      
      final entries = await baseDir.list(followLinks: false).toList();
      final orphanedDirs = <Directory>[];
      
      // Check each directory (which should be a libraryItemId)
      for (final entry in entries) {
        if (entry is! Directory) continue;
        
        final libraryItemId = entry.path.split(Platform.pathSeparator).last;
        
        // Check if this book exists in the database
        try {
          final book = await _booksRepo!.getBookFromDb(libraryItemId);
          if (book == null) {
            // Book not found in database - this is an orphaned download
            orphanedDirs.add(entry);
            _d('Found orphaned download directory: $libraryItemId');
          }
        } catch (e) {
          // Error checking book - skip this directory to be safe
          _d('Error checking book $libraryItemId: $e');
        }
      }
      
      // Delete orphaned directories
      int deletedCount = 0;
      for (final dir in orphanedDirs) {
        try {
          if (await dir.exists()) {
            await dir.delete(recursive: true);
            deletedCount++;
            _d('Deleted orphaned download directory: ${dir.path}');
          }
        } catch (e) {
          _d('Error deleting orphaned directory ${dir.path}: $e');
        }
      }
      
      // Update last cleanup time
      await prefs.setString(_lastCleanupKey, now.toIso8601String());
      
      // Log cleanup result
      final logEntry = {
        'timestamp': now.toIso8601String(),
        'deletedCount': deletedCount,
        'checkedCount': entries.whereType<Directory>().length,
        'message': deletedCount > 0 
            ? 'Deleted $deletedCount orphaned download directories'
            : 'No orphaned files found',
      };
      await _addCleanupLogEntry(logEntry);
      
      if (deletedCount > 0) {
        _d('Orphaned downloads cleanup complete: deleted $deletedCount directories');
      } else {
        _d('Orphaned downloads cleanup complete: no orphaned files found');
      }
    } catch (e) {
      _d('Error during orphaned downloads cleanup: $e');
      // Log error
      final logEntry = {
        'timestamp': DateTime.now().toIso8601String(),
        'deletedCount': 0,
        'checkedCount': 0,
        'message': 'Error during cleanup: $e',
      };
      await _addCleanupLogEntry(logEntry);
    }
  }
  
  /// Add a log entry to the cleanup log
  Future<void> _addCleanupLogEntry(Map<String, dynamic> entry) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logJson = prefs.getString(_cleanupLogKey);
      List<Map<String, dynamic>> logs = [];
      
      if (logJson != null && logJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(logJson) as List;
          logs = decoded.cast<Map<String, dynamic>>().toList();
        } catch (_) {
          logs = [];
        }
      }
      
      logs.insert(0, entry); // Add to beginning
      
      // Keep only last N entries
      if (logs.length > _maxLogEntries) {
        logs = logs.take(_maxLogEntries).toList();
      }
      
      await prefs.setString(_cleanupLogKey, jsonEncode(logs));
    } catch (_) {
      // Best effort - if logging fails, continue
    }
  }
  
  /// Get cleanup log entries
  static Future<List<Map<String, dynamic>>> getCleanupLog() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final logJson = prefs.getString(_cleanupLogKey);
      
      if (logJson == null || logJson.isEmpty) {
        return [];
      }
      
      final decoded = jsonDecode(logJson) as List;
      return decoded.cast<Map<String, dynamic>>().toList();
    } catch (_) {
      return [];
    }
  }

  // === Download plan (no sessions) ===
  Future<List<_DlTrack>> _ensureDownloadPlan(
    String libraryItemId, {
    String? episodeId,
    bool allowSessionFallback = true,
  }) async {
    final existing = _downloadPlanByItem[libraryItemId];
    if (existing != null && existing.isNotEmpty) return existing;

    try {
      final api = _auth.api;

      // First attempt: explicit files endpoint (no sessions)
      final filesResp = await api.request('GET', '/api/items/$libraryItemId/files');
      Map<String, dynamic>? item;
      List<dynamic>? filesList;
      if (filesResp.statusCode == 200) {
        try {
          final parsed = jsonDecode(filesResp.body);
          if (parsed is Map && parsed['files'] is List) {
            filesList = parsed['files'] as List;
          } else if (parsed is List) {
            filesList = parsed;
          }
        } catch (_) {}
      }

      // Fallback: full item (may include tracks/audioFiles)
      if (filesList == null) {
        final resp = await api.request('GET', '/api/items/$libraryItemId');
        if (resp.statusCode != 200) throw Exception('status ${resp.statusCode}');
        final bodyStr = resp.body;
        if (bodyStr.isEmpty) throw Exception('empty body');
        final parsed = jsonDecode(bodyStr);
        item = (parsed is Map && parsed['item'] is Map)
            ? (parsed['item'] as Map).cast<String, dynamic>()
            : (parsed as Map).cast<String, dynamic>();
      }

      Map<String, dynamic>? media = item != null && item['media'] is Map ? (item['media'] as Map).cast<String, dynamic>() : null;
      List<dynamic>? episodesList;
      if (episodeId != null) {
        // Try both root and under media
        if (item != null && item['episodes'] is List) episodesList = item['episodes'] as List;
        if (episodesList == null && media != null && media['episodes'] is List) {
          episodesList = media['episodes'] as List;
        }
        if (episodesList != null) {
          for (final e in episodesList) {
            if (e is Map) {
              final em = e.cast<String, dynamic>();
              final eid = (em['id'] ?? em['_id'] ?? '').toString();
              if (eid == episodeId) {
                media = em['media'] is Map ? (em['media'] as Map).cast<String, dynamic>() : em;
                break;
              }
            }
          }
        }
      }

      final tracks = <_DlTrack>[];

      if (filesList != null) {
        for (var i = 0; i < filesList.length; i++) {
          final f = filesList[i];
          if (f is! Map) continue;
          final m = f.cast<String, dynamic>();
          final fidRaw = (m['id'] ?? m['_id']);
          final fileId = fidRaw is String ? fidRaw : fidRaw?.toString();
          final idx = ((m['index'] ?? m['order'] ?? m['track'] ?? m['trackNumber'] ?? i) as num).toInt();
          final mime = (m['mimeType'] ?? m['contentType'] ?? 'audio/mpeg').toString();
          if (fileId != null && fileId.isNotEmpty) {
            tracks.add(_DlTrack(index: idx, fileId: fileId, mimeType: mime));
          }
        }
      } else if (item != null) {
        Map<String, dynamic> use = media ?? item;
        // Try common shapes
        List list;
        if (use['tracks'] is List) {
          list = (use['tracks'] as List);
          for (var i = 0; i < list.length; i++) {
            final t = list[i];
            if (t is! Map) continue;
            final m = t.cast<String, dynamic>();
            final idx = ((m['index'] ?? m['track'] ?? m['trackNumber'] ?? i) as num).toInt();
            String? fileId;
            if (m['fileId'] is String) fileId = m['fileId'] as String;
            if (fileId == null && m['file'] is Map) {
              final fm = (m['file'] as Map).cast<String, dynamic>();
              final fid = (fm['id'] ?? fm['_id']);
              if (fid is String) fileId = fid;
            }
            if (fileId == null && m['id'] is String) fileId = m['id'] as String; // some servers
            final mime = (m['mimeType'] ?? m['contentType'] ?? 'audio/mpeg').toString();
            if (fileId != null && fileId.isNotEmpty) {
              tracks.add(_DlTrack(index: idx, fileId: fileId, mimeType: mime));
            }
          }
        } else if (use['audioFiles'] is List) {
          list = (use['audioFiles'] as List);
          for (var i = 0; i < list.length; i++) {
            final f = list[i];
            if (f is! Map) continue;
            final m = f.cast<String, dynamic>();
            final fidRaw = (m['id'] ?? m['_id']);
            final fileId = fidRaw is String ? fidRaw : fidRaw?.toString();
            final idx = ((m['index'] ?? m['order'] ?? m['track'] ?? m['trackNumber'] ?? i) as num).toInt();
            final mime = (m['mimeType'] ?? m['contentType'] ?? 'audio/mpeg').toString();
            if (fileId != null && fileId.isNotEmpty) {
              tracks.add(_DlTrack(index: idx, fileId: fileId, mimeType: mime));
            }
          }
        } else if (use['files'] is List) {
          list = (use['files'] as List);
          for (var i = 0; i < list.length; i++) {
            final f = list[i];
            if (f is! Map) continue;
            final m = f.cast<String, dynamic>();
            final fidRaw = (m['id'] ?? m['_id']);
            final fileId = fidRaw is String ? fidRaw : fidRaw?.toString();
            final idx = ((m['index'] ?? m['order'] ?? m['track'] ?? m['trackNumber'] ?? i) as num).toInt();
            final mime = (m['mimeType'] ?? m['contentType'] ?? 'audio/mpeg').toString();
            if (fileId != null && fileId.isNotEmpty) {
              tracks.add(_DlTrack(index: idx, fileId: fileId, mimeType: mime));
            }
          }
        }
      }

      // Fallback: open a single session to derive fileIds from track URLs, then close it
      if (tracks.isEmpty && allowSessionFallback) {
        try {
          final open = await _playback.openSessionAndGetTracks(libraryItemId, episodeId: episodeId);
          final sessionId = open.sessionId;
          for (final t in open.tracks) {
            try {
              final u = Uri.tryParse(t.url);
              String? fileId;
              if (u != null) {
                final segs = u.pathSegments;
                // Look for "file/{id}" or "files/{id}"
                for (int i = 0; i < segs.length - 1; i++) {
                  final s = segs[i].toLowerCase();
                  if (s == 'file' || s == 'files') {
                    fileId = segs[i + 1];
                    break;
                  }
                }
                // Some servers may encode as query param
                fileId ??= u.queryParameters['fileId'] ?? u.queryParameters['id'];
              }
              if (fileId != null && fileId.isNotEmpty) {
                tracks.add(_DlTrack(index: t.index, fileId: fileId, mimeType: t.mimeType));
              }
            } catch (_) {}
          }
          // Close the session quickly; downloads don't need streaming sessions
          if (sessionId != null && sessionId.isNotEmpty) {
            unawaited(_playback.closeSessionById(sessionId));
          }
        } catch (_) {}
      }

      tracks.sort((a, b) => a.index.compareTo(b.index));
      _downloadPlanByItem[libraryItemId] = tracks;
      return tracks;
    } catch (_) {
      return _downloadPlanByItem[libraryItemId] ?? const <_DlTrack>[];
    }
  }

  Future<int> _getTotalTracksWithoutSession(
    String libraryItemId, {
    String? episodeId,
    bool allowSessionFallback = true,
  }) async {
    final plan = await _ensureDownloadPlan(
      libraryItemId,
      episodeId: episodeId,
      allowSessionFallback: allowSessionFallback,
    );
    return plan.length;
  }

  String _downloadUrlFor(String libraryItemId, String fileId, {String? episodeId}) {
    final base = _auth.api.baseUrl ?? '';
    // Use singular 'file' segment as commonly used by ABS; adjust if server expects 'files'
    return '$base/api/items/$libraryItemId/file/$fileId/download';
  }

  /// Start (or get) an aggregated progress stream for a specific book.
  /// Uses a quick, local-only progress snapshot on listen to avoid hitting
  /// the server (which can trigger book upserts).
  Stream<ItemProgress> watchItemProgress(String libraryItemId) {
    final ctrl = _itemCtrls.putIfAbsent(
      libraryItemId,
      () => StreamController<ItemProgress>.broadcast(onListen: () async {
        final snap = await _computeItemProgressQuick(libraryItemId);
        (_itemCtrls[libraryItemId]!).add(snap);
      }),
    );

    // Demux plugin updates -> per-item controllers
    _demuxSub ??= progressStream().listen((u) async {
      final meta = u.task.metaData ?? '';
      final id = _extractItemId(meta);
      if (id == null) return;
      _lastItemUpdate[id] = u;
      _lastUpdateAt[id] = DateTime.now();
      // Track task id for this item
      try {
        final tid = u.task.taskId;
        final set = _itemTaskIds.putIfAbsent(id, () => <String>{});
        set.add(tid);
      } catch (_) {}
      // Update UI active flags and in-flight state based on update type
      try {
        if (u is TaskProgressUpdate) {
          _uiActive[id] = true;
          _inFlightItems.add(id);
          _lastRunningProgress[id] = (u.progress ?? 0.0).clamp(0.0, 1.0);
        } else if (u is TaskStatusUpdate) {
          switch (u.status) {
            case TaskStatus.running:
            case TaskStatus.enqueued:
              _uiActive[id] = true;
              _inFlightItems.add(id);
              break;
            case TaskStatus.complete:
            case TaskStatus.failed:
            case TaskStatus.canceled:
              _uiActive[id] = false;
              _inFlightItems.remove(id);
              _lastRunningProgress.remove(id);
              break;
            default:
              break;
          }
        }
      } catch (_) {}
      if (_itemCtrls.containsKey(id)) {
        final snap = await _computeItemProgressQuick(id);
        final c = _itemCtrls[id];
        if (c != null && !c.isClosed) c.add(snap);
      }
    });

    return ctrl.stream;
  }

  /// Compute item progress using local data only (no server calls).
  Future<ItemProgress> _computeItemProgressQuick(String libraryItemId) async {
    try {
      final hasLocal = await hasLocalDownloads(libraryItemId);
      final recs = await _recordsForItem(libraryItemId);
      final completedLocal = await _countLocalFiles(libraryItemId);

      final runningProgress = _lastRunningProgress[libraryItemId] ?? 0.0;
      final totalTracks = recs.length;

      double value;
      if (totalTracks > 0) {
        final completedTracks = recs.where((r) => r.status == TaskStatus.complete).length;
        value = ((completedTracks.toDouble()) + runningProgress).clamp(0.0, totalTracks.toDouble()) /
            totalTracks.toDouble();
      } else {
        value = runningProgress;
        if (value == 0.0 && completedLocal > 0) value = 1.0;
      }

      String status = 'none';
      final hasRunning = recs.any((r) => r.status == TaskStatus.running);
      final hasQueued = recs.any((r) => r.status == TaskStatus.enqueued);
      final hasFailed = recs.any((r) => r.status == TaskStatus.failed);
      if (hasRunning) {
        status = 'running';
      } else if (hasQueued || _uiActive[libraryItemId] == true || _itemsInGlobalQueue.contains(libraryItemId)) {
        status = 'queued';
      } else if (hasFailed) {
        status = 'failed';
      } else if (hasLocal && completedLocal > 0) {
        status = 'complete';
        value = 1.0;
      }

      if ((status == 'running' || status == 'queued') && value < 0.01) {
        value = 0.01;
      }

      return ItemProgress(
        libraryItemId: libraryItemId,
        status: status,
        progress: value.clamp(0.0, 1.0),
        totalTasks: totalTracks,
        completed: completedLocal,
      );
    } catch (_) {
      return ItemProgress(
        libraryItemId: libraryItemId,
        status: 'none',
        progress: 0.0,
        totalTasks: 0,
        completed: 0,
      );
    }
  }

  /// Queue all tracks of an item for download (Wi-Fi rule from prefs).
  /// If the item already has local files AND no active tasks -> no-op (UI should show Delete).
  Future<void> enqueueItemDownloads(
      String libraryItemId, {
        String? episodeId,
        String? displayTitle,
      }) async {
    // Unblock if user explicitly re-enqueues
    _blockedItems.remove(libraryItemId);
    
    // Mark this item as allowed/active
    _activeItems.add(libraryItemId);
    _blockedItems.remove(libraryItemId);
    await _persistBlockedItems();

    final title = (displayTitle != null && displayTitle.isNotEmpty)
        ? displayTitle
        : 'Audiobook';

    // Add to background queue
    if (!_itemsInGlobalQueue.contains(libraryItemId)) {
      _globalDownloadQueue.add(MapEntry(libraryItemId, episodeId));
      _itemsInGlobalQueue.add(libraryItemId);
      _d('Added $libraryItemId to global queue. Queue length: ${_globalDownloadQueue.length}');
    }
    
    // Show a single download notification for this book via our custom notification service
    try {
      await NotificationService.instance.showDownloadStarted(title);
      
      // Start showing progress updates
      _startProgressNotifications(libraryItemId, title);
    } catch (_) {}
    
    // Immediately publish a queued snapshot so UI updates without waiting for DB
    try {
      _pendingQueuedUntil[libraryItemId] = DateTime.now().add(const Duration(seconds: 12));
      int totalTracks = await _getTotalTracksWithoutSession(libraryItemId, episodeId: episodeId);
      if (totalTracks == 0) {
        // Fallback to previous method if metadata missing
        try { totalTracks = await _playback.getTotalTrackCount(libraryItemId); } catch (_) {}
      }
      final snap = ItemProgress(
        libraryItemId: libraryItemId,
        status: 'queued',
        progress: totalTracks > 0 ? 0.01 : 0.0,
        totalTasks: totalTracks,
        completed: 0,
      );
      final ctrl = _itemCtrls[libraryItemId];
      if (ctrl != null && !ctrl.isClosed) ctrl.add(snap);
    } catch (_) {}

    // Start processing the global queue
    _processGlobalQueue();
  }

  /// Cancel all queued/running tasks for a book.
  Future<void> cancelForItem(String libraryItemId) async {
    // Block this item from auto-chaining immediately
    _blockedItems.add(libraryItemId);
    await _persistBlockedItems();
    _pendingQueuedUntil.remove(libraryItemId);
    _inFlightItems.remove(libraryItemId);
    _uiActive[libraryItemId] = false;
    _activeItems.remove(libraryItemId);
    // Clear any cached progress/updates so UI doesn't show stale percentages
    _lastRunningProgress.remove(libraryItemId);
    _lastItemUpdate.remove(libraryItemId);
    _lastUpdateAt.remove(libraryItemId);
    // Brief global halt
    _globalHaltUntil = DateTime.now().add(const Duration(milliseconds: 1500));
    // Remove any queued entries for this item
    _globalDownloadQueue.removeWhere((entry) => entry.key == libraryItemId);
    _itemsInGlobalQueue.remove(libraryItemId);
    
    // Cancel any active/enqueued tasks for this item and remove any downloaded files immediately
    try {
      // Cancel by group, DB, and live-tracked task ids to be thorough
      final liveIds = (_itemTaskIds[libraryItemId] ?? const <String>{}).toList();
      if (liveIds.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(liveIds);
      }
      final all = await _getAllRecordsCached();
      final groupIds = all
          .where((r) => (r.task.group ?? '').trim() == 'book-$libraryItemId' ||
              _extractItemId(r.task.metaData ?? '') == libraryItemId)
          .map((r) => r.taskId)
          .toList();
      if (groupIds.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(groupIds);
      }
      // Clean DB records for this item with delays
      final itemRecords = all.where((r) => _extractItemId(r.task.metaData ?? '') == libraryItemId).toList();
      for (final r in itemRecords) {
        try { 
          await FileDownloader().database.deleteRecordWithId(r.taskId);
          if (itemRecords.length > 1) {
            await Future.delayed(const Duration(milliseconds: 10));
          }
        } catch (_) {}
      }
      // Invalidate cache after deletion
      _cachedAllRecords = null;
      _cacheTimestamp = null;
      // Best-effort: remove partially written current track
      try {
        final last = _lastItemUpdate[libraryItemId];
        final fn = last?.task.filename ?? '';
        bool shouldDelete = false;
        if (last is TaskProgressUpdate) {
          shouldDelete = (last.progress ?? 0.0) < 0.999;
        } else if (last is TaskStatusUpdate) {
          shouldDelete = last.status == TaskStatus.running || last.status == TaskStatus.enqueued;
        }
        if (fn.isNotEmpty && shouldDelete) {
          final dir = await _itemDir(libraryItemId);
          final f = File('${dir.path}/$fn');
          if (await f.exists()) {
            await f.delete();
          }
        }
        // Also remove any leftover temp/part files
        final dir = await _itemDir(libraryItemId);
        if (await dir.exists()) {
          final entries = await dir.list().toList();
          for (final e in entries) {
            if (e is File) {
              final name = e.path.split('/').last.toLowerCase();
              if (name.endsWith('.part') || name.endsWith('.tmp')) {
                try { await e.delete(); } catch (_) {}
              }
            }
          }
        }
      } catch (_) {}

      // Remove entire item directory (all downloaded tracks) on cancel per requirement
      try {
        final dir = await _itemDir(libraryItemId);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (_) {}
    } catch (_) {}
    
    // Small debounce to allow plugin to settle
    await Future.delayed(const Duration(milliseconds: 150));
    _notifyItem(libraryItemId);
    // Hide download notification on cancel
    try { await NotificationService.instance.hideDownloadNotification(); } catch (_) {}
    
    // Stop progress notifications
    _stopProgressNotifications(libraryItemId);
    // Close any open download session for this item
    // CRITICAL: Only close if it's NOT the active playback session to preserve play position
    try {
      final sid = _downloadSessionByItem.remove(libraryItemId);
      if (sid != null && sid.isNotEmpty) {
        // Check if this is the currently playing item - if so, don't close the session
        final np = _playback.nowPlaying;
        final isCurrentlyPlaying = np != null && np.libraryItemId == libraryItemId;
        if (!isCurrentlyPlaying) {
          unawaited(_playback.closeSessionById(sid));
        }
      }
    } catch (_) {}
  }

  /// Remove local files for a book (and cancel tasks just in case).
  /// CRITICAL: Preserves play position if the item is currently playing.
  Future<void> deleteLocal(String libraryItemId) async {
    // CRITICAL: Check if this item is currently playing - if so, pause first
    final np = _playback.nowPlaying;
    final isCurrentlyPlaying = np != null && np.libraryItemId == libraryItemId;
    Duration? savedPosition;
    bool wasPlaying = false;
    int? savedTrackIndex;
    
    if (isCurrentlyPlaying) {
      // PAUSE playback first to prevent jumping around during deletion
      wasPlaying = _playback.player.playing;
      if (wasPlaying) {
        await _playback.pause();
      }
      // Save current playback state
      savedPosition = _playback.player.position;
      savedTrackIndex = np.currentIndex;
      
      // Show notification
      try {
        await NotificationService.instance.showDownloadComplete('Switching to streaming...');
      } catch (_) {}
    }
    
    // Wait a moment for pause to settle
    await Future.delayed(const Duration(milliseconds: 200));
    
    // Do all deletions at once
    await cancelForItem(libraryItemId);
    final dir = await _itemDir(libraryItemId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    
    // Remove all task records in one batch
    try {
      final recs = await _recordsForItem(libraryItemId);
      // Collect all task IDs first
      final taskIds = recs.map((r) => r.taskId).toList();
      // Delete all at once (no delays between - we're paused)
      for (final taskId in taskIds) {
        try {
          await FileDownloader().database.deleteRecordWithId(taskId);
        } catch (_) {}
      }
      // Invalidate cache after deletion
      _cachedAllRecords = null;
      _cacheTimestamp = null;
    } catch (_) {}
    
    _pendingQueuedUntil.remove(libraryItemId);
    _blockedItems.add(libraryItemId);
    _lastRunningProgress.remove(libraryItemId);
    _lastItemUpdate.remove(libraryItemId);
    _lastUpdateAt.remove(libraryItemId);
    _notifyItem(libraryItemId);
    
    // CRITICAL: If this was the playing item, switch back to streaming and restore position
    if (isCurrentlyPlaying && savedPosition != null && savedTrackIndex != null) {
      // Wait a moment for DB operations to complete
      await Future.delayed(const Duration(milliseconds: 300));
      
      try {
        final currentNp = _playback.nowPlaying;
        if (currentNp != null && currentNp.libraryItemId == libraryItemId) {
          // Check if tracks are still local (stale after deletion)
          final hasLocalTracks = currentNp.tracks.any((t) => t.isLocal);
          
          if (hasLocalTracks) {
            // Need to switch back to streaming tracks
            try {
              // Re-open streaming session to get fresh streaming tracks
              final open = await _playback.openSessionAndGetTracks(libraryItemId, episodeId: currentNp.episodeId);
              // Update tracks to streaming - seekGlobal will handle this
              await _playback.seekGlobal(savedPosition!, reportNow: false);
            } catch (e) {
              // If session open fails, try to reload the item
              try {
                await _playback.playItem(libraryItemId, episodeId: currentNp.episodeId, context: null);
                await Future.delayed(const Duration(milliseconds: 200));
                await _playback.seekGlobal(savedPosition!, reportNow: false);
              } catch (_) {
                // Last resort: just try to seek on current tracks
                await _playback.seekGlobal(savedPosition!, reportNow: false);
              }
            }
          } else {
            // Already on streaming tracks, just restore position
            await _playback.seekGlobal(savedPosition!, reportNow: false);
          }
          
          // RESUME playback if it was playing before
          if (wasPlaying) {
            await Future.delayed(const Duration(milliseconds: 200));
            await _playback.player.play();
          }
        }
      } catch (_) {
        // Best effort - if restore fails, at least we tried
      }
    }
  }

  Future<void> cancelAll() async {
    // Cancel all active downloads
    final records = await _getAllRecordsCached(forceRefresh: true);
    final ids = records.map((r) => r.taskId).toList();
    if (ids.isNotEmpty) {
      await FileDownloader().cancelTasksWithIds(ids);
    }
    
    // Clear the global queue completely
    _globalDownloadQueue.clear();
    _itemsInGlobalQueue.clear();
    _isProcessingGlobalQueue = false;
    
    // Block all items from auto-chaining
    final allItemIds = await listTrackedItemIds();
    for (final id in allItemIds) {
      _blockedItems.add(id);
      _pendingQueuedUntil.remove(id);
      _inFlightItems.remove(id);
      _uiActive[id] = false;
      _activeItems.remove(id);
    }
    await _persistBlockedItems();
    
    _d('Canceled all downloads and cleared global queue');
    // Hide download notification on cancel all
    try { await NotificationService.instance.hideDownloadNotification(); } catch (_) {}
    
    // Stop all progress notifications
    for (final itemId in _progressNotificationTitles.keys.toList()) {
      _stopProgressNotifications(itemId);
    }
    // Close all known download sessions
    try {
      final ids = List<String>.from(_downloadSessionByItem.values);
      _downloadSessionByItem.clear();
      for (final sid in ids) {
        if (sid.isNotEmpty) {
          unawaited(_playback.closeSessionById(sid));
        }
      }
    } catch (_) {}
  }

  /// Completely wipe all download metadata and internal caches (used on logout).
  Future<void> wipeAllData() async {
    try {
      final records = await _getAllRecordsCached(forceRefresh: true);
      for (final r in records) {
        try {
          await FileDownloader().database.deleteRecordWithId(r.taskId);
          if (records.length > 1) {
            await Future.delayed(const Duration(milliseconds: 5));
          }
        } catch (_) {}
      }
    } catch (_) {}
    _cachedAllRecords = null;
    _cacheTimestamp = null;

    _globalDownloadQueue.clear();
    _itemsInGlobalQueue.clear();
    _inFlightItems.clear();
    _pendingQueuedUntil.clear();
    _activeItems.clear();
    _uiActive.clear();
    _downloadPlanByItem.clear();
    _blockedItems.clear();
    await _persistBlockedItems();

    for (final timer in _progressNotificationTimers.values) {
      timer.cancel();
    }
    _progressNotificationTimers.clear();
    _progressNotificationTitles.clear();
    _downloadSessionByItem.clear();

    // Notify listeners that items have been cleared
    for (final entry in _itemCtrls.entries) {
      if (!entry.value.isClosed) {
        entry.value.add(ItemProgress(
          libraryItemId: entry.key,
          status: 'none',
          progress: 0,
          totalTasks: 0,
          completed: 0,
        ));
      }
    }
  }

  Future<List<TaskRecord>> listAll() async {
    return await _getAllRecordsCached();
  }

  /// Best-effort total bytes estimate for an item. Tries /files endpoint first,
  /// then falls back to HEAD (or ranged GET) on each download URL.
  Future<int?> estimateTotalBytes(String libraryItemId, {String? episodeId}) async {
    try {
      final api = _auth.api;
      int sum = 0;
      // 1) Try explicit files endpoint
      try {
        final r = await api.request('GET', '/api/items/$libraryItemId/files');
        if (r.statusCode == 200) {
          final data = jsonDecode(r.body);
          List list;
          if (data is Map && data['files'] is List) {
            list = data['files'] as List;
          } else if (data is List) list = data;
          else list = const [];
          for (final it in list) {
            if (it is Map) {
              final m = it.cast<String, dynamic>();
              final v = m['size'] ?? m['bytes'] ?? m['fileSize'] ?? (m['stat'] is Map ? (m['stat']['size']) : null) ?? m['sizeBytes'];
              if (v is num) {
                sum += v.toInt();
              } else if (v is String) {
                final n = int.tryParse(v);
                if (n != null) sum += n;
              }
            }
          }
          if (sum > 0) return sum;
        }
      } catch (_) {}

      // 2) Fall back: resolve plan and probe each URL for Content-Length
      final plan = await _ensureDownloadPlan(libraryItemId, episodeId: episodeId);
      if (plan.isEmpty) return null;

      final access = await _auth.api.accessToken();
      final client = HttpClient();
      client.autoUncompress = false;

      Future<int> probe(String url) async {
        // Prefer HEAD; fall back to ranged GET
        try {
          final req = await client.openUrl('HEAD', Uri.parse(url));
          if (access != null && access.isNotEmpty) req.headers.add('Authorization', 'Bearer $access');
          final resp = await req.close();
          final cl = resp.headers.value(HttpHeaders.contentLengthHeader);
          if (cl != null) {
            final n = int.tryParse(cl);
            if (n != null && n > 0) return n;
          }
        } catch (_) {}
        try {
          final req = await client.openUrl('GET', Uri.parse(url));
          if (access != null && access.isNotEmpty) req.headers.add('Authorization', 'Bearer $access');
          req.headers.add('Range', 'bytes=0-0');
          final resp = await req.close();
          final cr = resp.headers.value('content-range'); // bytes 0-0/12345
          if (cr != null && cr.contains('/')) {
            final totalStr = cr.split('/').last.trim();
            final n = int.tryParse(totalStr);
            if (n != null && n > 0) return n;
          }
          final cl = resp.headers.value(HttpHeaders.contentLengthHeader);
          if (cl != null) {
            final n = int.tryParse(cl);
            if (n != null && n > 0) return n;
          }
        } catch (_) {}
        return 0;
      }

      // Limit concurrency
      const int maxParallel = 8;
      int idx = 0;
      while (idx < plan.length) {
        final batch = plan.skip(idx).take(maxParallel).toList();
        final futures = batch.map((t) => probe(_downloadUrlFor(libraryItemId, t.fileId, episodeId: episodeId)));
        final results = await Future.wait(futures);
        for (final n in results) {
          sum += n;
        }
        idx += batch.length;
      }
      try { client.close(force: true); } catch (_) {}
      return sum > 0 ? sum : null;
    } catch (_) {
      return null;
    }
  }

  /// Resume serial downloads for all tracked items (if applicable)
  Future<void> resumeAll() async {
    final ids = await listTrackedItemIds();
    for (final id in ids) {
      // Unblock items that were previously blocked
      _blockedItems.remove(id);
      // Add back to global queue if they have pending downloads
      if (!_itemsInGlobalQueue.contains(id)) {
        _globalDownloadQueue.add(MapEntry(id, null));
        _itemsInGlobalQueue.add(id);
      }
    }
    // Start processing the queue
    _processGlobalQueue();
  }

  /// Get current queue status for debugging
  Map<String, dynamic> getQueueStatus() {
    return {
      'queueLength': _globalDownloadQueue.length,
      'itemsInQueue': _itemsInGlobalQueue.toList(),
      'isProcessing': _isProcessingGlobalQueue,
      'blockedItems': _blockedItems.toList(),
    };
  }

  /// Returns true if there are any active or queued downloads
  Future<bool> hasActiveOrQueued() async {
    try {
      final recs = await _getAllRecordsCached();
      final hasDbActive = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
      if (hasDbActive) return true;
    } catch (_) {}
    if (_inFlightItems.isNotEmpty) return true;
    if (_itemsInGlobalQueue.isNotEmpty) return true;
    if (_uiActive.values.any((v) => v == true)) return true;
    return false;
  }

  /// Return a union of itemIds that either have local files or active records.
  Future<List<String>> listTrackedItemIds() async {
    final ids = <String>{};
    // From task records
    final all = await _getAllRecordsCached();
    for (final r in all) {
      final meta = r.task.metaData ?? '';
      final id = _extractItemId(meta);
      if (id != null && id.isNotEmpty) ids.add(id);
    }
    // From local downloads via storage helper
    try {
      final localIds = await DownloadStorage.listItemIdsWithLocalDownloads();
      ids.addAll(localIds);
    } catch (_) {}
    final list = ids.toList()..sort();
    return list;
  }
  
  // === Progress notifications ===
  
  void _startProgressNotifications(String libraryItemId, String title) {
    _progressNotificationTitles[libraryItemId] = title;
    
    // Cancel any existing timer for this item
    _progressNotificationTimers[libraryItemId]?.cancel();
    
    // Start a timer to update progress notifications every 5 seconds (reduced from 2 to save battery)
    _progressNotificationTimers[libraryItemId] = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _updateProgressNotification(libraryItemId),
    );
  }
  
  void _stopProgressNotifications(String libraryItemId) {
    _progressNotificationTimers[libraryItemId]?.cancel();
    _progressNotificationTimers.remove(libraryItemId);
    _progressNotificationTitles.remove(libraryItemId);
  }
  
  Future<void> _updateProgressNotification(String libraryItemId) async {
    try {
      final title = _progressNotificationTitles[libraryItemId];
      if (title == null) return;
      
      // Get current progress for this item
      final progress = await _computeItemProgress(libraryItemId);
      final percentage = (progress.progress * 100).round();
      
      // Only update if there's meaningful progress
      if (percentage > 0 && percentage < 100) {
        await NotificationService.instance.showDownloadProgress(
          title,
          percentage,
          100,
        );
      }
    } catch (e) {
      // '[DL] Error updating progress notification: $e');
    }
  }

  // === Local files helpers ===

  Future<bool> hasLocalDownloads(String libraryItemId) async {
    final dir = await _itemDir(libraryItemId);
    if (!await dir.exists()) return false;
    try {
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      return files.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  // === Internal aggregation ===

  Future<ItemProgress> _computeItemProgress(String libraryItemId) async {
    // First check if local files exist - this is the most reliable indicator
    final hasLocal = await hasLocalDownloads(libraryItemId);
    final recs = await _recordsForItem(libraryItemId);
    int totalTracks = await _getTotalTracksWithoutSession(
      libraryItemId,
      allowSessionFallback: false,
    );
    final completedLocal = await _countLocalFiles(libraryItemId);

    // Determine per-file running progress using live cache for stability
    double runningProgress = _lastRunningProgress[libraryItemId] ?? 0.0;

    final denom = totalTracks == 0 ? 1 : totalTracks;
    double value = ((completedLocal.toDouble()) + runningProgress) / denom;
    // If item is blocked/canceled, force 0 to avoid stale '2%'
    if (_blockedItems.contains(libraryItemId) && !hasLocal) {
      value = 0.0;
    } else if (value > 0.0 && value < 0.01) {
      value = 0.01;
    }

    String status = 'none';
    // CRITICAL: Check local files first - if they exist and we have files, consider download status
    // This ensures downloaded books show "Downloaded" even if track count doesn't match exactly
    if (hasLocal && completedLocal > 0) {
      final bool hasActiveTasks =
          recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued) ||
          _uiActive[libraryItemId] == true ||
          _itemsInGlobalQueue.contains(libraryItemId) ||
          _activeItems.contains(libraryItemId);
      // If we have local files, check if we have enough files OR if total tracks is unknown
      // This handles cases where track count might be slightly off or unknown
      if (totalTracks > 0) {
        // If we know the total, check if we have all files
        if (completedLocal >= totalTracks) {
          status = 'complete';
        } else {
          // Partially downloaded - remain in running/queued state until all files are done
          status = hasActiveTasks ? 'running' : 'queued';
        }
      } else {
        // Total tracks unknown but we have local files - consider complete
        status = 'complete';
      }
    } else if (recs.any((r) => r.status == TaskStatus.failed)) status = 'failed';
    else if (recs.any((r) => r.status == TaskStatus.running)) status = 'running';
    else if (recs.any((r) => r.status == TaskStatus.enqueued)) status = 'queued';
    else if (_pendingQueuedUntil[libraryItemId]?.isAfter(DateTime.now()) == true) status = 'queued';
    else if (_itemsInGlobalQueue.contains(libraryItemId) || _activeItems.contains(libraryItemId)) status = 'queued';
    else if (_blockedItems.contains(libraryItemId) && !hasLocal) status = 'none';
    else if (_uiActive[libraryItemId] == true) status = 'running';
    else if (completedLocal > 0 && completedLocal < totalTracks) status = 'running';
    else if (hasLocal && completedLocal > 0) {
      // Has some local files but not complete - treat as in progress or complete based on count
      status = completedLocal >= totalTracks ? 'complete' : 'running';
    }

    return ItemProgress(
      libraryItemId: libraryItemId,
      status: status,
      progress: value.clamp(0.0, 1.0),
      totalTasks: totalTracks,
      completed: completedLocal,
    );
  }

  // Cache for database records to reduce locking
  List<TaskRecord>? _cachedAllRecords;
  DateTime? _cacheTimestamp;
  static const _cacheDuration = Duration(seconds: 3);
  bool _isQuerying = false;

  Future<List<TaskRecord>> _recordsForItem(String libraryItemId) async {
    final all = await _getAllRecordsCached();
    return all.where((r) {
      final meta = r.task.metaData ?? '';
      final id = _extractItemId(meta);
      return id == libraryItemId;
    }).toList();
  }

  Future<List<TaskRecord>> _queryAllRecordsWithRetry({int maxRetries = 3}) async {
    for (int i = 0; i < maxRetries; i++) {
      try {
        return await FileDownloader().database.allRecords();
      } catch (e) {
        if (i < maxRetries - 1) {
          // Wait before retry, with exponential backoff
          await Future.delayed(Duration(milliseconds: 50 * (i + 1)));
        } else {
          // Last retry failed, return empty list
          return [];
        }
      }
    }
    return [];
  }

  /// Get all records with caching to reduce database locking
  Future<List<TaskRecord>> _getAllRecordsCached({bool forceRefresh = false}) async {
    final now = DateTime.now();
    if (!forceRefresh && 
        _cachedAllRecords != null && 
        _cacheTimestamp != null && 
        now.difference(_cacheTimestamp!) < _cacheDuration &&
        !_isQuerying) {
      return _cachedAllRecords!;
    }

    // Prevent concurrent queries
    if (_isQuerying) {
      // Wait a bit and retry with cache
      await Future.delayed(const Duration(milliseconds: 100));
      if (_cachedAllRecords != null) {
        return _cachedAllRecords!;
      }
    }

    _isQuerying = true;
    try {
      final all = await _queryAllRecordsWithRetry();
      _cachedAllRecords = all;
      _cacheTimestamp = now;
      return all;
    } finally {
      _isQuerying = false;
    }
  }

  Future<void> _persistBlockedItems() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_blockedItemsPrefsKey, _blockedItems.toList());
    } catch (_) {}
  }

  Future<void> _loadBlockedItemsFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = prefs.getStringList(_blockedItemsPrefsKey) ?? const <String>[];
      _blockedItems
        ..clear()
        ..addAll(list);
    } catch (_) {}
  }

  String? _extractItemId(String meta) {
    try {
      final m = jsonDecode(meta);
      if (m is Map && m['libraryItemId'] is String) {
        return m['libraryItemId'] as String;
      }
    } catch (_) {}
    return null;
  }

  static String _extFromMime(String mime) {
    final m = mime.toLowerCase();
    if (m.contains('mpeg')) return 'mp3';
    if (m.contains('mp4') || m.contains('aac')) return 'm4a';
    if (m.contains('flac')) return 'flac';
    if (m.contains('opus')) return 'opus';
    if (m.contains('ogg')) return 'ogg';
    if (m.contains('webm')) return 'webm';
    return 'bin';
  }

  Future<Directory> _itemDir(String libraryItemId) async =>
      DownloadStorage.itemDir(libraryItemId);

  void _notifyItem(String libraryItemId) async {
    final c = _itemCtrls[libraryItemId];
    if (c != null && !c.isClosed) {
      c.add(await _computeItemProgress(libraryItemId));
    }
  }
  
  /// Public method to force refresh download status for an item
  Future<void> refreshItemStatus(String libraryItemId) async {
    _notifyItem(libraryItemId);
  }

  Future<int> _countLocalFiles(String libraryItemId) async {
    try {
      final dir = await _itemDir(libraryItemId);
      if (!await dir.exists()) return 0;
      final files = await dir
          .list()
          .where((e) => e is File)
          .cast<File>()
          .toList();
      return files.length;
    } catch (_) {
      return 0;
    }
  }

  // Foreground downloader removed

  /// Process the global download queue - ensures only one download runs at a time
  Future<void> _processGlobalQueue() async {
    // Respect global halt
    if (_globalHaltUntil != null && DateTime.now().isBefore(_globalHaltUntil!)) {
      _d('Global halt active; skipping queue processing');
      return;
    }
    if (_isProcessingGlobalQueue || _globalDownloadQueue.isEmpty) {
      _d('Global queue processing skipped: isProcessing=$_isProcessingGlobalQueue, isEmpty=${_globalDownloadQueue.isEmpty}');
      return;
    }
    
    _isProcessingGlobalQueue = true;
    _d('Starting global queue processing. Queue length: ${_globalDownloadQueue.length}');
    
    try {
      while (_globalDownloadQueue.isNotEmpty) {
        if (_inFlightItems.isNotEmpty) {
          _d('A task is already in flight, deferring queue processing');
          break;
        }
        // Check if there's already a download running
        final allRecords = await _getAllRecordsCached();
        final hasRunning = allRecords.any((r) => 
          r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
        
        if (hasRunning) {
          _d('Download already running, skipping queue processing now');
          break;
        }
        
        // Take the next item from the queue
        final nextItem = _globalDownloadQueue.removeFirst();
        final libraryItemId = nextItem.key;
        final episodeId = nextItem.value;
        
        _itemsInGlobalQueue.remove(libraryItemId);
        _d('Processing next item from global queue: $libraryItemId');
        
        // Start downloading the next track for this item
        await _startNextForItem(libraryItemId, episodeId: episodeId);
        // After scheduling once, exit; chain listener will continue
        break;
      }
    } finally {
      _isProcessingGlobalQueue = false;
      _d('Finished global queue processing');
    }
  }

  // Serial per-item scheduler: ensure only one active task for a given item
  Future<void> _startNextForItem(String libraryItemId, {String? episodeId}) async {
    _d('_startNextForItem called for $libraryItemId');
    // Respect global halt
    if (_globalHaltUntil != null && DateTime.now().isBefore(_globalHaltUntil!)) {
      _d('Global halt active; not scheduling new task');
      return;
    }
    
    if (_blockedItems.contains(libraryItemId)) {
      _d('Item $libraryItemId is blocked, skipping');
      return;
    }
    if (_schedulingItems.contains(libraryItemId)) {
      _d('Item $libraryItemId is already being scheduled, skipping');
      return;
    }
    if (_inFlightItems.isNotEmpty) {
      _d('Another task is in flight globally, skipping scheduling');
      return;
    }
    if (_inFlightItems.contains(libraryItemId)) {
      _d('Item $libraryItemId already has an in-flight task, skipping');
      return;
    }
    _schedulingItems.add(libraryItemId);
    try {
      // If already running/enqueued for this item, do nothing
      final recs = await _recordsForItem(libraryItemId);
      final hasActive = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
      if (hasActive) {
        _d('Item $libraryItemId already has active tasks, skipping');
        return;
      }

      // Build or reuse download plan without opening playback sessions
      final plan = await _ensureDownloadPlan(libraryItemId, episodeId: episodeId);
      _d('Found ${plan.length} downloadable tracks for $libraryItemId');
      
      if (plan.isEmpty) {
        _d('No remote tracks found for $libraryItemId');
        _notifyItem(libraryItemId);
        return;
      }

      // Find first track whose file does NOT exist locally
      final dir = await _itemDir(libraryItemId);
      _DlTrack? next;
      for (final t in plan) {
        final filename = 'track_${t.index.toString().padLeft(3, '0')}.${_extFromMime(t.mimeType)}';
        final f = File('${dir.path}/$filename');
        if (!f.existsSync()) {
          next = t;
          break;
        }
      }
      if (next == null) {
        // All tracks for this book are downloaded, remove from global queue
        _globalDownloadQueue.removeWhere((entry) => entry.key == libraryItemId);
        _itemsInGlobalQueue.remove(libraryItemId);
        _d('Book $libraryItemId is complete, removed from global queue');
        _notifyItem(libraryItemId);
        return;
      }
      
      _d('Downloading track ${next.index} for $libraryItemId');

      final prefs = await SharedPreferences.getInstance();
      final wifiOnly = prefs.getBool(_wifiOnlyKey) ?? false;
      final filename = 'track_${next.index.toString().padLeft(3, '0')}.${_extFromMime(next.mimeType)}';

      final baseFolder = await DownloadStorage.taskDirectoryPrefix();
      final preferredBase = await DownloadStorage.preferredTaskBaseDirectory();
      // Add Authorization header so background worker can access protected URLs
      final headers = <String, String>{};
      try {
        final access = await _auth.api.accessToken();
        if (access != null && access.isNotEmpty) {
          headers['Authorization'] = 'Bearer $access';
        }
      } catch (_) {}
      // Build /download endpoint URL (no playback session)
      final url = _downloadUrlFor(libraryItemId, next.fileId, episodeId: episodeId);
      // Log the download URL with full details
      _d('Downloading from $url');
      
      final logger = SessionLoggerService.instance;
      if (logger.isActive) {
        final sanitizedHeaders = Map<String, String>.from(headers);
        if (sanitizedHeaders.containsKey('Authorization')) {
          sanitizedHeaders['Authorization'] = 'Bearer [REDACTED]';
        }
        await logger.log('DOWNLOAD ENQUEUE:');
        await logger.log('  URL: $url');
        await logger.log('  LibraryItemId: $libraryItemId');
        await logger.log('  TrackIndex: ${next.index}');
        await logger.log('  Filename: $filename');
        await logger.log('  Directory: $baseFolder/$libraryItemId');
        await logger.log('  Headers: ${jsonEncode(sanitizedHeaders)}');
        await logger.log('  RequiresWiFi: $wifiOnly');
      }
      
      final task = DownloadTask(
        url: url,
        filename: filename,
        directory: '$baseFolder/$libraryItemId',
        baseDirectory: preferredBase,
        headers: headers,
        // Request status and progress so we can compute accurate overall %
        updates: Updates.statusAndProgress,
        requiresWiFi: wifiOnly,
        allowPause: true,
        metaData: jsonEncode({'libraryItemId': libraryItemId}),
        group: 'book-$libraryItemId',
      );

      await FileDownloader().enqueue(task);
      
      if (logger.isActive) {
        await logger.log('DOWNLOAD ENQUEUED: TaskId ${task.taskId}');
      }
      _inFlightItems.add(libraryItemId);
      _notifyItem(libraryItemId);

      // Keep this item in the global queue until all tracks are downloaded
      // The chain listener will handle continuing with the next track

      _ensureChainListener();
    } finally {
      _schedulingItems.remove(libraryItemId);
    }
  }

  Future<void> _resumeAllPending() async {
    // Foreground runner only; don't resume pending
  }

  void _ensureChainListener() {
    if (_chainSub != null) return;
    _chainSub = progressStream().listen((u) async {
      final meta = u.task.metaData ?? '';
      final id = _extractItemId(meta);
      if (id == null) return;
      // Ignore/cancel updates for items we explicitly blocked
      if (_blockedItems.contains(id)) {
        try {
          await FileDownloader().cancelTaskWithId(u.task.taskId);
          try { await FileDownloader().database.deleteRecordWithId(u.task.taskId); } catch (_) {}
        } catch (_) {}
        return;
      }
      // Fast-path: when a task completes, clear live flags and try to schedule the next immediately
      if (u is TaskStatusUpdate && u.status == TaskStatus.complete) {
        final logger = SessionLoggerService.instance;
        if (logger.isActive) {
          await logger.log('DOWNLOAD COMPLETE:');
          await logger.log('  TaskId: ${u.task.taskId}');
          await logger.log('  LibraryItemId: $id');
          await logger.log('  Filename: ${u.task.filename}');
        }
        _uiActive[id] = false;
        _inFlightItems.remove(id);
        _lastRunningProgress.remove(id);
        _lastUpdateAt[id] = DateTime.now();
        // Allow DB to settle, then schedule next if nothing else is active
        await Future.delayed(const Duration(milliseconds: 150));
        final recs = await _recordsForItem(id);
        final hasActiveDb = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
        if (!hasActiveDb) {
          _nextAllowedSchedule[id] = DateTime.now();
          await _startNextForItem(id);
        }
        return;
      }
      
      // Log other status updates
      final logger = SessionLoggerService.instance;
      if (logger.isActive) {
        if (u is TaskProgressUpdate) {
          await logger.log('DOWNLOAD PROGRESS UPDATE:');
          await logger.log('  TaskId: ${u.task.taskId}');
          await logger.log('  LibraryItemId: $id');
          await logger.log('  Progress: ${((u.progress ?? 0.0) * 100).toStringAsFixed(1)}%');
          await logger.log('  URL: ${u.task.url}');
          await logger.log('  Filename: ${u.task.filename}');
        } else if (u is TaskStatusUpdate) {
          await logger.log('DOWNLOAD STATUS UPDATE:');
          await logger.log('  TaskId: ${u.task.taskId}');
          await logger.log('  LibraryItemId: $id');
          await logger.log('  Status: ${u.status}');
          await logger.log('  URL: ${u.task.url}');
          await logger.log('  Filename: ${u.task.filename}');
          if (u.status == TaskStatus.failed) {
            await logger.log('  ERROR: Download failed');
            try {
              final allRecords = await FileDownloader().database.allRecords();
              final record = allRecords.firstWhere(
                (r) => r.taskId == u.task.taskId,
                orElse: () => throw Exception('Record not found'),
              );
              if (record.status == TaskStatus.failed) {
                await logger.log('  Error: Task failed (status: ${record.status})');
              }
            } catch (e) {
              await logger.log('  Could not retrieve error details: $e');
            }
          } else if (u.status == TaskStatus.canceled) {
            await logger.log('  CANCELED: Download was canceled');
          }
        }
      }
      // Only respond to items the user activated
      if (!_activeItems.contains(id)) return;

      // Small debounce to allow plugin to update DB
      await Future.delayed(const Duration(milliseconds: 150));

      // Determine activity using DB and live flags
      final recs = await _recordsForItem(id);
      final hasActiveDb = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
      bool hasActiveLive = (_uiActive[id] == true) || _inFlightItems.contains(id);
      // Clear stale live flags if no DB activity for >2s
      if (!hasActiveDb && hasActiveLive) {
        final last = _lastUpdateAt[id];
        final stale = last == null || DateTime.now().difference(last) > const Duration(seconds: 2);
        if (stale) {
          _uiActive[id] = false;
          _inFlightItems.remove(id);
          hasActiveLive = false;
        }
      }
      final hasActive = hasActiveDb || hasActiveLive;

      if (!hasActive) {
        // Check if this book still has tracks to download using cached plan
        final plan = await _ensureDownloadPlan(id);
        final dir = await _itemDir(id);
        bool hasMoreTracks = false;
        for (final t in plan) {
          final filename = 'track_${t.index.toString().padLeft(3, '0')}.${_extFromMime(t.mimeType)}';
          final f = File('${dir.path}/$filename');
          if (!f.existsSync()) {
            hasMoreTracks = true;
            break;
          }
        }

        if (hasMoreTracks) {
          // Throttle; ensure no other file in flight
          final now = DateTime.now();
          if (_globalHaltUntil != null && now.isBefore(_globalHaltUntil!)) return;
          final nextOk = _nextAllowedSchedule[id] ?? DateTime.fromMillisecondsSinceEpoch(0);
          if (now.isBefore(nextOk)) return;
          _nextAllowedSchedule[id] = now.add(const Duration(milliseconds: 750));
          await _startNextForItem(id);
        } else {
          // Completed: clear queues and hide notification
          _globalDownloadQueue.removeWhere((entry) => entry.key == id);
          _itemsInGlobalQueue.remove(id);
          _uiActive[id] = false;
          _inFlightItems.remove(id);
          try {
            await NotificationService.instance.hideDownloadNotification();
            // Best-effort: show a short completion notification using the item id as title hint
            await NotificationService.instance.showDownloadComplete('Book ready');
            
            // Stop progress notifications for this item
            _stopProgressNotifications(id);
          } catch (_) {}
          unawaited(StreamingCacheService.instance.evictForItem(id));
          // If the completed item is currently playing from stream, switch to local seamlessly
          // PAUSE first to prevent position jumping
          try {
            final np = _playback.nowPlaying;
            final isCurrentlyPlaying = np != null && np.libraryItemId == id;
            bool wasPlaying = false;
            Duration? savedGlobalPosition;
            
            if (isCurrentlyPlaying) {
              // CRITICAL: Save global position BEFORE pausing
              savedGlobalPosition = _playback.globalBookPosition;
              wasPlaying = _playback.player.playing;
              
              if (wasPlaying) {
                await _playback.pause();
              }
              
              // Show notification
              try {
                await NotificationService.instance.showDownloadComplete('Switching to downloaded files...');
              } catch (_) {}
              
              // Wait a moment for pause to settle
              await Future.delayed(const Duration(milliseconds: 200));
              
              // Switch to local files
              await _playback.switchToLocalIfAvailableFor(id);
              
              // CRITICAL: Restore the exact saved position after switching
              if (savedGlobalPosition != null && savedGlobalPosition > Duration.zero) {
                await Future.delayed(const Duration(milliseconds: 100));
                await _playback.seekGlobal(savedGlobalPosition, reportNow: false);
                await Future.delayed(const Duration(milliseconds: 100));
                
                // Verify position was restored correctly
                final actualPos = _playback.globalBookPosition;
                if (actualPos != null) {
                  final diff = (actualPos.inMilliseconds - savedGlobalPosition.inMilliseconds).abs();
                  if (diff > 2000) {
                    // Position is off by more than 2 seconds, try again
                    await Future.delayed(const Duration(milliseconds: 200));
                    await _playback.seekGlobal(savedGlobalPosition, reportNow: false);
                  }
                }
              }
              
              // RESUME playback if it was playing before
              if (wasPlaying) {
                await Future.delayed(const Duration(milliseconds: 200));
                await _playback.player.play();
              }
            } else {
              // Not currently playing, just switch silently
              await _playback.switchToLocalIfAvailableFor(id);
            }
          } catch (_) {}
        }
      }

      _notifyItem(id);
    });
  }

  Future<void> _closeDownloadSessionWhenIdle(String? sessionId, String libraryItemId) async {
    if (sessionId == null || sessionId.isEmpty) return;
    await Future.delayed(const Duration(seconds: 2));
    final recs = await _recordsForItem(libraryItemId);
    final hasActive = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
    if (hasActive) return;
    unawaited(_playback.closeSessionById(sessionId));
  }

  /// Delete all downloaded files and cancel any active tasks (global).
  Future<void> deleteAllLocal() async {
    await cancelAll();
    try {
      final root = await DownloadStorage.baseDir();
      if (await root.exists()) {
        await root.delete(recursive: true);
      }
    } catch (_) {}
    try {
      final all = await _getAllRecordsCached(forceRefresh: true);
      // Batch deletions with delays
      for (final r in all) {
        try {
          await FileDownloader().database.deleteRecordWithId(r.taskId);
          if (all.length > 1) {
            await Future.delayed(const Duration(milliseconds: 10));
          }
        } catch (_) {}
      }
      // Invalidate cache
      _cachedAllRecords = null;
      _cacheTimestamp = null;
    } catch (_) {}
  }
}
