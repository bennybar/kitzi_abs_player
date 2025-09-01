// lib/core/downloads_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
  final int totalTasks;
  final int completed;

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
  StreamSubscription<TaskUpdate>? _muxSub;

  Future<void> init() async {
    // Configure ONE global notification. Do NOT set per-task displayName.
    try {
      await FileDownloader().configureNotification(
        running: const TaskNotification('Downloading audiobooks…', ''),
        complete: const TaskNotification('Downloads complete', ''),
        error: const TaskNotification('Download failed', ''),
      );
    } catch (_) {}
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
    _muxSub ??= progressStream().listen((u) async {
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
      }) async {
    // If already downloaded and no tasks => nothing to enqueue
    if (await hasLocalDownloads(libraryItemId)) {
      final recs = await _recordsForItem(libraryItemId);
      if (recs.isEmpty) {
        _d('Already local for $libraryItemId; skipping enqueue.');
        _notifyItem(libraryItemId);
        return;
      }
    }

    final tracks =
    await _playback.getPlayableTracks(libraryItemId, episodeId: episodeId);

    final remoteTracks = tracks.where((t) => !t.isLocal).toList();
    if (remoteTracks.isEmpty) {
      _d('No remote tracks to download for $libraryItemId (already local?).');
      _notifyItem(libraryItemId);
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final wifiOnly = prefs.getBool(_wifiOnlyKey) ?? true;

    // Enqueue WITHOUT per-task displayName to keep a single system notification
    for (final t in remoteTracks) {
      final filename =
          'track_${t.index.toString().padLeft(3, '0')}.${_extFromMime(t.mimeType)}';

      final task = DownloadTask(
        url: t.url, // absolute URL with token
        filename: filename,
        directory: 'abs/$libraryItemId',
        baseDirectory: BaseDirectory.applicationDocuments,
        updates: Updates.statusAndProgress,
        requiresWiFi: wifiOnly,
        allowPause: true,
        metaData: jsonEncode({'libraryItemId': libraryItemId}),
      );

      await FileDownloader().enqueue(task);
    }

    _notifyItem(libraryItemId);
  }

  /// Cancel all queued/running tasks for a book.
  Future<void> cancelForItem(String libraryItemId) async {
    final recs = await _recordsForItem(libraryItemId);
    for (final r in recs) {
      await FileDownloader().cancelTaskWithId(r.taskId);
    }
    _notifyItem(libraryItemId);
  }

  /// Remove local files for a book (and cancel tasks just in case).
  Future<void> deleteLocal(String libraryItemId) async {
    await cancelForItem(libraryItemId);
    final dir = await _itemDir(libraryItemId);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    _notifyItem(libraryItemId);
  }

  Future<void> cancelAll() async {
    final records = await FileDownloader().database.allRecords();
    final ids = records.map((r) => r.taskId).toList();
    if (ids.isNotEmpty) {
      await FileDownloader().cancelTasksWithIds(ids);
    }
  }

  Future<List<TaskRecord>> listAll() =>
      FileDownloader().database.allRecords();

  // === Local files helpers ===

  Future<bool> hasLocalDownloads(String libraryItemId) async {
    final dir = await _itemDir(libraryItemId);
    return dir.exists();
  }

  // === Internal aggregation ===

  Future<ItemProgress> _computeItemProgress(String libraryItemId) async {
    final recs = await _recordsForItem(libraryItemId);
    if (recs.isEmpty) {
      // If there are no tasks but local files exist, treat as complete
      final local = await hasLocalDownloads(libraryItemId);
      return ItemProgress(
        libraryItemId: libraryItemId,
        status: local ? 'complete' : 'none',
        progress: local ? 1.0 : 0.0,
        totalTasks: 0,
        completed: local ? 1 : 0,
      );
    }

    int total = recs.length;
    int done = recs.where((r) => r.status == TaskStatus.complete).length;

    double sum = 0.0;
    for (final r in recs) {
      if (r.status == TaskStatus.complete) {
        sum += 1.0;
      } else {
        sum += (r.progress ?? 0.0);
      }
    }
    final avg = sum / total;

    String status = 'running';
    if (done == total) status = 'complete';
    if (recs.any((r) => r.status == TaskStatus.failed)) status = 'failed';
    if (recs.every((r) => r.status == TaskStatus.enqueued)) status = 'queued';
    if (recs.every((r) => r.status == TaskStatus.canceled)) status = 'canceled';

    return ItemProgress(
      libraryItemId: libraryItemId,
      status: status,
      progress: avg,
      totalTasks: total,
      completed: done,
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
}
