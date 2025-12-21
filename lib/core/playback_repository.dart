// lib/core/playback_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_repository.dart';
import 'audio_service_binding.dart';
import 'audio_service_manager.dart';
import 'chapter_navigation_service.dart';
import 'sleep_timer_service.dart';
import 'playback_speed_service.dart';
import 'download_storage.dart';
import 'play_history_service.dart';
import 'playback_journal_service.dart';
import 'dynamic_island_service.dart';
import '../models/book.dart';
import 'books_repository.dart';
import 'smart_rewind_service.dart';
import 'streaming_cache_service.dart';
import 'detailed_play_history_service.dart';

enum ProgressResetChoice {
  useServer,
  useLocal,
  cancel,
}

const _kProgressPing = Duration(seconds: 26);
const _kLocalProgPrefix = 'abs_progress:';      // local fallback per item
const _kLastItemKey = 'abs_last_item_id';       // last played item id

/// UI-facing indicator for whether progress was synced recently, or is pending sync.
class ProgressSyncStatus {
  final DateTime? lastAttemptAt;
  final DateTime? lastSuccessAt;
  final bool pending;
  final int consecutiveFailures;
  final String? lastError;

  const ProgressSyncStatus({
    this.lastAttemptAt,
    this.lastSuccessAt,
    this.pending = false,
    this.consecutiveFailures = 0,
    this.lastError,
  });

  bool get hasEverSynced => lastSuccessAt != null;

  ProgressSyncStatus copyWith({
    DateTime? lastAttemptAt,
    DateTime? lastSuccessAt,
    bool? pending,
    int? consecutiveFailures,
    String? lastError,
  }) {
    return ProgressSyncStatus(
      lastAttemptAt: lastAttemptAt ?? this.lastAttemptAt,
      lastSuccessAt: lastSuccessAt ?? this.lastSuccessAt,
      pending: pending ?? this.pending,
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      lastError: lastError,
    );
  }
}

class PlaybackTrack {
  final int index;
  final String url;
  final String mimeType;
  final double duration; // seconds (0 if unknown)
  final bool isLocal;
  PlaybackTrack({
    required this.index,
    required this.url,
    required this.mimeType,
    required this.duration,
    this.isLocal = false,
  });

  PlaybackTrack copyWith({double? duration}) => PlaybackTrack(
    index: index,
    url: url,
    mimeType: mimeType,
    duration: duration ?? this.duration,
    isLocal: isLocal,
  );
}

class Chapter {
  final String title;
  final Duration start;
  Chapter({required this.title, required this.start});
}

class ChapterProgressMetrics {
  final int index;
  final int totalChapters;
  final Duration start;
  final Duration end;
  final Duration elapsed;
  final String? title;

  ChapterProgressMetrics({
    required this.index,
    required this.totalChapters,
    required this.start,
    required this.end,
    required this.elapsed,
    this.title,
  });

  Duration get duration => end - start;
}

class NowPlaying {
  final String libraryItemId;
  final String title;
  final String? author;
  final String? narrator;
  final String? coverUrl;
  final List<PlaybackTrack> tracks;
  final int currentIndex;
  final List<Chapter> chapters;
  final String? episodeId;

  const NowPlaying({
    required this.libraryItemId,
    required this.title,
    required this.tracks,
    required this.currentIndex,
    required this.chapters,
    this.author,
    this.narrator,
    this.coverUrl,
    this.episodeId,
  });

  NowPlaying copyWith({
    int? currentIndex,
    List<PlaybackTrack>? tracks,
    String? coverUrl,
  }) =>
      NowPlaying(
        libraryItemId: libraryItemId,
        title: title,
        author: author,
        narrator: narrator,
        coverUrl: coverUrl ?? this.coverUrl,
        tracks: tracks ?? this.tracks,
        currentIndex: currentIndex ?? this.currentIndex,
        chapters: chapters,
        episodeId: episodeId,
      );
}

class PlaybackRepository {
  final StreamController<String> _debugLogCtr = StreamController.broadcast();
  Stream<String> get debugLogStream => _debugLogCtr.stream;

  void _log(String msg) {
    // Logging removed for cleaner console output
  }

  PlaybackRepository(this._auth) {
    _init();
  }

  final AuthRepository _auth;
  final AudioPlayer player = AudioPlayer();

  /// Emits current progress sync status for UI (player / mini-player).
  final ValueNotifier<ProgressSyncStatus> progressSyncStatus =
      ValueNotifier<ProgressSyncStatus>(const ProgressSyncStatus());

  final StreamController<NowPlaying?> _nowPlayingCtr =
  StreamController.broadcast();
  NowPlaying? _nowPlaying;
  Stream<NowPlaying?> get nowPlayingStream => _nowPlayingCtr.stream;
  NowPlaying? get nowPlaying => _nowPlaying;

  // Book completion status stream
  final StreamController<Map<String, bool>> _completionStatusCtr =
  StreamController.broadcast();
  Stream<Map<String, bool>> get completionStatusStream => _completionStatusCtr.stream;
  final Map<String, bool> completionCache = {};

  Stream<bool> get playingStream => player.playingStream;
  Stream<Duration> get positionStream => player.createPositionStream();
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<ProcessingState> get processingStateStream =>
      player.processingStateStream;

  String? _progressItemId;
  String? _activeSessionId; // Remote streaming session id (if any)
  final Map<String, _CachedProgressValue> _serverProgressCache = <String, _CachedProgressValue>{};
  final Map<String, DateTime> _completionTimestamps = <String, DateTime>{};
  static const _progressCacheTtl = Duration(seconds: 20);
  static const _completionCacheTtl = Duration(seconds: 30);

  // Detailed listening session tracking (local-only, optional).
  DateTime? _listeningStartedAt;
  double? _listeningStartPositionSeconds;
  String? _listeningItemId;
  String? _listeningTitle;
  String? _listeningAuthor;
  String? _listeningNarrator;
  String? _listeningCoverUrl;

  void _beginListeningSession({double? startPositionSeconds}) {
    final np = _nowPlaying;
    if (np == null) return;
    _listeningStartedAt = DateTime.now();
    _listeningStartPositionSeconds = startPositionSeconds ?? (_computeGlobalPositionSec() ?? 0.0);
    _listeningItemId = np.libraryItemId;
    _listeningTitle = np.title;
    _listeningAuthor = np.author;
    _listeningNarrator = np.narrator;
    _listeningCoverUrl = np.coverUrl;
  }

  void _clearListeningSession() {
    _listeningStartedAt = null;
    _listeningStartPositionSeconds = null;
    _listeningItemId = null;
    _listeningTitle = null;
    _listeningAuthor = null;
    _listeningNarrator = null;
    _listeningCoverUrl = null;
  }

  void _endListeningSession() {
    final startedAt = _listeningStartedAt;
    final itemId = _listeningItemId;
    if (startedAt == null || itemId == null || itemId.isEmpty) {
      _clearListeningSession();
      return;
    }
    final elapsed = DateTime.now().difference(startedAt);
    if (elapsed < const Duration(seconds: 5)) {
      _clearListeningSession();
      return;
    }
    final session = PlaySession(
      bookId: itemId,
      bookTitle: _listeningTitle ?? 'Audiobook',
      author: _listeningAuthor,
      narrator: _listeningNarrator,
      coverUrl: _listeningCoverUrl,
      startPositionSeconds: (_listeningStartPositionSeconds ?? 0.0).clamp(0.0, double.infinity),
      playDurationSeconds: elapsed.inMilliseconds / 1000.0,
      timestamp: DateTime.now(),
    );
    _clearListeningSession();
    unawaited(DetailedPlayHistoryService.addSession(session));
  }

  void _markSyncAttempt() {
    final now = DateTime.now();
    final prev = progressSyncStatus.value;
    progressSyncStatus.value = prev.copyWith(
      lastAttemptAt: now,
      consecutiveFailures: prev.consecutiveFailures,
      lastError: prev.lastError,
    );
  }

  void _markSyncSuccess() {
    final now = DateTime.now();
    progressSyncStatus.value = ProgressSyncStatus(
      lastAttemptAt: now,
      lastSuccessAt: now,
      pending: false,
      consecutiveFailures: 0,
      lastError: null,
    );
  }

  void _markSyncFailure(String message) {
    final now = DateTime.now();
    final prev = progressSyncStatus.value;
    progressSyncStatus.value = ProgressSyncStatus(
      lastAttemptAt: now,
      lastSuccessAt: prev.lastSuccessAt,
      pending: true,
      consecutiveFailures: (prev.consecutiveFailures + 1).clamp(0, 999999),
      lastError: message,
    );
  }

  late final WidgetsBindingObserver _lifecycleHook = _LifecycleHook(
    onPauseOrDetach: () async {
      await _sendProgressImmediate(paused: true);
      await _closeActiveSession();
    },
    onResume: () async {
      // Refresh chapter metadata when app resumes in case network is now available
      if (_nowPlaying != null) {
        // Delay the refresh to avoid blocking the resume
        Future.delayed(const Duration(seconds: 2), () {
          refreshChapterMetadata();
        });
      }
    },
  );

  Future<List<PlaybackTrack>> getPlayableTracks(String libraryItemId,
      {String? episodeId}) =>
      _getTracksPreferLocal(libraryItemId, episodeId: episodeId);

  /// Always fetch remote/stream tracks (ignores local files) for metadata like total count.
  Future<List<PlaybackTrack>> getRemoteTracks(String libraryItemId, {String? episodeId}) {
    return _streamTracks(libraryItemId, episodeId: episodeId);
  }

  /// Expose opening a streaming session to callers that need the session id
  /// (e.g., downloads) without affecting the player's own active session.
  Future<StreamTracksResult> openSessionAndGetTracks(String libraryItemId, {String? episodeId}) {
    return _openSessionAndGetTracks(libraryItemId, episodeId: episodeId);
  }

  /// Total number of tracks for an item (local preferred to avoid opening sessions).
  /// Only opens a session if local tracks are not available and we actually need the count.
  Future<int> getTotalTrackCount(String libraryItemId, {String? episodeId}) async {
    // Prefer local tracks to avoid opening unnecessary sessions
    final local = await _localTracks(libraryItemId);
    if (local.isNotEmpty) {
      return local.length;
    }
    // Only open session if we really need the count and have no local tracks
    // This should be rare - most calls should have local tracks available
    try {
      final remote = await _streamTracks(libraryItemId, episodeId: episodeId);
      return remote.length;
    } catch (_) {
      return 0;
    }
  }

