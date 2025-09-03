// lib/core/downloads_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:collection';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_repository.dart';
import 'playback_repository.dart';
import 'download_storage.dart';
import 'notification_service.dart';

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

class DownloadsRepository {
  DownloadsRepository(this._auth, this._playback);
  final AuthRepository _auth;
  final PlaybackRepository _playback;

  static const _wifiOnlyKey = 'downloads_wifi_only';

  void _d(String m) => debugPrint('[DL] $m');

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

  Future<void> init() async {
    // Configure ONE global notification. Do NOT set per-task displayName.
    try {
      await FileDownloader().configureNotification(
        running: null,
        complete: null,
        error: null,
      );
    } catch (_) {}

    // Load persistent blocked items (ensures hard-stop even across restarts)
    await _loadBlockedItemsFromPrefs();

    // Do not auto-resume pending downloads on startup; user can resume explicitly from UI
    // Additionally, cancel any persisted tasks from previous sessions to avoid battery/storage drain
    try {
      final all = await FileDownloader().database.allRecords();
      final ids = all.map((r) => r.taskId).toList();
      if (ids.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(ids);
      }
      for (final r in all) {
        try { await FileDownloader().database.deleteRecordWithId(r.taskId); } catch (_) {}
      }
    } catch (_) {}

    // Ensure global listener is active so chaining continues even when UI is closed
    _ensureChainListener();
  }

