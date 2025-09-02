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

    // Resume any pending downloads from previous session
    try {
      await _resumeAllPending();
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
    // Kick off or continue serial downloads for this item (one track at a time)
    await _startNextForItem(libraryItemId, episodeId: episodeId);
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

  /// Resume serial downloads for all tracked items (if applicable)
  Future<void> resumeAll() async {
    final ids = await listTrackedItemIds();
    for (final id in ids) {
      await _startNextForItem(id);
    }
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

  // Serial per-item scheduler: ensure only one active task for a given item
  Future<void> _startNextForItem(String libraryItemId, {String? episodeId}) async {
    // If already running/enqueued for this item, do nothing
    final recs = await _recordsForItem(libraryItemId);
    final hasActive = recs.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
    if (hasActive) return;

    // Determine next remote track not yet downloaded locally
    final tracks = await _playback.getRemoteTracks(libraryItemId, episodeId: episodeId);
    tracks.sort((a, b) => a.index.compareTo(b.index));
    if (tracks.isEmpty) {
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
      _notifyItem(libraryItemId);
      return;
    }

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
    );

    await FileDownloader().enqueue(task);
    _notifyItem(libraryItemId);

    // Listen to updates to trigger next in chain
    _muxSub ??= progressStream().listen((u) async {
      final meta = u.task.metaData ?? '';
      final id = _extractItemId(meta);
      if (id == null) return;
      await Future.delayed(const Duration(milliseconds: 100));
      await _startNextForItem(id);
      _notifyItem(id);
    });
  }

  Future<void> _resumeAllPending() async {
    final ids = await listTrackedItemIds();
    for (final id in ids) {
      await _startNextForItem(id);
    }
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