  /// Warm-load last item (server position wins). If [playAfterLoad] true, will start playback.
  Future<void> warmLoadLastItem({bool playAfterLoad = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_kLastItemKey);
      if (last == null || last.isEmpty) return;

      // If we're already playing the same item and playAfterLoad is true, 
      // don't restart playback - just ensure we're ready to continue
      if (playAfterLoad && _nowPlaying?.libraryItemId == last && player.playing) {
        _log('Warm load: already playing $last, skipping restart');
        return;
      }

      // Try fast local path first for offline support
      final localTracks = await _localTracks(last);
      if (localTracks.isNotEmpty) {
        _log('Warm load (offline/local): found ${localTracks.length} local tracks');
        // Try to get cached book metadata from local DB
        String title = 'Audiobook';
        String? author;
        String? coverUrl;
        try {
          final repo = await BooksRepository.create();
          final b = await repo.getBookFromDb(last);
          if (b != null) {
            title = b.title.isNotEmpty ? b.title : title;
            author = b.author; // Do not fall back to narrator for artist
            coverUrl = b.coverUrl;
          }
        } catch (_) {}

        // Always fetch a fresh cover URL (tokenized) to avoid stale/expired images
        final refreshedCover = await _coverUrl(last);
        final effectiveCoverUrl = (refreshedCover != null && refreshedCover.isNotEmpty)
            ? refreshedCover
            : coverUrl;

        // Do not attempt to ensure durations online; play with what we have
        // But try to get proper chapter metadata from server for better chapter titles
        List<Chapter> chapters = _chaptersFromTracks(localTracks);
        
        // Try to fetch proper chapter metadata from server
        try {
          final meta = await _getItemMeta(last);
          final serverChapters = _extractChapters(meta);
          if (serverChapters.isNotEmpty) {
            chapters = serverChapters;
            _log('Warm load: using server chapter metadata (${chapters.length} chapters)');
            // Cache the server chapters for future use
            await _cacheChapterMetadata(last, serverChapters);
          } else {
            _log('Warm load: no server chapters found, trying cached chapters');
            // Try to load cached chapter metadata
            final cachedChapters = await _loadCachedChapterMetadata(last);
            if (cachedChapters.isNotEmpty) {
              chapters = cachedChapters;
              _log('Warm load: using cached chapter metadata (${chapters.length} chapters)');
            } else {
              _log('Warm load: no cached chapters found, using local track-based chapters');
            }
          }
        } catch (e) {
          _log('Warm load: failed to fetch server chapter metadata: $e, trying cached chapters');
          // Try to load cached chapter metadata as fallback
          final cachedChapters = await _loadCachedChapterMetadata(last);
          if (cachedChapters.isNotEmpty) {
            chapters = cachedChapters;
            _log('Warm load: using cached chapter metadata (${chapters.length} chapters)');
          } else {
            _log('Warm load: no cached chapters available, using local track-based chapters');
          }
        }
        
        final np = NowPlaying(
          libraryItemId: last,
          title: title,
          author: author,
          narrator: null, // Narrator not available from local cache
          coverUrl: effectiveCoverUrl,
          tracks: localTracks,
          currentIndex: 0,
          chapters: chapters,
        );
        _log('Warm load: setting nowPlaying for downloaded book: ${np.title}, tracks: ${np.tracks.length}, playAfterLoad: $playAfterLoad');
        _setNowPlaying(np);
        _progressItemId = last;

        // Resume from cached position (local or server if available)
        // Force refresh to get latest server progress and avoid stale cache
        double? resumeSec;
        try { resumeSec = await fetchServerProgress(last, forceRefresh: true); } catch (_) {}
        resumeSec ??= prefs.getDouble('$_kLocalProgPrefix$last');

        if (resumeSec != null && resumeSec > 0) {
          final map = _mapGlobalSecondsToTrack(resumeSec, np.tracks);
          await _setTrackAt(map.index, preload: true);
          await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
        } else {
          await _setTrackAt(0, preload: true);
        }

        if (playAfterLoad) {
          // Apply smart rewind before resuming playback
          try {
            if (await SmartRewindService.instance.isEnabled()) {
              final rewind = await SmartRewindService.instance.computeRewind();
              final seconds = rewind.inSeconds;
              if (seconds > 0) {
                await nudgeSeconds(-seconds);
              }
            }
          } catch (_) {}

          await player.play();
          
          // Apply saved playback speed
          try {
            await PlaybackSpeedService.instance.applyCurrentSpeed();
          } catch (e) {
            _log('Failed to apply current playback speed: $e');
          }
          
          await _sendProgressImmediate();
        }
        return;
      }

      // Fallback to original online path if no local audio is available.
      // IMPORTANT: Do not open a remote streaming session here unless we will actually play.
      // Avoid calling /play on warm load to prevent opening sessions prematurely.
      if (!playAfterLoad) {
        _log('Warm load: skipping remote /play to avoid opening session. Will defer until actual playback.');
        return;
      }

      final meta = await _getItemMeta(last);
      _log('Warm load (playAfterLoad=true) metadata for $last: keys=${meta.keys.toList()}');
      var chapters = _extractChapters(meta);
      _log('Warm load extracted ${chapters.length} chapters');

      final open = await _openSessionAndGetTracks(last);
      final tracksWithDur = open.tracks;
      _activeSessionId = open.sessionId;
      _log('Warm load opened playback session: ${_activeSessionId ?? 'none'} with ${tracksWithDur.length} tracks');
      if (chapters.isEmpty && tracksWithDur.isNotEmpty) {
        chapters = _chaptersFromTracks(tracksWithDur);
        _log('Warm load generated ${chapters.length} chapters from tracks');
      }

      final np = NowPlaying(
        libraryItemId: last,
        title: _titleFromMeta(meta) ?? 'Audiobook',
        author: _authorFromMeta(meta), // Writer only; no narrator fallback for artist
        narrator: _narratorFromMeta(meta),
        coverUrl: await _coverUrl(last),
        tracks: tracksWithDur,
        currentIndex: 0,
        chapters: chapters,
      );
      _setNowPlaying(np);
      _progressItemId = last;

      // Force refresh to get latest server progress and avoid stale cache
      final resumeSec = await fetchServerProgress(last, forceRefresh: true) ??
          prefs.getDouble('$_kLocalProgPrefix$last');

      if (resumeSec != null && resumeSec > 0) {
        final map = _mapGlobalSecondsToTrack(resumeSec, np.tracks);
        await _setTrackAt(map.index, preload: true);
        await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
      } else {
        await _setTrackAt(0, preload: true);
      }

      // Apply smart rewind before starting playback
      try {
        if (await SmartRewindService.instance.isEnabled()) {
          final rewind = await SmartRewindService.instance.computeRewind();
          final seconds = rewind.inSeconds;
          if (seconds > 0) {
            await nudgeSeconds(-seconds);
          }
        }
      } catch (_) {}
      await player.play();
      
      // Apply saved playback speed
      try {
        await PlaybackSpeedService.instance.applyCurrentSpeed();
      } catch (e) {
        _log('Failed to apply current playback speed: $e');
      }
      
      await _sendProgressImmediate();
    } catch (e) {
      _log('warmLoadLastItem error: $e');
    }
  }

  Future<double?> fetchServerProgress(String libraryItemId, {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = _serverProgressCache[libraryItemId];
      if (cached != null && DateTime.now().difference(cached.timestamp) < _progressCacheTtl) {
        return cached.seconds;
      }
    }
    try {
      final api = _auth.api;
      final resp = await api.request('GET', '/api/me/progress/$libraryItemId');
      if (resp.statusCode != 200) return null;
      try {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) {
          if (data['currentTime'] is num) {
            final value = (data['currentTime'] as num).toDouble();
            _serverProgressCache[libraryItemId] = _CachedProgressValue(value, DateTime.now());
            return value;
          }
          if (data['currentTime'] is String) {
            final value = double.tryParse(data['currentTime'] as String);
            _serverProgressCache[libraryItemId] = _CachedProgressValue(value, DateTime.now());
            return value;
          }
          final first = _firstMapValue(data);
          if (first != null) {
            final v = first['currentTime'];
            if (v is num) {
              final value = v.toDouble();
              _serverProgressCache[libraryItemId] = _CachedProgressValue(value, DateTime.now());
              return value;
            }
            if (v is String) {
              final value = double.tryParse(v);
              _serverProgressCache[libraryItemId] = _CachedProgressValue(value, DateTime.now());
              return value;
            }
          }
        }
      } catch (_) {}
      return null;
    } on SocketException catch (_) {
      // Offline
      return null;
    } finally {
      _serverProgressCache.putIfAbsent(libraryItemId, () => _CachedProgressValue(null, DateTime.now()));
    }
  }

  /// Check if a book is marked as finished/completed on the server
  Future<bool> isBookCompleted(String libraryItemId, {bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final cached = completionCache[libraryItemId];
      final stamp = _completionTimestamps[libraryItemId];
      if (cached != null && stamp != null && DateTime.now().difference(stamp) < _completionCacheTtl) {
        return cached;
      }
    }
    try {
      final api = _auth.api;
      final resp = await api.request('GET', '/api/me/progress/$libraryItemId');
      if (resp.statusCode != 200) return completionCache[libraryItemId] ?? false;
      try {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) {
          if (data['isFinished'] == true) {
            completionCache[libraryItemId] = true;
            _completionTimestamps[libraryItemId] = DateTime.now();
            return true;
          }
          if (data['progress'] is num) {
            final progress = (data['progress'] as num).toDouble();
            final isCompleted = progress >= 0.99;
            completionCache[libraryItemId] = isCompleted;
            _completionTimestamps[libraryItemId] = DateTime.now();
            return isCompleted;
          }
          if (data['currentTime'] is num && data['duration'] is num) {
            final currentTime = (data['currentTime'] as num).toDouble();
            final duration = (data['duration'] as num).toDouble();
            if (duration > 0) {
              final isCompleted = (currentTime / duration) >= 0.99;
              completionCache[libraryItemId] = isCompleted;
              _completionTimestamps[libraryItemId] = DateTime.now();
              return isCompleted;
            }
          }
        }
      } catch (_) {}
      return completionCache[libraryItemId] ?? false;
    } on SocketException catch (_) {
      return completionCache[libraryItemId] ?? false;
    }
  }

  /// Update book completion status and notify all listeners
  Future<void> updateBookCompletionStatus(String libraryItemId, bool isCompleted) async {
    completionCache[libraryItemId] = isCompleted;
    _completionTimestamps[libraryItemId] = DateTime.now();
    final newCache = Map<String, bool>.from(completionCache);
    _completionStatusCtr.add(newCache);
    _log('Updated completion status for $libraryItemId: $isCompleted');
  }

  /// Get current completion status for a book (from cache)
  bool getBookCompletionStatus(String libraryItemId) {
    return completionCache[libraryItemId] ?? false;
  }

  /// Stream of completion status for a specific book
  Stream<bool> getBookCompletionStream(String libraryItemId) {
    return completionStatusStream.map((statusMap) {
      final result = statusMap[libraryItemId] ?? false;
      return result;
    });
  }

  /// Check if sync progress before play is enabled
  Future<bool> _shouldSyncProgressBeforePlay() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('sync_progress_before_play') ?? true;
    } catch (_) {
      return true; // Default to true if error
    }
  }

  /// Check if sync is required and server is available
  /// Returns true if sync is not required or if server is available
  /// Returns false if sync is required but server is unavailable
  /// Shows a dialog if offline and sync is required, allowing user to proceed
  Future<bool> _checkSyncRequirement({BuildContext? context}) async {
    final shouldSync = await _shouldSyncProgressBeforePlay();
    if (!shouldSync) return true; // Sync not required, proceed
    
    try {
      final api = _auth.api;
      await api.request('GET', '/api/me', auth: true).timeout(
        const Duration(seconds: 3),
        onTimeout: () {
          throw TimeoutException('Request timeout', const Duration(seconds: 3));
        },
      );
      return true; // Server is available
    } catch (e) {
      _log('Sync preflight failed: $e');
      if (context != null && context.mounted) {
        return await _showOfflineSyncDialog(context);
      }
      return false;
    }
  }

  /// Show dialog when offline and sync is required
  /// Returns true if user chooses to proceed, false if they cancel
  Future<bool> _showOfflineSyncDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'No Internet Connection',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You are currently offline. "Sync progress before play" is enabled, but progress cannot be synced right now.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: cs.primary.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 20,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Your progress will sync automatically when you come back online.',
                      style: text.bodyMedium?.copyWith(
                        color: cs.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Play Anyway'),
          ),
        ],
      ),
    );
    
    return result ?? false;
  }

  /// Clear all playback state (called on logout)
  Future<void> clearState() async {
    try {
      // Pause any active playback
      await player.pause();
      
      // Clear now playing state
      _setNowPlaying(null);
      _progressItemId = null;
      _activeSessionId = null;
      
      // Stop progress sync
      _stopProgressSync();
      
      // Clear local progress cache
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith(_kLocalProgPrefix) || key == _kLastItemKey) {
          await prefs.remove(key);
        }
      }
      
      _log('Playback state cleared');
    } catch (e) {
      _log('Error clearing playback state: $e');
    }
  }

  /// Validate and clear invalid cover image cache
  Future<void> _validateCoverImageCache(String? coverUrl) async {
    if (coverUrl == null || coverUrl.isEmpty) return;
    
    try {
      final cacheManager = DefaultCacheManager();
      final fileInfo = await cacheManager.getFileFromCache(coverUrl);
      
      if (fileInfo != null) {
        final file = fileInfo.file;
        bool shouldClear = false;
        
        if (await file.exists()) {
          final length = await file.length();
          if (length == 0) {
            shouldClear = true;
          } else {
            // Try to verify it's a valid image
            try {
              final bytes = await file.readAsBytes();
              if (bytes.isEmpty) {
                shouldClear = true;
              } else {
                // Check if cache entry is stale
                final now = DateTime.now();
                final validUntil = fileInfo.validTill;
                if (validUntil != null && now.isAfter(validUntil)) {
                  shouldClear = true;
                }
              }
            } catch (_) {
              shouldClear = true;
            }
          }
        } else {
          shouldClear = true;
        }
        
        if (shouldClear) {
          await cacheManager.removeFile(coverUrl);
          _log('Cleared invalid cover image cache for $coverUrl');
        }
      }
      
      // Prewarm the image after validation/clearing
      try {
        // Use a BuildContext if available, otherwise just clear cache
        // The image will be loaded fresh when needed
      } catch (_) {
        // If prewarming fails, continue anyway
      }
    } catch (_) {
      // If validation fails, continue anyway
    }
  }

  Future<bool> playItem(String libraryItemId, {String? episodeId, BuildContext? context}) async {
    // Guard: do not attempt playback if item appears to be non-audiobook
    try {
      final repo = await BooksRepository.create();
      final b = await repo.getBookFromDb(libraryItemId) ?? await repo.getBook(libraryItemId);
      if (b.isAudioBook == false) {
        _log('Blocked play for non-audiobook item $libraryItemId');
        return false;
      }
    } catch (_) {}

    // Check if sync is required and server is available
    final canProceed = await _checkSyncRequirement(context: context);
    if (!canProceed) {
      _log('Cannot play: server unavailable and sync progress is required, or user cancelled');
      return false;
    }

    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastItemKey, libraryItemId);

    final meta = await _getItemMeta(libraryItemId);
    _log('Loaded item metadata for $libraryItemId: keys=${meta.keys.toList()}');
    var chapters = _extractChapters(meta);
    _log('Extracted ${chapters.length} chapters');
    
    // Cache server chapters if we got them
    if (chapters.isNotEmpty) {
      await _cacheChapterMetadata(libraryItemId, chapters);
    }

    // Determine tracks and open a remote session only if we need to stream
    List<PlaybackTrack> tracks;
    String? openedSessionId;
    final localTracks = await _localTracks(libraryItemId);
    if (localTracks.isNotEmpty) {
      // Try to ensure local track durations by merging with remote metadata when available
      tracks = await _ensureDurations(localTracks, libraryItemId, episodeId: episodeId);
      _log('Using ${tracks.length} local tracks (no remote session opened)');
    } else {
      final open = await _openSessionAndGetTracks(libraryItemId, episodeId: episodeId);
      tracks = open.tracks;
      openedSessionId = open.sessionId;
      _log('Opened remote session ${openedSessionId ?? 'none'}; fetched ${tracks.length} streaming tracks');
    }
    if (chapters.isEmpty && tracks.isNotEmpty) {
      chapters = _chaptersFromTracks(tracks);
      _log('No chapters from metadata; generated ${chapters.length} from tracks');
    }

    final np = NowPlaying(
      libraryItemId: libraryItemId,
      title: _titleFromMeta(meta) ?? 'Audiobook',
      author: _authorFromMeta(meta), // Writer only; no narrator fallback for artist
      narrator: _narratorFromMeta(meta),
      coverUrl: await _coverUrl(libraryItemId),
      tracks: tracks,
      currentIndex: 0,
      chapters: chapters,
      episodeId: episodeId,
    );
    
    // Add to play history
    try {
      final book = await _getBookForHistory(libraryItemId);
      if (book != null) {
        await PlayHistoryService.addToHistory(book);
      }
    } catch (e) {
      // Don't fail playback if history tracking fails
      _log('Failed to add to play history: $e');
    }
    _setNowPlaying(np);
    _progressItemId = libraryItemId;
    _activeSessionId = openedSessionId;

    // Validate and clear invalid cover image cache in background
    unawaited(_validateCoverImageCache(np.coverUrl));

    // Update audio service with new now playing info
    _log('Updating audio service with now playing: ${np.title}');
    try {
      await AudioServiceBinding.instance.updateNowPlaying(np);
      _log('✓ Audio service updated successfully');
    } catch (e) {
      _log('❌ Failed to update audio service: $e');
    }

    // Check for progress reset/mismatch and get user confirmation if needed
    final decision = await _handleProgressResetConfirmation(libraryItemId, prefs, context);
    if (decision.cancelled) {
      _log('Playback cancelled by user during progress confirmation');
      return false;
    }

    final resumeSec = decision.position;
    if (resumeSec != null && resumeSec > 0) {
      final map = _mapGlobalSecondsToTrack(resumeSec, tracks);
      await _setTrackAt(map.index, preload: true);
      await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
    } else {
      await _setTrackAt(0, preload: true);
    }

    _startProgressSync(libraryItemId, episodeId: episodeId);

    player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        final cur = _nowPlaying;
        if (cur == null) return;
        final next = cur.currentIndex + 1;
        if (next < cur.tracks.length) {
          await _setTrackAt(next, preload: true);
          await player.play();
          
          // Apply saved playback speed
          try {
            await PlaybackSpeedService.instance.applyCurrentSpeed();
          } catch (e) {
            _log('Failed to apply current playback speed: $e');
          }
          
          await _sendProgressImmediate();
        } else {
          // Completed last track; mark finished and close session to stop transcodes
          _endListeningSession();
          await _sendProgressImmediate(finished: true);
          await _closeActiveSession();
          unawaited(StreamingCacheService.instance.evictForItem(cur.libraryItemId));
        }
      }
    });

    // Begin local listening session tracking (optional, enabled in settings).
    _beginListeningSession(startPositionSeconds: resumeSec ?? (_computeGlobalPositionSec() ?? 0.0));
    await player.play();
    
    // Apply saved playback speed
    try {
      await PlaybackSpeedService.instance.applyCurrentSpeed();
    } catch (e) {
      _log('Failed to apply current playback speed: $e');
    }
    
    await _sendProgressImmediate();
    return true;
  }

  /// UPDATED: Send position to server on pause
  Future<void> pause() async {
    final np = _nowPlaying;
    final globalPos = globalBookPosition;
    final chapterMetrics = currentChapterProgress;
    // Optionally stop any active sleep timer based on user setting
    try {
      final prefs = await SharedPreferences.getInstance();
      final shouldCancel = prefs.getBool('pause_cancels_sleep_timer') ?? true;
      if (shouldCancel) {
        SleepTimerService.instance.stopTimer();
      }
    } catch (_) {}
    await player.pause();
    _endListeningSession();
    await _sendProgressImmediate(paused: true);
    await _closeActiveSession();
    try { await SmartRewindService.instance.recordPauseNow(); } catch (_) {}
    if (np != null && globalPos != null) {
      final chapterTitle = chapterMetrics?.title ??
          (chapterMetrics != null ? 'Chapter ${chapterMetrics.index + 1}' : null);
      unawaited(PlaybackJournalService.instance.recordHistoryEntry(
        libraryItemId: np.libraryItemId,
        bookTitle: np.title,
        positionMs: globalPos.inMilliseconds,
        chapterTitle: chapterTitle,
        chapterIndex: chapterMetrics?.index,
      ));
    }
  }

  /// UPDATED: Check server position and sync before resuming
  Future<bool> resume({bool skipSync = false, BuildContext? context}) async {
    final itemId = _progressItemId;
    final np = _nowPlaying;
    
    // Refresh cover URL (tokenized) and validate cache to avoid missing images after reopen
    if (np != null) {
      try {
        final freshCover = await _coverUrl(np.libraryItemId);
        if (freshCover != null && freshCover.isNotEmpty && freshCover != np.coverUrl) {
          final updated = np.copyWith(coverUrl: freshCover);
          _setNowPlaying(updated);
          unawaited(_validateCoverImageCache(freshCover));
        } else {
          unawaited(_validateCoverImageCache(np.coverUrl));
        }
      } catch (_) {
        unawaited(_validateCoverImageCache(np.coverUrl));
      }
    }
    
    // Check if sync is required and server is available (unless skipSync is true)
    if (!skipSync) {
      final canProceed = await _checkSyncRequirement(context: context);
      if (!canProceed) {
        _log('Cannot resume: server unavailable and sync progress is required');
        return false;
      }
    }
    
    if (itemId != null && np != null && !skipSync) {
      await _syncPositionFromServer();
      if ((_activeSessionId == null || _activeSessionId!.isEmpty) && np.tracks.isNotEmpty && !np.tracks.first.isLocal) {
        // Re-open streaming session after pause/close
        try {
          final open = await _openSessionAndGetTracks(itemId, episodeId: np.episodeId);
          _activeSessionId = open.sessionId;
          final tracks = open.tracks;
          // Preserve current global position
          final curSec = _computeGlobalPositionSec() ?? _trackOnlyPosSec() ?? 0.0;
          // Update nowPlaying with fresh tracks and seek appropriately
          final updated = np.copyWith(tracks: tracks);
          _setNowPlaying(updated);
          // Validate cover image cache for updated NowPlaying
          unawaited(_validateCoverImageCache(updated.coverUrl));
          final map = _mapGlobalSecondsToTrack(curSec, tracks);
          await _setTrackAt(map.index, preload: true);
          await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
        } catch (e) {
          _log('Failed to reopen session on resume: $e');
        }
      }
    }
    // Apply smart rewind before resuming playback
    try {
      if (await SmartRewindService.instance.isEnabled()) {
        final rewind = await SmartRewindService.instance.computeRewind();
        final seconds = rewind.inSeconds;
        if (seconds > 0) {
          await nudgeSeconds(-seconds);
        }
      }
    } catch (_) {}

    // Begin local listening session tracking (optional, enabled in settings).
    _beginListeningSession(startPositionSeconds: _computeGlobalPositionSec() ?? (_trackOnlyPosSec() ?? 0.0));
    await player.play();
    
    // Apply saved playback speed
    try {
      await PlaybackSpeedService.instance.applyCurrentSpeed();
    } catch (e) {
      _log('Failed to apply current playback speed: $e');
    }
    
    await _sendProgressImmediate();
    return true;
  }

  /// New method: Sync position from server before playing
  Future<void> _syncPositionFromServer() async {
    final itemId = _progressItemId;
    final np = _nowPlaying;
    if (itemId == null || np == null) return;

    try {
      _log('Checking server position before resume...');
      final serverSec = await fetchServerProgress(itemId);
      if (serverSec == null) return;

      // Get current local position
      final currentSec = _computeGlobalPositionSec() ?? _trackOnlyPosSec();
      if (currentSec == null) return;

      // If server position differs by more than 5 seconds, sync to server position
      const threshold = 5.0;
      final diff = (serverSec - currentSec).abs();

      if (diff > threshold) {
        _log('Server position ($serverSec) differs from local ($currentSec) by ${diff.toStringAsFixed(1)}s. Syncing...');

        final map = _mapGlobalSecondsToTrack(serverSec, np.tracks);

        // Switch track if necessary
        if (map.index != np.currentIndex) {
          await _setTrackAt(map.index, preload: true);
        }

        // Seek to the correct position
        await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));

        _log('Synced to server position: track ${map.index}, offset ${map.offsetSec.toStringAsFixed(1)}s');
      } else {
        _log('Server position matches local position (diff: ${diff.toStringAsFixed(1)}s)');
      }
    } catch (e) {
      _log('Error syncing position from server: $e');
    }
  }

  /// Handle progress reset confirmation when server progress is reset but local progress exists
  /// Decide which position to start from (server/local) and allow cancel.
  /// Returns a record: position (nullable) and cancelled flag.
  Future<({double? position, bool cancelled})> _handleProgressResetConfirmation(
      String libraryItemId, SharedPreferences prefs, BuildContext? context) async {
    try {
      // Get server progress
      double? serverSec;
      try {
        serverSec = await fetchServerProgress(libraryItemId);
      } catch (_) {
        // offline: ignore
      }
      
      // Get local progress
      final localSec = prefs.getDouble('$_kLocalProgPrefix$libraryItemId');
      
      // Check if we have a progress reset scenario:
      // - Server progress is 0 or null (reset)
      // - Local progress exists and is > 0
      // - Sync before play is enabled (we'll always warn when server is reset)
      // Treat a real server reset only when the server explicitly returns 0 or less.
      // If serverSec is null (offline/no data), do NOT consider it a reset — prefer local.
      final serverReset = serverSec != null && serverSec <= 0;
      final hasLocalProgress = localSec != null && localSec > 0;
      final shouldSync = await _shouldSyncProgressBeforePlay();
      
      if (serverReset && hasLocalProgress) {
        _log('Progress reset detected: server=${serverSec ?? 0}, local=$localSec');
        
        // Show confirmation dialog
        final choice = await _showProgressResetDialog(libraryItemId, localSec, context, shouldSync);
        
        switch (choice) {
          case ProgressResetChoice.useServer:
            _log('User chose to use server position (reset)');
            return (position: serverSec, cancelled: false); // Will be 0 or null, so starts from beginning
          case ProgressResetChoice.useLocal:
            _log('User chose to use local position');
            return (position: localSec, cancelled: false);
          case ProgressResetChoice.cancel:
            _log('User cancelled playback');
            return (position: null, cancelled: true); // This will cause playItem to return false
        }
      }

      // If both positions exist and differ significantly, warn and ask which to use
      if (shouldSync && serverSec != null && localSec != null) {
        final diff = (serverSec - localSec).abs();
        if (diff >= 60.0) {
          final choice = await _showProgressMismatchDialog(
            libraryItemId,
            serverSec,
            localSec,
            context,
          );
          switch (choice) {
            case ProgressResetChoice.useServer:
              _log('User chose server position after mismatch warning');
              return (position: serverSec, cancelled: false);
            case ProgressResetChoice.useLocal:
              _log('User chose local position after mismatch warning');
              return (position: localSec, cancelled: false);
            case ProgressResetChoice.cancel:
              _log('User cancelled playback after mismatch warning');
              return (position: null, cancelled: true);
          }
        }
      }
      
      // Default behavior: prefer server only if it's > 0; otherwise prefer local when available
      if (serverSec != null && serverSec > 0) return (position: serverSec, cancelled: false);
      if (localSec != null && localSec > 0) return (position: localSec, cancelled: false);
      return (position: serverSec ?? localSec, cancelled: false);
    } catch (e) {
      _log('Error in progress reset confirmation: $e');
      // Fallback to original behavior
      try {
        final serverSec = await fetchServerProgress(libraryItemId);
        final localSec = prefs.getDouble('$_kLocalProgPrefix$libraryItemId');
        if (serverSec != null && serverSec > 0) return (position: serverSec, cancelled: false);
        if (localSec != null && localSec > 0) return (position: localSec, cancelled: false);
        return (position: serverSec ?? localSec, cancelled: false);
      } catch (_) {
        final localSec = prefs.getDouble('$_kLocalProgPrefix$libraryItemId');
        return (position: localSec, cancelled: false);
      }
    }
  }

  /// Show confirmation dialog for progress reset scenario
  Future<ProgressResetChoice> _showProgressResetDialog(String libraryItemId, double localSec, BuildContext? context, bool syncEnabled) async {
    if (context == null) {
      _log('No context available for progress reset dialog, defaulting to local position');
      return ProgressResetChoice.useLocal;
    }

    // Format the local progress time
    final localDuration = Duration(milliseconds: (localSec * 1000).round());
    final localTimeStr = _formatDuration(localDuration);

    return await showDialog<ProgressResetChoice>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Progress Reset Detected'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                syncEnabled 
                  ? 'The server progress for this book has been reset, but you have local progress saved.'
                  : 'The server progress for this book has been reset. You have local progress that will be lost if you start from the beginning.',
                style: const TextStyle(fontSize: 16),
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Your local progress: $localTimeStr',
                      style: const TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'What would you like to do?',
                style: TextStyle(fontWeight: FontWeight.w500),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(ProgressResetChoice.cancel),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(ProgressResetChoice.useServer),
              child: const Text('Start from beginning'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(ProgressResetChoice.useLocal),
              child: Text('Resume from $localTimeStr'),
            ),
          ],
        );
      },
    ) ?? ProgressResetChoice.useServer; // Default to server if dialog is dismissed
  }

  /// Format duration for display
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Show dialog when server/local positions differ significantly
  Future<ProgressResetChoice> _showProgressMismatchDialog(
      String libraryItemId, double serverSec, double localSec, BuildContext? context) async {
    if (context == null) {
      _log('No context for mismatch dialog, defaulting to local position');
      return ProgressResetChoice.useLocal;
    }

    String _fmt(double sec) {
      final d = Duration(milliseconds: (sec * 1000).round());
      final two = (int v) => v.toString().padLeft(2, '0');
      final h = d.inHours;
      final m = two(d.inMinutes.remainder(60));
      final s = two(d.inSeconds.remainder(60));
      return h > 0 ? '$h:$m:$s' : '$m:$s';
    }

    final diff = (serverSec - localSec).abs();
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final result = await showDialog<ProgressResetChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Choose position to start',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Server and local positions differ by ${diff.toStringAsFixed(0)} seconds. Which one should we use?',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: cs.primary.withOpacity(0.3), width: 1),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Server: ${_fmt(serverSec)}', style: text.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
                  const SizedBox(height: 4),
                  Text('Local: ${_fmt(localSec)}', style: text.bodyMedium?.copyWith(color: cs.onPrimaryContainer)),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(ProgressResetChoice.cancel),
            child: Text('Cancel', style: TextStyle(color: cs.onSurfaceVariant)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(ProgressResetChoice.useLocal),
            child: const Text('Use Local'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(ProgressResetChoice.useServer),
            child: const Text('Use Server'),
          ),
        ],
      ),
    );

    return result ?? ProgressResetChoice.cancel;
  }

  /// When scrubbing, pass `reportNow: false` repeatedly; only call once with true at the end.
  Future<void> seek(Duration pos, {bool reportNow = true}) async {
    await player.seek(pos);
    if (reportNow) {
      await _sendProgressImmediate(
        overrideTrackPosSec: pos.inMilliseconds / 1000.0,
      );
    }
  }

  Future<void> nudgeSeconds(int delta) async {
    final total = player.duration ?? Duration.zero;
    var target = player.position + Duration(seconds: delta);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    await seek(target, reportNow: true);
  }

  // ---- Public global duration/position helpers ----
  /// Total duration across all tracks, if all track durations are known.
  Duration? get totalBookDuration {
    final sec = _computeTotalDurationSec();
    if (sec == null) return null;
    return Duration(milliseconds: (sec * 1000).round());
  }

  /// Current global position from book start, if computable.
  Duration? get globalBookPosition {
    final sec = _computeGlobalPositionSec();
    if (sec == null) return null;
    return Duration(milliseconds: (sec * 1000).round());
  }

  /// Seek using a global position from the start of the book across tracks.
  /// Falls back to clamped range when the target exceeds known total.
  Future<void> seekGlobal(Duration globalPosition, {bool reportNow = true}) async {
    final np = _nowPlaying;
    if (np == null) return;

    // Clamp to [0, total]
    double targetSec = globalPosition.inMilliseconds / 1000.0;
    final totalSec = _computeTotalDurationSec();
    if (targetSec < 0) targetSec = 0.0;
    if (totalSec != null && targetSec > totalSec) targetSec = totalSec;

    final map = _mapGlobalSecondsToTrack(targetSec, np.tracks);
    final targetOffset = Duration(milliseconds: (map.offsetSec * 1000).round());
    
    // If switching tracks, preserve playback state
    final wasPlaying = player.playing;
    if (map.index != np.currentIndex) {
      await _setTrackAt(map.index, preload: true);
      // Small delay to ensure track is loaded before seeking
      await Future.delayed(const Duration(milliseconds: 50));
    }
    
    // Seek to the target position
    await player.seek(targetOffset);
    
    // Restore playback state if it was playing
    if (wasPlaying && !player.playing) {
      await player.play();
    }
    
    if (reportNow) {
      await _sendProgressImmediate(overrideTrackPosSec: map.offsetSec);
    }
  }

  ChapterProgressMetrics? get currentChapterProgress {
    final np = _nowPlaying;
    if (np == null || np.chapters.isEmpty) return null;
    final total = totalBookDuration;
    final globalPos = globalBookPosition;
    if (total == null || globalPos == null) return null;

    int chapterIdx = 0;
    for (int i = 0; i < np.chapters.length; i++) {
      if (globalPos >= np.chapters[i].start) {
        chapterIdx = i;
      } else {
        break;
      }
    }

    final chapter = np.chapters[chapterIdx];
    final start = chapter.start;
    final end = (chapterIdx + 1 < np.chapters.length) ? np.chapters[chapterIdx + 1].start : total;
    if (end <= start) return null;
    final duration = end - start;
    var elapsed = globalPos - start;
    if (elapsed.isNegative) elapsed = Duration.zero;
    if (elapsed > duration) elapsed = duration;

    return ChapterProgressMetrics(
      index: chapterIdx,
      totalChapters: np.chapters.length,
      start: start,
      end: end,
      elapsed: elapsed,
      title: chapter.title.isEmpty ? null : chapter.title,
    );
  }

  Future<void> reportProgressNow() => _sendProgressImmediate();

  Future<double?> getCachedProgressSeconds(String libraryItemId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final local = prefs.getDouble('$_kLocalProgPrefix$libraryItemId');
      if (local != null) return local;
    } catch (_) {}
    return fetchServerProgress(libraryItemId);
  }

  Future<void> sendCompletionUpdate(
    String libraryItemId,
    bool finished, {
    double? overrideCurrentTimeSeconds,
  }) async {
    double? currentSeconds = overrideCurrentTimeSeconds;
    final total = _computeTotalDurationSec();
    final isActive = _nowPlaying?.libraryItemId == libraryItemId;
    if (currentSeconds == null) {
      if (isActive) currentSeconds = _computeGlobalPositionSec();
      currentSeconds ??= await getCachedProgressSeconds(libraryItemId);
    }

    if (isActive && _activeSessionId != null && currentSeconds != null) {
      final synced = await _syncSession(
        cur: currentSeconds,
        total: total,
        finished: finished,
        paused: true,
      );
      if (synced) {
        await updateBookCompletionStatus(libraryItemId, finished);
        return;
      }
    }

    await _patchProgressCompletion(
      libraryItemId: libraryItemId,
      finished: finished,
      currentSeconds: currentSeconds,
      totalSeconds: total,
    );
    await updateBookCompletionStatus(libraryItemId, finished);
  }

  Future<void> setSpeed(double speed) => player.setSpeed(speed.clamp(0.5, 3.0));
  bool get hasPrev => _nowPlaying != null && _nowPlaying!.currentIndex > 0;
  bool get hasNext =>
      _nowPlaying != null &&
          _nowPlaying!.currentIndex + 1 < _nowPlaying!.tracks.length;

  /// Smart availability check for previous: considers both tracks and chapters
  bool get hasSmartPrev {
    final np = _nowPlaying;
    if (np == null) return false;
    
    // Multi-track books: use track-based logic
    if (np.tracks.length > 1) {
      return hasPrev;
    }
    
    // Single-track books with chapters: check if there's a previous chapter
    if (np.tracks.length == 1 && np.chapters.isNotEmpty) {
      final chapterNav = ChapterNavigationService.instance;
      return chapterNav.getPreviousChapter() != null;
    }
    
    // Fallback to track-based logic
    return hasPrev;
  }

  /// Smart availability check for next: considers both tracks and chapters
  bool get hasSmartNext {
    final np = _nowPlaying;
    if (np == null) return false;
    
    // Multi-track books: use track-based logic
    if (np.tracks.length > 1) {
      return hasNext;
    }
    
    // Single-track books with chapters: check if there's a next chapter
    if (np.tracks.length == 1 && np.chapters.isNotEmpty) {
      final chapterNav = ChapterNavigationService.instance;
      return chapterNav.getNextChapter() != null;
    }
    
    // Fallback to track-based logic
    return hasNext;
  }

  Future<void> prevTrack() async {
    SleepTimerService.instance.cancelChapterSleepIfActive();
    if (!hasPrev) return;
    final idx = _nowPlaying!.currentIndex - 1;
    await _setTrackAt(idx, preload: true);
    await player.play();
    
    // Apply saved playback speed
    try {
      await PlaybackSpeedService.instance.applyCurrentSpeed();
    } catch (e) {
      _log('Failed to apply current playback speed: $e');
    }
    
    await _sendProgressImmediate();
  }

  /// Smart previous navigation: uses chapter navigation for single-track books, track navigation for multi-track books
  Future<void> smartPrev() async {
    final np = _nowPlaying;
    if (np == null) return;
    SleepTimerService.instance.cancelChapterSleepIfActive();
    
    // If we have multiple tracks, use track-based navigation
    if (np.tracks.length > 1 && hasPrev) {
      await prevTrack();
      return;
    }
    
    // If we have a single track with chapters, use chapter navigation
    if (np.tracks.length == 1 && np.chapters.isNotEmpty) {
      final chapterNav = ChapterNavigationService.instance;
      final prevChapter = chapterNav.getPreviousChapter();
      if (prevChapter != null) {
        await chapterNav.jumpToChapter(prevChapter);
        await _sendProgressImmediate();
      }
      return;
    }
    
    // Fallback to regular track navigation
    if (hasPrev) {
      await prevTrack();
    }
  }

  Future<void> nextTrack() async {
    SleepTimerService.instance.cancelChapterSleepIfActive();
    if (!hasNext) return;
    final idx = _nowPlaying!.currentIndex + 1;
    await _setTrackAt(idx, preload: true);
    await player.play();
    
    // Apply saved playback speed
    try {
      await PlaybackSpeedService.instance.applyCurrentSpeed();
    } catch (e) {
      _log('Failed to apply current playback speed: $e');
    }
    
    await _sendProgressImmediate();
  }

  /// Smart next navigation: uses chapter navigation for single-track books, track navigation for multi-track books
  Future<void> smartNext() async {
    final np = _nowPlaying;
    if (np == null) return;
    SleepTimerService.instance.cancelChapterSleepIfActive();
    
    // If we have multiple tracks, use track-based navigation
    if (np.tracks.length > 1 && hasNext) {
      await nextTrack();
      return;
    }
    
    // If we have a single track with chapters, use chapter navigation
    if (np.tracks.length == 1 && np.chapters.isNotEmpty) {
      final chapterNav = ChapterNavigationService.instance;
      final nextChapter = chapterNav.getNextChapter();
      if (nextChapter != null) {
        await chapterNav.jumpToChapter(nextChapter);
        await _sendProgressImmediate();
      }
      return;
    }
    
    // Fallback to regular track navigation
    if (hasNext) {
      await nextTrack();
    }
  }

  Future<void> stop() async {
    // Also stop any active sleep timer
    try { SleepTimerService.instance.stopTimer(); } catch (_) {}
    _endListeningSession();
    await player.stop();
    await _sendProgressImmediate(finished: true);
    _stopProgressSync();
    _setNowPlaying(null);
    _progressItemId = null;
    await _closeActiveSession();
    
    // Stop Dynamic Island Live Activity
    AudioServiceManager.instance.stopDynamicIsland();
  }

  /// If the current item has fully downloaded local files, switch playback from
  /// streaming URLs to local file paths seamlessly, preserving track index and
  /// in-track position. Returns true if a switch occurred.
  Future<bool> switchToLocalIfAvailableFor(String libraryItemId) async {
    final np = _nowPlaying;
    if (np == null) return false;
    if (np.libraryItemId != libraryItemId) return false;

    // Ensure local files exist (ideally full set)
    final local = await _localTracks(libraryItemId);
    if (local.isEmpty) return false;
    // Require that the current index is valid within local tracks
    if (np.currentIndex >= local.length) return false;
    unawaited(StreamingCacheService.instance.evictForItem(libraryItemId));

    final wasPlaying = player.playing;
    // CRITICAL: Use global position to preserve position across tracks - calculate BEFORE updating tracks
    final globalPosSec = _computeGlobalPositionSec();
    final curIndex = np.currentIndex;
    final curTrackPos = player.position; // Also save current track position as backup

    // Merge known durations from current tracks to local tracks by index
    // CRITICAL: Preserve all durations from current tracks to ensure accurate position mapping
    try {
      final merged = <PlaybackTrack>[];
      for (final lt in local) {
        double dur = lt.duration;
        try {
          // Find matching track by index to preserve duration
          final match = np.tracks.firstWhere((t) => t.index == lt.index, orElse: () => lt);
          if (match.duration > 0) {
            dur = match.duration; // Use existing duration from streaming track
          }
        } catch (_) {}
        merged.add(PlaybackTrack(
          index: lt.index,
          url: lt.url,
          mimeType: lt.mimeType,
          duration: dur,
          isLocal: true,
        ));
      }
      // Replace tracks with local (with merged durations) without changing metadata/author
      final updated = np.copyWith(tracks: merged);
      _setNowPlaying(updated);
    } catch (_) {
      // Fallback: no merge
      final updated = np.copyWith(tracks: local);
      _setNowPlaying(updated);
    }

    // CRITICAL: Restore position using global position - this ensures accuracy across tracks
    if (globalPosSec != null && globalPosSec > 0) {
      // Map global position to track index and offset using UPDATED tracks (with local URLs but preserved durations)
      final updatedNp = _nowPlaying; // Get the updated nowPlaying after track switch
      if (updatedNp != null && updatedNp.tracks.isNotEmpty) {
        // Calculate target track and offset BEFORE loading the track
        final map = _mapGlobalSecondsToTrack(globalPosSec, updatedNp.tracks);
        final targetIndex = map.index.clamp(0, updatedNp.tracks.length - 1);
        final targetOffsetSec = map.offsetSec;
        final targetOffsetMs = (targetOffsetSec * 1000).round();
        
        // CRITICAL: Load the target track first
        final needsTrackSwitch = targetIndex != updatedNp.currentIndex;
        if (needsTrackSwitch) {
          await _setTrackAt(targetIndex, preload: true);
        }
        
        // Wait for track to be fully loaded and ready
        int retries = 0;
        while (retries < 20) {
          await Future.delayed(const Duration(milliseconds: 50));
          final currentDuration = player.duration;
          final currentPosition = player.position;
          // Track is ready when we have a duration and can get position
          if (currentDuration != null && currentDuration > Duration.zero) {
            // Additional check: ensure player is ready
            if (currentPosition != null) {
              break;
            }
          }
          retries++;
        }
        
        // Get actual track duration from player (may differ from track metadata)
        final actualTrackDuration = player.duration;
        final maxOffsetMs = actualTrackDuration != null 
            ? actualTrackDuration.inMilliseconds 
            : (updatedNp.tracks[targetIndex].duration > 0 
                ? (updatedNp.tracks[targetIndex].duration * 1000).round() 
                : targetOffsetMs);
        
        // Clamp offset to valid range
        final clampedOffsetMs = targetOffsetMs.clamp(0, maxOffsetMs);
        final clampedOffset = Duration(milliseconds: clampedOffsetMs);
        
        // CRITICAL: Seek to the exact position
        await player.seek(clampedOffset);
        
        // Verify position was set correctly
        await Future.delayed(const Duration(milliseconds: 150));
        final actualPos = player.position;
        final posDiff = (actualPos.inMilliseconds - clampedOffsetMs).abs();
        if (posDiff > 1000) {
          // Position is significantly off, try seeking again with a longer wait
          await Future.delayed(const Duration(milliseconds: 200));
          await player.seek(clampedOffset);
        }
      } else {
        // Fallback: use seekGlobal
        await seekGlobal(Duration(milliseconds: (globalPosSec * 1000).round()), reportNow: false);
      }
    } else {
      // Fallback: if global position not available, use current track position
      final updatedNp = _nowPlaying;
      if (updatedNp != null && curIndex < updatedNp.tracks.length) {
        if (curIndex != updatedNp.currentIndex) {
          await _setTrackAt(curIndex, preload: true);
          await Future.delayed(const Duration(milliseconds: 100));
        }
        if (curTrackPos > Duration.zero) {
          await player.seek(curTrackPos);
        }
      }
    }
    if (wasPlaying) {
      await player.play();
      
      // Apply saved playback speed
      try {
        await PlaybackSpeedService.instance.applyCurrentSpeed();
      } catch (e) {
        _log('Failed to apply current playback speed: $e');
      }
    }

    // Close any active streaming session to stop server-side work
    await _closeActiveSession();
    await _sendProgressImmediate();
    return true;
  }

  // ---- Progress sync ----

  Timer? _progressTimer;
  double _lastSentSec = -1;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<Duration>? _positionSub;
  DateTime? _lastPositionUpdate;
  DateTime? _lastDynamicIslandUpdate;
  static const _positionUpdateThrottle = Duration(milliseconds: 500);
  static const _dynamicIslandUpdateThrottle = Duration(seconds: 2);

  void _startProgressSync(String libraryItemId, {String? episodeId}) {
    _progressTimer?.cancel();
    _playingSub?.cancel();
    _positionSub?.cancel();

    // Start/stop heartbeat based on actual playing state
    _playingSub = player.playingStream.listen((isPlaying) async {
      if (isPlaying) {
        // Start periodic ping if not already running
        _progressTimer ??= Timer.periodic(_kProgressPing, (_) async {
          await _sendProgressImmediate();
        });
      } else {
        // Stop periodic ping when paused/stopped
        _progressTimer?.cancel();
        _progressTimer = null;
      }
    });

    // Throttle position stream updates to reduce battery drain
    _positionSub = player.positionStream.listen((pos) {
      final now = DateTime.now();
      
      // Throttle position updates (max once per 500ms)
      if (_lastPositionUpdate != null && 
          now.difference(_lastPositionUpdate!) < _positionUpdateThrottle) {
        return; // Skip if updated too recently
      }
      _lastPositionUpdate = now;
      
      final cur = _computeGlobalPositionSec() ?? _trackOnlyPosSec();
      final total = _computeTotalDurationSec();
      if (cur == null) return;

      final bigJump = (_lastSentSec - cur).abs() >= 30;
      final isDone = (total != null && total > 0) ? (cur / total) >= 0.999 : false;
      if (bigJump || isDone) {
        _sendProgressImmediate(finished: isDone);
      }
      
      // Update Dynamic Island with current position (throttled)
      _updateDynamicIsland();
    });
  }

  void _stopProgressSync() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _playingSub?.cancel();
    _playingSub = null;
    _positionSub?.cancel();
    _positionSub = null;
  }
  
  /// Update Dynamic Island with current playback state (throttled to save battery)
  void _updateDynamicIsland() {
    final np = _nowPlaying;
    if (np == null) return;
    
    // Throttle Dynamic Island updates (max once per 2 seconds)
    final now = DateTime.now();
    if (_lastDynamicIslandUpdate != null && 
        now.difference(_lastDynamicIslandUpdate!) < _dynamicIslandUpdateThrottle) {
      return; // Skip if updated less than 2 seconds ago
    }
    _lastDynamicIslandUpdate = now;
    
    final position = Duration(milliseconds: (_computeGlobalPositionSec() ?? 0.0).round() * 1000);
    final duration = Duration(milliseconds: (_computeTotalDurationSec() ?? 0.0).round() * 1000);
    final isPlaying = player.playing;
    
    // Update Dynamic Island asynchronously
    AudioServiceManager.instance.updateDynamicIsland(
      isPlaying: isPlaying,
      position: position,
      duration: duration,
    );
  }

  /// Always try to send at least `currentTime`. Include `duration/progress`
  /// only when we know the total.
  Future<void> _sendProgressImmediate({
    double? overrideTrackPosSec,
    bool finished = false,
    bool paused = false,
  }) async {
    final itemId = _progressItemId;
    final np = _nowPlaying;
    if (itemId == null || np == null) return;

    final total = _computeTotalDurationSec();
    final cur = (overrideTrackPosSec != null)
        ? _computeGlobalFromTrackPos(overrideTrackPosSec)
        : (_computeGlobalPositionSec() ?? _trackOnlyPosSec());

    if (cur == null) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('$_kLocalProgPrefix$itemId', cur);
    } catch (_) {}

    _lastSentSec = cur;

    // Prefer syncing an active streaming session when available
    _markSyncAttempt();
    final synced = await _syncSession(cur: cur, total: total, finished: finished, paused: paused);
    if (synced) {
      _markSyncSuccess();
      return;
    }

    // Fallback: legacy progress update endpoint
    final api = _auth.api;
    final path = (np.episodeId == null)
        ? '/api/me/progress/$itemId'
        : '/api/me/progress/$itemId/${np.episodeId}';

    final bodyMap = <String, dynamic>{
      'currentTime': cur,
      'isFinished': finished,
    };
    if (total != null && total > 0) {
      bodyMap['duration'] = total;
      bodyMap['progress'] = (cur / total).clamp(0.0, 1.0);
    }

    http.Response? resp;
    _log("Sending progress via PATCH fallback: cur=$cur, total=$total, finished=$finished");

    try {
      resp = await api.request('PATCH', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("PATCH ${resp.statusCode} ${resp.body}");
      if (resp.statusCode == 200 || resp.statusCode == 204) {
        _markSyncSuccess();
        return;
      }
    } catch (e) {
      _log("PATCH error: $e");
    }

    // Fallbacks
    try {
      resp = await api.request('PUT', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("PUT ${resp.statusCode} ${resp.body}");
      if (resp.statusCode == 200 || resp.statusCode == 204) {
        _markSyncSuccess();
        return;
      }
    } catch (e) {
      _log("PUT error: $e");
    }

    try {
      resp = await api.request('POST', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("POST ${resp.statusCode} ${resp.body}");
      if (resp.statusCode == 200 || resp.statusCode == 204) {
        _markSyncSuccess();
        return;
      }
    } catch (e) {
      _log("POST error: $e");
    }

    final code = resp?.statusCode;
    _markSyncFailure(code != null ? 'HTTP $code' : 'No response');
  }

  Future<void> _patchProgressCompletion({
    required String libraryItemId,
    required bool finished,
    double? currentSeconds,
    double? totalSeconds,
  }) async {
    final api = _auth.api;
    final path = '/api/me/progress/$libraryItemId';
    final bodyMap = <String, dynamic>{
      'isFinished': finished,
      if (currentSeconds != null) 'currentTime': currentSeconds,
    };
    if (currentSeconds != null && totalSeconds != null && totalSeconds > 0) {
      bodyMap['duration'] = totalSeconds;
      bodyMap['progress'] = (currentSeconds / totalSeconds).clamp(0.0, 1.0);
    }

    await api.request(
      'PATCH',
      path,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(bodyMap),
    );
  }

  // ---- Internals ----

  /// Check if Bluetooth auto-play is enabled
  Future<bool> _isBluetoothAutoPlayEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('bluetooth_auto_play') ?? true;
    } catch (_) {
      return true; // Default to true if error
    }
  }

  /// Configure audio session based on user preferences
  Future<void> _configureAudioSession(AudioSession session) async {
    // Always use the standard music configuration
    // The bluetooth_auto_play setting is handled at the application level,
    // not at the audio session level, to allow manual play while blocking automatic play
    await session.configure(const AudioSessionConfiguration.music());
  }

  /// Reconfigure audio session when settings change
  Future<void> reconfigureAudioSession() async {
    try {
      final session = await AudioSession.instance;
      await _configureAudioSession(session);
      _log('Audio session reconfigured for Bluetooth auto-play setting');
    } catch (e) {
      _log('Failed to reconfigure audio session: $e');
    }
  }

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await _configureAudioSession(session);
    WidgetsBinding.instance.addObserver(_lifecycleHook);
    
    // Initialize playback speed service early
    await PlaybackSpeedService.instance.initialize(this);
    
    // Apply the loaded speed to the player immediately
    try {
      await PlaybackSpeedService.instance.applyCurrentSpeed();
    } catch (e) {
      _log('Failed to apply initial playback speed: $e');
    }

    // Pause when headphones unplug or audio becomes noisy
    // and respect interruption events (e.g., phone calls)
    session.becomingNoisyEventStream.listen((_) async {
      await pause();
    });

    session.interruptionEventStream.listen((event) async {
      // Feature: navigation-aware auto pause/rewind when ducked
      if (event.begin) {
        // For transient ducks (e.g., navigation prompts), briefly rewind before pausing
        if (event.type == AudioInterruptionType.duck) {
          try { await nudgeSeconds(-3); } catch (_) {}
        }
        await pause();
      }
      // Do not auto-resume by default; we could add a user pref later
    });
  }

  Future<void> _setTrackAt(int index, {bool preload = false}) async {
    final cur = _nowPlaying!;
    final track = cur.tracks[index];

    Duration? loadedDuration;
    if (track.isLocal) {
      loadedDuration = await player.setFilePath(track.url, preload: preload);
    } else {
      // Use Authorization header with Bearer token for secure session URLs
      final headers = <String, String>{};
      try {
        final access = await _auth.api.accessToken();
        if (access != null && access.isNotEmpty) {
          headers['Authorization'] = 'Bearer $access';
        }
      } catch (_) {}
      final uri = Uri.parse(track.url);
      AudioSource source;
      try {
        source = await StreamingCacheService.instance.createCachingSource(
          uri: uri,
          libraryItemId: cur.libraryItemId,
          trackIndex: track.index,
          headers: headers.isEmpty ? null : headers,
        );
      } catch (_) {
        source = AudioSource.uri(uri, headers: headers);
      }
      loadedDuration = await player.setAudioSource(
        source,
        preload: preload,
      );
      unawaited(StreamingCacheService.instance.trimToLimit());
    }
    // If we obtained the track's duration upon loading, update the nowPlaying track list
    List<PlaybackTrack>? maybeUpdatedTracks;
    try {
      final d = loadedDuration ?? player.duration;
      if (d != null) {
        final list = List<PlaybackTrack>.from(cur.tracks);
        if (index >= 0 && index < list.length) {
          list[index] = list[index].copyWith(duration: d.inMilliseconds / 1000.0);
          maybeUpdatedTracks = list;
        }
      }
    } catch (_) {}

    final updatedNowPlaying = cur.copyWith(
      currentIndex: index,
      tracks: maybeUpdatedTracks,
    );
    _setNowPlaying(updatedNowPlaying);
    
    // Notify audio service about track change
    _notifyAudioServiceTrackChange(index);
    
    // Update chapter navigation service
    ChapterNavigationService.instance.initialize(this);
    
    // Update sleep timer service
    SleepTimerService.instance.initialize(this);

    // If we know the duration after loading, update the queue/media item so
    // system UIs (notification/lockscreen) can show a determinate progress bar.
    try {
      final d = loadedDuration ?? player.duration;
      if (d != null) {
        // Update only the current index in the audio service queue
        final handler = AudioServiceBinding.instance.audioHandler;
        if (handler != null) {
          final q = handler.queue.value;
          if (index >= 0 && index < q.length) {
            final old = q[index];
            final updated = old.copyWith(duration: d);
            final newQ = List<MediaItem>.from(q);
            newQ[index] = updated;
            handler.queue.add(newQ);
            // Also update the current mediaItem
            handler.mediaItem.add(updated);
          }
        }
      }
    } catch (_) {}
  }

  void _notifyAudioServiceTrackChange(int trackIndex) {
    // Notify audio service about track change
    AudioServiceBinding.instance.updateCurrentTrack(trackIndex);
  }

  Future<List<PlaybackTrack>> _getTracksPreferLocal(String libraryItemId,
      {String? episodeId}) async {
    final local = await _localTracks(libraryItemId);
    if (local.isNotEmpty) return local;
    return _streamTracks(libraryItemId, episodeId: episodeId);
  }

  Future<List<PlaybackTrack>> _ensureDurations(
      List<PlaybackTrack> tracks, String libraryItemId,
      {String? episodeId}) async {
    final missing = tracks.any((t) => t.duration <= 0);
    if (!missing) return tracks;

    // Don't open a session just to get durations - this causes unnecessary server load
    // If durations are missing, we'll use 0 and they'll be resolved when actually playing
    // or we can get them from book metadata if available
    _log('Local tracks missing durations, but skipping session open to avoid unnecessary server load');
    return tracks;
  }

  Future<List<PlaybackTrack>> _streamTracks(String libraryItemId,
      {String? episodeId}) async {
    final api = _auth.api;
    final token = await api.accessToken();
    final baseStr = api.baseUrl ?? '';
    final base = Uri.parse(baseStr);

    final path = episodeId == null
        ? '/api/items/$libraryItemId/play'
        : '/api/items/$libraryItemId/play/$episodeId';

    final resp = await api.request('POST', path,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceInfo': {'clientVersion': 'kitzi-android-0.1.0'},
          // Include opus/ogg to match Audiobookshelf defaults and avoid server-side rejection
          'supportedMimeTypes': [
            'audio/mpeg',
            'audio/mp4',
            'audio/aac',
            'audio/flac',
            'audio/ogg',
            'audio/opus',
            'audio/webm'
          ]
        }));

    if (resp.statusCode != 200) {
      throw Exception('Failed to get tracks: ${resp.statusCode}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final tracks = (data['audioTracks'] as List?) ?? const [];
    return tracks.map((t) {
      final m = (t as Map).cast<String, dynamic>();
      final idx = (m['index'] as num?)?.toInt() ?? 0;
      final dur = (m['duration'] as num?)?.toDouble() ?? 0.0; // seconds
      final mime = (m['mimeType'] ?? 'audio/mpeg').toString();
      final contentUrl = (m['contentUrl'] ?? '').toString();

      Uri abs = Uri.tryParse(contentUrl) ?? Uri(path: contentUrl);
      if (!abs.hasScheme) {
        final rel = contentUrl.startsWith('/') ? contentUrl.substring(1) : contentUrl;
        abs = base.resolve(rel);
      }

      return PlaybackTrack(
        index: idx,
        url: abs.toString(),
        mimeType: mime,
        duration: dur,
        isLocal: false,
      );
    }).toList()
      ..sort((a, b) => a.index.compareTo(b.index));
  }

  // Open a streaming session and return tracks + session id
  Future<StreamTracksResult> _openSessionAndGetTracks(String libraryItemId, {String? episodeId}) async {
    final api = _auth.api;
    final token = await api.accessToken();
    final baseStr = api.baseUrl ?? '';
    final base = Uri.parse(baseStr);

    final path = episodeId == null
        ? '/api/items/$libraryItemId/play'
        : '/api/items/$libraryItemId/play/$episodeId';

    final resp = await api.request('POST', path,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'deviceInfo': {'clientVersion': 'kitzi-android-0.1.0'},
          // Include opus/ogg to match Audiobookshelf defaults and avoid server-side rejection
          'supportedMimeTypes': [
            'audio/mpeg',
            'audio/mp4',
            'audio/aac',
            'audio/flac',
            'audio/ogg',
            'audio/opus',
            'audio/webm'
          ]
        }));

    if (resp.statusCode != 200) {
      throw Exception('Failed to open session: ${resp.statusCode}');
    }

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final sessionId = (data['sessionId'] ?? data['id'] ?? data['_id'])?.toString();
    final tracks = (data['audioTracks'] as List?) ?? const [];
    final list = tracks.map((t) {
      final m = (t as Map).cast<String, dynamic>();
      final idx = (m['index'] as num?)?.toInt() ?? 0;
      final dur = (m['duration'] as num?)?.toDouble() ?? 0.0; // seconds
      final mime = (m['mimeType'] ?? 'audio/mpeg').toString();
      final contentUrl = (m['contentUrl'] ?? '').toString();

      Uri abs = Uri.tryParse(contentUrl) ?? Uri(path: contentUrl);
      if (!abs.hasScheme) {
        final rel = contentUrl.startsWith('/') ? contentUrl.substring(1) : contentUrl;
        abs = Uri.parse(baseStr).resolve(rel);
      }

      return PlaybackTrack(
        index: idx,
        url: abs.toString(),
        mimeType: mime,
        duration: dur,
        isLocal: false,
      );
    }).toList()
      ..sort((a, b) => a.index.compareTo(b.index));

    return StreamTracksResult(tracks: list, sessionId: sessionId);
  }

  Future<bool> _syncSession({required double cur, double? total, required bool finished, required bool paused}) async {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return false;
    try {
      final api = _auth.api;
      final payload = <String, dynamic>{
        'currentTime': cur,
        'position': (cur * 1000).round(),
        'isPaused': paused,
        'isFinished': finished,
      };
      if (total != null && total > 0) {
        payload['duration'] = total;
        payload['progress'] = (cur / total).clamp(0.0, 1.0);
      }

      // Try a few likely endpoints; ignore failures and fall back to legacy progress
      final candidates = <List<String>>[
        ['POST', '/api/me/sessions/$sessionId/sync'],
        ['PATCH', '/api/me/sessions/$sessionId'],
        ['POST', '/api/sessions/$sessionId/sync'],
        ['PATCH', '/api/sessions/$sessionId'],
      ];
      for (final c in candidates) {
        try {
          final r = await api.request(c[0], c[1],
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(payload));
          if (r.statusCode == 200 || r.statusCode == 204) {
            _log('Session sync OK via ${c[0]} ${c[1]}');
            return true;
          }
        } catch (_) {}
      }
    } catch (e) {
      _log('Session sync error: $e');
    }
    return false;
  }

  Future<void> _closeActiveSession() async {
    final sessionId = _activeSessionId;
    if (sessionId == null || sessionId.isEmpty) return;
    _activeSessionId = null; // Prevent duplicate closes
    try {
      final api = _auth.api;
      final candidates = <List<String>>[
        ['DELETE', '/api/me/sessions/$sessionId'],
        ['POST', '/api/me/sessions/$sessionId/close'],
        ['POST', '/api/sessions/$sessionId/close'],
      ];
      for (final c in candidates) {
        try {
          final r = await api.request(c[0], c[1], headers: {'Content-Type': 'application/json'});
          if (r.statusCode == 200 || r.statusCode == 204 || r.statusCode == 404) {
            _log('Closed session via ${c[0]} ${c[1]} (status ${r.statusCode})');
            break;
          }
        } catch (_) {}
      }
    } catch (e) {
      _log('Session close error: $e');
    }
  }

  /// Close a specific session by id (used by background downloads which manage their own sessions).
  Future<void> closeSessionById(String sessionId) async {
    if (sessionId.isEmpty) return;
    try {
      final api = _auth.api;
      final candidates = <List<String>>[
        ['DELETE', '/api/me/sessions/$sessionId'],
        ['POST', '/api/me/sessions/$sessionId/close'],
        ['POST', '/api/sessions/$sessionId/close'],
      ];
      for (final c in candidates) {
        try {
          final r = await api.request(c[0], c[1], headers: {'Content-Type': 'application/json'});
          if (r.statusCode == 200 || r.statusCode == 204 || r.statusCode == 404) {
            break;
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  Future<List<PlaybackTrack>> _localTracks(String libraryItemId) async {
    try {
      final dir = await DownloadStorage.itemDir(libraryItemId);
      if (!await dir.exists()) return const [];
      final files = (await dir.list().toList()).whereType<File>().toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      if (files.isEmpty) return const [];
      final list = <PlaybackTrack>[];
      for (var i = 0; i < files.length; i++) {
        final f = files[i];
        final ext = f.path.split('.').last.toLowerCase();
        final mime = ext == 'mp3'
            ? 'audio/mpeg'
            : (ext == 'm4a' || ext == 'aac' || ext == 'm4b')
                ? 'audio/mp4'
                : ext == 'flac'
                    ? 'audio/flac'
                    : (ext == 'ogg' || ext == 'oga')
                        ? 'audio/ogg'
                        : ext == 'opus'
                            ? 'audio/opus'
                            : 'audio/mpeg';
        list.add(PlaybackTrack(
          index: i,
          url: f.path,
          mimeType: mime,
          duration: 0.0, // unknown until merged
          isLocal: true,
        ));
      }
      return list;
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _getItemMeta(String libraryItemId) async {
    final baseStr = _auth.api.baseUrl ?? '';
    final base = Uri.parse(baseStr);
    final token = await _auth.api.accessToken();

    Uri meta = base.resolve('api/items/$libraryItemId');
    if (token != null && token.isNotEmpty) {
      meta = meta.replace(queryParameters: {
        ...meta.queryParameters,
        'token': token,
      });
    }

    final r = await http.get(meta);
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (j['item'] as Map?)?.cast<String, dynamic>() ?? j.cast<String, dynamic>();
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  Future<String?> _coverUrl(String libraryItemId) async {
    final baseStr = _auth.api.baseUrl ?? '';
    final base = Uri.parse(baseStr);
    final token = await _auth.api.accessToken();

    Uri cov = base.resolve('api/items/$libraryItemId/cover');
    if (token != null && token.isNotEmpty) {
      cov = cov.replace(queryParameters: {
        ...cov.queryParameters,
        'token': token,
      });
    }
    return cov.toString();
  }

  void _setNowPlaying(NowPlaying? np) {
    _nowPlaying = np;
    _nowPlayingCtr.add(np);
    
    // Start Dynamic Island Live Activity when new content starts playing
    if (np != null && DynamicIslandService.instance.isSupported) {
      _updateDynamicIsland();
    }
  }

  // ----- Mapping / helpers -----

  double? _computeTotalDurationSec() {
    final tracks = _nowPlaying?.tracks ?? const <PlaybackTrack>[];
    double sum = 0.0;
    for (final t in tracks) {
      if (t.duration <= 0) {
        return null;
      }
      sum += t.duration;
    }
    return sum > 0 ? sum : null;
  }

  // track-only pos in seconds (fallback when global mapping impossible)
  double? _trackOnlyPosSec() => player.position.inMilliseconds / 1000.0;

  double? _computeGlobalPositionSec() {
    final np = _nowPlaying;
    if (np == null) return null;
    final idx = np.currentIndex;
    final pos = player.position.inMilliseconds / 1000.0;
    double prefix = 0.0;
    for (int i = 0; i < idx; i++) {
      final d = np.tracks[i].duration;
      if (d <= 0) return null;
      prefix += d;
    }
    return prefix + pos;
  }

  double _computeGlobalFromTrackPos(double trackPosSec) {
    final np = _nowPlaying!;
    final idx = np.currentIndex;
    double prefix = 0.0;
    for (int i = 0; i < idx; i++) {
      prefix += (np.tracks[i].duration > 0 ? np.tracks[i].duration : 0.0);
    }
    return prefix + trackPosSec;
  }

  _TrackMap _mapGlobalSecondsToTrack(double sec, List<PlaybackTrack> tracks) {
    double remain = sec;
    for (int i = 0; i < tracks.length; i++) {
      final d = tracks[i].duration;
      if (d <= 0) {
        return _TrackMap(index: i, offsetSec: remain);
      }
      if (remain < d) {
        return _TrackMap(index: i, offsetSec: remain);
      }
      remain -= d;
    }
    final last = tracks.isNotEmpty ? tracks.length - 1 : 0;
    return _TrackMap(index: last, offsetSec: tracks.isNotEmpty ? tracks[last].duration : 0.0);
  }

  String? _titleFromMeta(Map<String, dynamic> meta) {
    return (meta['title'] as String?) ??
        (meta['media']?['metadata']?['title'] as String?) ??
        (meta['book']?['title'] as String?);
  }

  String? _authorFromMeta(Map<String, dynamic> meta) {
    String? pick(String? s) => (s != null && s.trim().isNotEmpty) ? s : null;

    // Prefer simple string fields across common locations
    final simple = pick(meta['author'] as String?) ??
        pick(meta['authorName'] as String?) ??
        pick(meta['media']?['metadata']?['author'] as String?) ??
        pick(meta['media']?['metadata']?['authorName'] as String?) ??
        pick(meta['book']?['author'] as String?) ??
        pick(meta['book']?['authorName'] as String?);
    if (simple != null) return simple;

    // Fallback to authors list across possible locations
    List<dynamic>? list = (meta['authors'] as List?) ??
        (meta['media']?['metadata']?['authors'] as List?) ??
        (meta['book']?['authors'] as List?);
    if (list != null && list.isNotEmpty) {
      final names = <String>[];
      for (final it in list) {
        if (it is Map && it['name'] is String) {
          final n = (it['name'] as String).trim();
          if (n.isNotEmpty) names.add(n);
        } else if (it is String) {
          final n = it.trim();
          if (n.isNotEmpty) names.add(n);
        }
      }
      if (names.isNotEmpty) return names.join(', ');
    }
    return null;
  }

  String? _narratorFromMeta(Map<String, dynamic> meta) {
    final narrList = meta['narrators'] ?? meta['media']?['metadata']?['narrators'];
    if (narrList is List) {
      final names = <String>[];
      for (final it in narrList) {
        if (it is Map && it['name'] is String) names.add(it['name'] as String);
        if (it is String) names.add(it);
      }
      if (names.isNotEmpty) return names.join(', ');
    }
    final single = meta['narrator'] ?? meta['media']?['metadata']?['narrator'];
    if (single is String && single.trim().isNotEmpty) return single;
    return null;
  }

  List<Chapter> _extractChapters(Map<String, dynamic> meta) {
    final chapters = <Chapter>[];
    // Try common locations used by Audiobookshelf and derivatives
    final toc = meta['chapters'] ??
        meta['tableOfContents'] ??
        meta['media']?['metadata']?['chapters'] ??
        meta['media']?['chapters'] ??
        meta['book']?['chapters'];

    void parseList(List list, {String? sourceName}) {
      for (final c in list) {
        if (c is Map) {
          final map = c.cast<String, dynamic>();
          final title = (map['title'] ?? map['name'] ?? map['chapter'] ?? '').toString();
          final startMs = (map['start'] is num)
              ? (map['start'] as num).toDouble() * 1000
              : (map['startMs'] is num)
                  ? (map['startMs'] as num).toDouble()
                  : (map['time'] is num)
                      ? (map['time'] as num).toDouble() * 1000
                      : null;
          if (startMs != null) {
            chapters.add(Chapter(
              title: title,
              start: Duration(milliseconds: startMs.round()),
            ));
          }
        }
      }
    }

    if (toc is List) {
      parseList(toc, sourceName: 'root');
    }

    // Sort by start just in case
    chapters.sort((a, b) => a.start.compareTo(b.start));
    return chapters;
  }

  List<Chapter> _chaptersFromTracks(List<PlaybackTrack> tracks) {
    final chapters = <Chapter>[];
    double cursorSec = 0.0;
    for (final t in tracks) {
      // Prefer to use filename (without extension) when local files are used,
      // otherwise fall back to generic Track N.
      String title = 'Track ${t.index + 1}';
      if (t.isLocal) {
        try {
          final parts = t.url.split(Platform.pathSeparator);
          final base = parts.isNotEmpty ? parts.last : t.url;
          final withoutExt = base.contains('.') ? base.substring(0, base.lastIndexOf('.')) : base;
          if (withoutExt.trim().isNotEmpty) {
            title = withoutExt.trim();
          }
        } catch (_) {}
      }
      chapters.add(Chapter(
        title: title,
        start: Duration(milliseconds: (cursorSec * 1000).round()),
      ));
      cursorSec += t.duration > 0 ? t.duration : 0.0;
    }
    return chapters;
  }

  /// Cache chapter metadata locally for offline use
  Future<void> _cacheChapterMetadata(String libraryItemId, List<Chapter> chapters) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final chapterData = chapters.map((c) => {
        'title': c.title,
        'startMs': c.start.inMilliseconds,
      }).toList();
      await prefs.setString('chapters_$libraryItemId', jsonEncode(chapterData));
      _log('Cached ${chapters.length} chapters for $libraryItemId');
    } catch (e) {
      _log('Failed to cache chapter metadata: $e');
    }
  }

  /// Load cached chapter metadata
  Future<List<Chapter>> _loadCachedChapterMetadata(String libraryItemId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedData = prefs.getString('chapters_$libraryItemId');
      if (cachedData == null || cachedData.isEmpty) return [];
      
      final List<dynamic> chapterList = jsonDecode(cachedData);
      final chapters = chapterList.map((data) {
        final map = data as Map<String, dynamic>;
        return Chapter(
          title: map['title'] as String? ?? '',
          start: Duration(milliseconds: (map['startMs'] as num?)?.toInt() ?? 0),
        );
      }).toList();
      
      _log('Loaded ${chapters.length} cached chapters for $libraryItemId');
      return chapters;
    } catch (e) {
      _log('Failed to load cached chapter metadata: $e');
      return [];
    }
  }

  /// Refresh chapter metadata for the currently playing item
  Future<void> refreshChapterMetadata() async {
    final np = _nowPlaying;
    if (np == null) return;
    
    try {
      _log('Refreshing chapter metadata for ${np.libraryItemId}');
      final meta = await _getItemMeta(np.libraryItemId);
      final serverChapters = _extractChapters(meta);
      
      if (serverChapters.isNotEmpty) {
        // Update the current NowPlaying with fresh chapter data
        final updatedNp = NowPlaying(
          libraryItemId: np.libraryItemId,
          title: np.title,
          author: np.author,
          narrator: np.narrator,
          coverUrl: np.coverUrl,
          tracks: np.tracks,
          currentIndex: np.currentIndex,
          chapters: serverChapters,
          episodeId: np.episodeId,
        );
        _setNowPlaying(updatedNp);
        
        // Cache the fresh chapters
        await _cacheChapterMetadata(np.libraryItemId, serverChapters);
        _log('Refreshed chapter metadata: ${serverChapters.length} chapters');
      }
    } catch (e) {
      _log('Failed to refresh chapter metadata: $e');
    }
  }

  Map<String, dynamic>? _firstMapValue(Map<String, dynamic> m) {
    for (final v in m.values) {
      if (v is Map) {
        try {
          return v.cast<String, dynamic>();
        } catch (_) {}
      }
    }
    return null;
  }
  
  /// Helper method to get book information for play history
  Future<Book?> _getBookForHistory(String libraryItemId) async {
    try {
      final meta = await _getItemMeta(libraryItemId);
      
      final coverUrl = await _coverUrl(libraryItemId);
      if (coverUrl == null) return null; // Skip if no cover available
      
      return Book(
        id: libraryItemId,
        title: _titleFromMeta(meta) ?? 'Unknown Title',
        author: _authorFromMeta(meta),
        coverUrl: coverUrl,
        description: null,
        durationMs: null,
        sizeBytes: null,
      );
    } catch (e) {
      _log('Failed to get book info for history: $e');
      return null;
    }
  }
}

class _CachedProgressValue {
  const _CachedProgressValue(this.seconds, this.timestamp);
  final double? seconds;
  final DateTime timestamp;
}

class _LifecycleHook extends WidgetsBindingObserver {
  final Future<void> Function() onPauseOrDetach;
  final Future<void> Function()? onResume;
  _LifecycleHook({required this.onPauseOrDetach, this.onResume});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      onPauseOrDetach();
    } else if (state == AppLifecycleState.resumed && onResume != null) {
      onResume!();
    }
  }
}

class _TrackMap {
  final int index;
  final double offsetSec;
  _TrackMap({required this.index, required this.offsetSec});
}

class StreamTracksResult {
  final List<PlaybackTrack> tracks;
  final String? sessionId;
  StreamTracksResult({required this.tracks, required this.sessionId});
}