  /// Start (or get) an aggregated progress stream for a specific book.
  Stream<ItemProgress> watchItemProgress(String libraryItemId) {
    final ctrl = _itemCtrls.putIfAbsent(
      libraryItemId,
          () => StreamController<ItemProgress>.broadcast(onListen: () async {
        final snap = await _computeItemProgress(libraryItemId);
        (_itemCtrls[libraryItemId]!)..add(snap);
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
        final snap = await _computeItemProgress(id);
        final c = _itemCtrls[id];
        if (c != null && !c.isClosed) c.add(snap);
      }
    });

    return ctrl.stream;
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

    // Add to background queue
    if (!_itemsInGlobalQueue.contains(libraryItemId)) {
      _globalDownloadQueue.add(MapEntry(libraryItemId, episodeId));
      _itemsInGlobalQueue.add(libraryItemId);
      _d('Added $libraryItemId to global queue. Queue length: ${_globalDownloadQueue.length}');
    }
    
    // Show a single download notification for this book
    try {
      final title = (displayTitle != null && displayTitle.isNotEmpty)
          ? displayTitle
          : 'Audiobook';
      await NotificationService.instance.showDownloadStarted(title);
    } catch (_) {}
    
    // Immediately publish a queued snapshot so UI updates without waiting for DB
    try {
      _pendingQueuedUntil[libraryItemId] = DateTime.now().add(const Duration(seconds: 12));
      final totalTracks = await _playback.getTotalTrackCount(libraryItemId);
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
    
    // Cancel any active/enqueued tasks for this item
    try {
      // Cancel by group, DB, and live-tracked task ids to be thorough
      final liveIds = (_itemTaskIds[libraryItemId] ?? const <String>{}).toList();
      if (liveIds.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(liveIds);
      }
      final all = await FileDownloader().database.allRecords();
      final groupIds = all
          .where((r) => (r.task.group ?? '').trim() == 'book-$libraryItemId' ||
              _extractItemId(r.task.metaData ?? '') == libraryItemId)
          .map((r) => r.taskId)
          .toList();
      if (groupIds.isNotEmpty) {
        await FileDownloader().cancelTasksWithIds(groupIds);
      }
      // Clean DB records for this item
      for (final r in all.where((r) => _extractItemId(r.task.metaData ?? '') == libraryItemId)) {
        try { await FileDownloader().database.deleteRecordWithId(r.taskId); } catch (_) {}
      }
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
    } catch (_) {}
    
    // Small debounce to allow plugin to settle
    await Future.delayed(const Duration(milliseconds: 150));
    _notifyItem(libraryItemId);
    // Hide download notification on cancel
    try { await NotificationService.instance.hideDownloadNotification(); } catch (_) {}
  }

  /// Remove local files for a book (and cancel tasks just in case).
  Future<void> deleteLocal(String libraryItemId) async {
    await cancelForItem(libraryItemId);
    final dir = await _itemDir(libraryItemId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    // Also remove task records for this item from plugin database
    try {
      final recs = await _recordsForItem(libraryItemId);
      for (final r in recs) {
        await FileDownloader().database.deleteRecordWithId(r.taskId);
      }
    } catch (_) {}
    _pendingQueuedUntil.remove(libraryItemId);
    _blockedItems.add(libraryItemId);
    _lastRunningProgress.remove(libraryItemId);
    _lastItemUpdate.remove(libraryItemId);
    _lastUpdateAt.remove(libraryItemId);
    _notifyItem(libraryItemId);
  }

  Future<void> cancelAll() async {
    // Cancel all active downloads
    final records = await FileDownloader().database.allRecords();
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
  }

  Future<List<TaskRecord>> listAll() =>
      FileDownloader().database.allRecords();

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

  /// Return a union of itemIds that either have local files or active records.
  Future<List<String>> listTrackedItemIds() async {
    final ids = <String>{};
    // From task records
    final all = await FileDownloader().database.allRecords();
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
    final recs = await _recordsForItem(libraryItemId);
    final totalTracks = await _playback.getTotalTrackCount(libraryItemId);
    final completedLocal = await _countLocalFiles(libraryItemId);

    // Determine per-file running progress using live cache for stability
    double runningProgress = _lastRunningProgress[libraryItemId] ?? 0.0;

    final denom = totalTracks == 0 ? 1 : totalTracks;
    double value = ((completedLocal.toDouble()) + runningProgress) / denom;
    // If item is blocked/canceled, force 0 to avoid stale '2%'
    if (_blockedItems.contains(libraryItemId)) {
      value = 0.0;
    } else if (value > 0.0 && value < 0.01) {
      value = 0.01;
    }

    String status = 'none';
    if (completedLocal >= totalTracks && totalTracks > 0) status = 'complete';
    else if (recs.any((r) => r.status == TaskStatus.failed)) status = 'failed';
    else if (recs.any((r) => r.status == TaskStatus.running)) status = 'running';
    else if (recs.any((r) => r.status == TaskStatus.enqueued)) status = 'queued';
    else if (_pendingQueuedUntil[libraryItemId]?.isAfter(DateTime.now()) == true) status = 'queued';
    else if (_itemsInGlobalQueue.contains(libraryItemId) || _activeItems.contains(libraryItemId)) status = 'queued';
    else if (_blockedItems.contains(libraryItemId)) status = 'none';
    else if (_uiActive[libraryItemId] == true) status = 'running';
    else if (completedLocal > 0 && completedLocal < totalTracks) status = 'running';

    return ItemProgress(
      libraryItemId: libraryItemId,
      status: status,
      progress: value.clamp(0.0, 1.0),
      totalTasks: totalTracks,
      completed: completedLocal,
    );
  }

  Future<List<TaskRecord>> _recordsForItem(String libraryItemId) async {
    final all = await FileDownloader().database.allRecords();
    return all.where((r) {
      final meta = r.task.metaData ?? '';
      final id = _extractItemId(meta);
      return id == libraryItemId;
    }).toList();
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
        final allRecords = await FileDownloader().database.allRecords();
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

      // Determine next remote track not yet downloaded locally
      final tracks = await _playback.getRemoteTracks(libraryItemId, episodeId: episodeId);
      tracks.sort((a, b) => a.index.toString().compareTo(b.index.toString()));
      _d('Found ${tracks.length} remote tracks for $libraryItemId');
      
      if (tracks.isEmpty) {
        _d('No remote tracks found for $libraryItemId');
        _notifyItem(libraryItemId);
        return;
      }

      // Find first track whose file does NOT exist locally
      final dir = await _itemDir(libraryItemId);
      PlaybackTrack? next;
      for (final t in tracks) {
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
      final wifiOnly = prefs.getBool(_wifiOnlyKey) ?? true;
      final filename = 'track_${next.index.toString().padLeft(3, '0')}.${_extFromMime(next.mimeType)}';

      final baseFolder = await DownloadStorage.taskDirectoryPrefix();
      final preferredBase = await DownloadStorage.preferredTaskBaseDirectory();
      final task = DownloadTask(
        url: next.url,
        filename: filename,
        directory: '$baseFolder/$libraryItemId',
        baseDirectory: preferredBase,
        // Request status and progress so we can compute accurate overall %
        updates: Updates.statusAndProgress,
        requiresWiFi: wifiOnly,
        allowPause: true,
        metaData: jsonEncode({'libraryItemId': libraryItemId}),
        group: 'book-$libraryItemId',
      );

      await FileDownloader().enqueue(task);
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
        // Check if this book still has tracks to download
        final tracks = await _playback.getRemoteTracks(id);
        final dir = await _itemDir(id);
        bool hasMoreTracks = false;
        for (final t in tracks) {
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
          if (_inFlightItems.isNotEmpty) return;
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
          } catch (_) {}
          // Optional: toast/snackbar via notification channel could be added here
        }
      }

      _notifyItem(id);
    });
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
      final all = await FileDownloader().database.allRecords();
      for (final r in all) {
        await FileDownloader().database.deleteRecordWithId(r.taskId);
      }
    } catch (_) {}
  }
}
