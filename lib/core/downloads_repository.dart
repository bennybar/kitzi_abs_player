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
  
  // Global download queue management
  final Queue<MapEntry<String, String?>> _globalDownloadQueue = Queue<MapEntry<String, String?>>();
  bool _isProcessingGlobalQueue = false;
  final Set<String> _itemsInGlobalQueue = <String>{};

  Future<void> init() async {
    // Configure ONE global notification. Do NOT set per-task displayName.
    try {
      await FileDownloader().configureNotification(
        running: const TaskNotification('Downloading…', ''),
        // Avoid per-track complete notifications; we'll rely on UI and only
        // update title when the whole book finishes
        complete: null,
        error: const TaskNotification('Download failed', ''),
      );
    } catch (_) {}

    // Resume any pending downloads from previous session
    try {
      await _resumeAllPending();
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
    
    // Add to global queue if not already there
    if (!_itemsInGlobalQueue.contains(libraryItemId)) {
      _globalDownloadQueue.add(MapEntry(libraryItemId, episodeId));
      _itemsInGlobalQueue.add(libraryItemId);
      _d('Added $libraryItemId to global queue. Queue length: ${_globalDownloadQueue.length}');
    }
    
    // Update notification title to the current book (best effort)
    try {
      await FileDownloader().configureNotification(
        running: TaskNotification(
          displayTitle != null && displayTitle.isNotEmpty
              ? 'Downloading "$displayTitle"'
              : 'Downloading audiobook…',
          '',
        ),
        complete: null,
        error: const TaskNotification('Download failed', ''),
      );
    } catch (_) {}
    
    // Immediately publish a queued snapshot so UI updates without waiting for DB
    try {
      _pendingQueuedUntil[libraryItemId] = DateTime.now().add(const Duration(seconds: 3));
      final totalTracks = await _playback.getTotalTrackCount(libraryItemId);
      final completedLocal = await _countLocalFiles(libraryItemId);
      final snap = ItemProgress(
        libraryItemId: libraryItemId,
        status: 'queued',
        progress: totalTracks == 0 ? 0.0 : (completedLocal / totalTracks).clamp(0.0, 1.0),
        totalTasks: totalTracks,
        completed: completedLocal,
      );
      final ctrl = _itemCtrls[libraryItemId];
      if (ctrl != null && !ctrl.isClosed) ctrl.add(snap);
    } catch (_) {}

    // Start processing the global queue
    _processGlobalQueue();
  }

  /// Cancel all queued/running tasks for a book.
  Future<void> cancelForItem(String libraryItemId) async {
    final recs = await _recordsForItem(libraryItemId);
    for (final r in recs) {
      await FileDownloader().cancelTaskWithId(r.taskId);
    }
    _pendingQueuedUntil.remove(libraryItemId);
    _blockedItems.add(libraryItemId);
    
    // Remove from global queue
    _globalDownloadQueue.removeWhere((entry) => entry.key == libraryItemId);
    _itemsInGlobalQueue.remove(libraryItemId);
    
    _notifyItem(libraryItemId);
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
    }
    
    _d('Canceled all downloads and cleared global queue');
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
    // From local directory names
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/abs');
      if (await dir.exists()) {
        final entries = await dir.list(followLinks: false).toList();
        for (final e in entries) {
          final name = e.path.split('/').last;
          if (name.isNotEmpty) ids.add(name);
        }
      }
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

    double runningProgress = 0.0;
    if (recs.isNotEmpty) {
      final running = recs.firstWhere(
            (r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued,
        orElse: () => recs.first,
      );
      runningProgress = (running.progress ?? 0.0).clamp(0.0, 1.0);
    }

    final denom = totalTracks == 0 ? 1 : totalTracks;
    final value = ((completedLocal.toDouble()) + runningProgress) / denom;

    String status = 'none';
    if (completedLocal >= totalTracks && totalTracks > 0) status = 'complete';
    else if (recs.any((r) => r.status == TaskStatus.failed)) status = 'failed';
    else if (recs.any((r) => r.status == TaskStatus.running)) status = 'running';
    else if (recs.any((r) => r.status == TaskStatus.enqueued)) status = 'queued';
    else if (_pendingQueuedUntil[libraryItemId]?.isAfter(DateTime.now()) == true) status = 'queued';
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

  Future<Directory> _itemDir(String libraryItemId) async {
    final docs = await getApplicationDocumentsDirectory();
    return Directory('${docs.path}/abs/$libraryItemId');
  }

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

  /// Process the global download queue - ensures only one download runs at a time
  Future<void> _processGlobalQueue() async {
    if (_isProcessingGlobalQueue || _globalDownloadQueue.isEmpty) {
      _d('Global queue processing skipped: isProcessing=$_isProcessingGlobalQueue, isEmpty=${_globalDownloadQueue.isEmpty}');
      return;
    }
    
    _isProcessingGlobalQueue = true;
    _d('Starting global queue processing. Queue length: ${_globalDownloadQueue.length}');
    
    try {
      while (_globalDownloadQueue.isNotEmpty) {
        // Check if there's already a download running
        final allRecords = await FileDownloader().database.allRecords();
        final hasRunning = allRecords.any((r) => 
          r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
        
        if (hasRunning) {
          _d('Download already running, waiting...');
          // Wait a bit and check again
          await Future.delayed(const Duration(milliseconds: 500));
          continue;
        }
        
        // Take the next item from the queue
        final nextItem = _globalDownloadQueue.removeFirst();
        final libraryItemId = nextItem.key;
        final episodeId = nextItem.value;
        
        _itemsInGlobalQueue.remove(libraryItemId);
        _d('Processing next item from global queue: $libraryItemId');
        
        // Start downloading the next track for this item
        await _startNextForItem(libraryItemId, episodeId: episodeId);
        
        // Don't break here - let the chain listener handle the next steps
        // It will either continue with this book or move to the next one
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
    
    if (_blockedItems.contains(libraryItemId)) {
      _d('Item $libraryItemId is blocked, skipping');
      return;
    }
    if (_schedulingItems.contains(libraryItemId)) {
      _d('Item $libraryItemId is already being scheduled, skipping');
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

    final task = DownloadTask(
      url: next.url,
      filename: filename,
      directory: 'abs/$libraryItemId',
      baseDirectory: BaseDirectory.applicationDocuments,
      updates: Updates.statusAndProgress,
      requiresWiFi: wifiOnly,
      allowPause: true,
      metaData: jsonEncode({'libraryItemId': libraryItemId}),
      group: 'book-$libraryItemId',
    );

    await FileDownloader().enqueue(task);
    _notifyItem(libraryItemId);

    // Keep this item in the global queue until all tracks are downloaded
    // The chain listener will handle continuing with the next track

    _ensureChainListener();
    } finally {
      _schedulingItems.remove(libraryItemId);
    }
  }

  Future<void> _resumeAllPending() async {
    final ids = await listTrackedItemIds();
    for (final id in ids) {
      // Add to global queue if not already there
      if (!_itemsInGlobalQueue.contains(id)) {
        _globalDownloadQueue.add(MapEntry(id, null));
        _itemsInGlobalQueue.add(id);
      }
    }
    // Start processing the queue
    _processGlobalQueue();
  }

  void _ensureChainListener() {
    if (_chainSub != null) return;
    _chainSub = progressStream().listen((u) async {
      final meta = u.task.metaData ?? '';
      final id = _extractItemId(meta);
      if (id == null) return;
      if (_blockedItems.contains(id)) return;
      
      _d('Chain listener: Task update for $id');
      
      // React to any update; scheduling guard + hasActive prevent duplicates
      await Future.delayed(const Duration(milliseconds: 150));
      
      // Check if this item needs more tracks downloaded
      final recs = await _recordsForItem(id);
      final hasActive = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
      
      _d('Chain listener: Item $id hasActive: $hasActive, records: ${recs.length}');
      
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
          // This book still has tracks to download, continue with it
          _d('Book $id still has tracks to download, continuing...');
          // Add a small delay to ensure the previous download is fully processed
          await Future.delayed(const Duration(milliseconds: 200));
          await _startNextForItem(id);
        } else {
          // This book is complete, remove from global queue and process next
          _d('Book $id is complete, removing from global queue and moving to next');
          _globalDownloadQueue.removeWhere((entry) => entry.key == id);
          _itemsInGlobalQueue.remove(id);
          _processGlobalQueue();
        }
      } else {
        // Continue with this item
        await _startNextForItem(id);
      }
      
      _notifyItem(id);
    });
  }

  /// Delete all downloaded files and cancel any active tasks (global).
  Future<void> deleteAllLocal() async {
    await cancelAll();
    try {
      final docs = await getApplicationDocumentsDirectory();
      final root = Directory('${docs.path}/abs');
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
