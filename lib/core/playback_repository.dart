// lib/core/playback_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:audio_service/audio_service.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_repository.dart';
import 'audio_service_binding.dart';
import 'chapter_navigation_service.dart';
import 'sleep_timer_service.dart';
import 'playback_speed_service.dart';
import 'download_storage.dart';
import 'play_history_service.dart';
import '../models/book.dart';
import 'books_repository.dart';

const _kProgressPing = Duration(seconds: 10);
const _kLocalProgPrefix = 'abs_progress:';      // local fallback per item
const _kLastItemKey = 'abs_last_item_id';       // last played item id

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

class NowPlaying {
  final String libraryItemId;
  final String title;
  final String? author;
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
    this.coverUrl,
    this.episodeId,
  });

  NowPlaying copyWith({int? currentIndex, List<PlaybackTrack>? tracks}) =>
      NowPlaying(
        libraryItemId: libraryItemId,
        title: title,
        author: author,
        coverUrl: coverUrl,
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
    debugPrint("[ABS] $msg");
    _debugLogCtr.add(msg);
  }

  PlaybackRepository(this._auth) {
    _init();
  }

  final AuthRepository _auth;
  final AudioPlayer player = AudioPlayer();

  final StreamController<NowPlaying?> _nowPlayingCtr =
  StreamController.broadcast();
  NowPlaying? _nowPlaying;
  Stream<NowPlaying?> get nowPlayingStream => _nowPlayingCtr.stream;
  NowPlaying? get nowPlaying => _nowPlaying;

  Stream<bool> get playingStream => player.playingStream;
  Stream<Duration> get positionStream => player.createPositionStream();
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<ProcessingState> get processingStateStream =>
      player.processingStateStream;

  String? _progressItemId;
  String? _activeSessionId; // Remote streaming session id (if any)

  late final WidgetsBindingObserver _lifecycleHook = _LifecycleHook(
    onPauseOrDetach: () async {
      await _sendProgressImmediate(paused: true);
      await _closeActiveSession();
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

  /// Total number of tracks for an item (remote preferred; fallback to local count).
  Future<int> getTotalTrackCount(String libraryItemId, {String? episodeId}) async {
    try {
      final remote = await _streamTracks(libraryItemId, episodeId: episodeId);
      return remote.length;
    } catch (_) {
      final local = await _localTracks(libraryItemId);
      return local.length;
    }
  }

  /// Warm-load last item (server position wins). If [playAfterLoad] true, will start playback.
  Future<void> warmLoadLastItem({bool playAfterLoad = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getString(_kLastItemKey);
      if (last == null || last.isEmpty) return;

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

        // Do not attempt to ensure durations online; play with what we have
        final chapters = _chaptersFromTracks(localTracks);
        final np = NowPlaying(
          libraryItemId: last,
          title: title,
          author: author,
          coverUrl: coverUrl,
          tracks: localTracks,
          currentIndex: 0,
          chapters: chapters,
        );
        _setNowPlaying(np);
        _progressItemId = last;

        // Resume from cached position (local or server if available)
        double? resumeSec;
        try { resumeSec = await fetchServerProgress(last); } catch (_) {}
        resumeSec ??= prefs.getDouble('$_kLocalProgPrefix$last');

        if (resumeSec != null && resumeSec > 0) {
          final map = _mapGlobalSecondsToTrack(resumeSec, np.tracks);
          await _setTrackAt(map.index, preload: true);
          await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
        } else {
          await _setTrackAt(0, preload: true);
        }

        if (playAfterLoad) {
          await player.play();
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
        coverUrl: await _coverUrl(last),
        tracks: tracksWithDur,
        currentIndex: 0,
        chapters: chapters,
      );
      _setNowPlaying(np);
      _progressItemId = last;

      final resumeSec = await fetchServerProgress(last) ??
          prefs.getDouble('$_kLocalProgPrefix$last');

      if (resumeSec != null && resumeSec > 0) {
        final map = _mapGlobalSecondsToTrack(resumeSec, np.tracks);
        await _setTrackAt(map.index, preload: true);
        await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
      } else {
        await _setTrackAt(0, preload: true);
      }

      await player.play();
      await _sendProgressImmediate();
    } catch (e) {
      _log('warmLoadLastItem error: $e');
    }
  }

  Future<double?> fetchServerProgress(String libraryItemId) async {
    try {
      final api = _auth.api;
      final resp = await api.request('GET', '/api/me/progress/$libraryItemId');
      if (resp.statusCode != 200) return null;
      try {
        final data = jsonDecode(resp.body);
        if (data is Map<String, dynamic>) {
          if (data['currentTime'] is num) return (data['currentTime'] as num).toDouble();
          if (data['currentTime'] is String) return double.tryParse(data['currentTime'] as String);
          final first = _firstMapValue(data);
          if (first != null) {
            final v = first['currentTime'];
            if (v is num) return v.toDouble();
            if (v is String) return double.tryParse(v);
          }
        }
      } catch (_) {}
      return null;
    } on SocketException catch (_) {
      // Offline
      return null;
    }
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
  Future<bool> _checkSyncRequirement() async {
    final shouldSync = await _shouldSyncProgressBeforePlay();
    if (!shouldSync) return true; // Sync not required, proceed
    
    try {
      // Try to make a simple API call to check server availability
      final api = _auth.api;
      await api.request('GET', '/api/me', auth: true);
      return true; // Server is available
    } catch (e) {
      _log('Server unavailable for sync: $e');
      return false; // Server is unavailable
    }
  }

  /// Clear all playback state (called on logout)
  Future<void> clearState() async {
    try {
      // Stop any active playback
      await player.stop();
      
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

  Future<bool> playItem(String libraryItemId, {String? episodeId}) async {
    // Guard: do not attempt playback if item appears to be non-audiobook
    try {
      final repo = await BooksRepository.create();
      final b = await repo.getBookFromDb(libraryItemId) ?? await repo.getBook(libraryItemId);
      if (b != null && b.isAudioBook == false) {
        _log('Blocked play for non-audiobook item $libraryItemId');
        return false;
      }
    } catch (_) {}

    // Check if sync is required and server is available
    final canProceed = await _checkSyncRequirement();
    if (!canProceed) {
      _log('Cannot play: server unavailable and sync progress is required');
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

    // Determine tracks and open a remote session only if we need to stream
    List<PlaybackTrack> tracks;
    String? openedSessionId;
    final localTracks = await _localTracks(libraryItemId);
    if (localTracks.isNotEmpty) {
      tracks = localTracks;
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

    // Update audio service with new now playing info
    _log('Updating audio service with now playing: ${np.title}');
    try {
      await AudioServiceBinding.instance.updateNowPlaying(np);
      _log('✓ Audio service updated successfully');
    } catch (e) {
      _log('❌ Failed to update audio service: $e');
    }

    // SERVER WINS: try server position first; fallback to local cache
    double? resumeSec;
    try {
      resumeSec = await fetchServerProgress(libraryItemId);
    } catch (_) {
      // offline: ignore
    }
    resumeSec ??= prefs.getDouble('$_kLocalProgPrefix$libraryItemId');

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
          await _sendProgressImmediate();
        } else {
          // Completed last track; mark finished and close session to stop transcodes
          await _sendProgressImmediate(finished: true);
          await _closeActiveSession();
        }
      }
    });

    await player.play();
    await _sendProgressImmediate();
    return true;
  }

  /// UPDATED: Send position to server on pause
  Future<void> pause() async {
    // Optionally stop any active sleep timer based on user setting
    try {
      final prefs = await SharedPreferences.getInstance();
      final shouldCancel = prefs.getBool('pause_cancels_sleep_timer') ?? true;
      if (shouldCancel) {
        SleepTimerService.instance.stopTimer();
      }
    } catch (_) {}
    await player.pause();
    await _sendProgressImmediate(paused: true);
    await _closeActiveSession();
  }

  /// UPDATED: Check server position and sync before resuming
  Future<bool> resume() async {
    final itemId = _progressItemId;
    final np = _nowPlaying;
    
    // Check if sync is required and server is available
    final canProceed = await _checkSyncRequirement();
    if (!canProceed) {
      _log('Cannot resume: server unavailable and sync progress is required');
      return false;
    }
    
    if (itemId != null && np != null) {
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
          final map = _mapGlobalSecondsToTrack(curSec, tracks);
          await _setTrackAt(map.index, preload: true);
          await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
        } catch (e) {
          _log('Failed to reopen session on resume: $e');
        }
      }
    }
    await player.play();
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
    if (map.index != np.currentIndex) {
      await _setTrackAt(map.index, preload: true);
    }
    await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
    if (reportNow) {
      await _sendProgressImmediate(overrideTrackPosSec: map.offsetSec);
    }
  }

  Future<void> reportProgressNow() => _sendProgressImmediate();

  Future<void> setSpeed(double speed) => player.setSpeed(speed.clamp(0.5, 3.0));
  bool get hasPrev => _nowPlaying != null && _nowPlaying!.currentIndex > 0;
  bool get hasNext =>
      _nowPlaying != null &&
          _nowPlaying!.currentIndex + 1 < _nowPlaying!.tracks.length;

  Future<void> prevTrack() async {
    if (!hasPrev) return;
    final idx = _nowPlaying!.currentIndex - 1;
    await _setTrackAt(idx, preload: true);
    await player.play();
    await _sendProgressImmediate();
  }

  Future<void> nextTrack() async {
    if (!hasNext) return;
    final idx = _nowPlaying!.currentIndex + 1;
    await _setTrackAt(idx, preload: true);
    await player.play();
    await _sendProgressImmediate();
  }

  Future<void> stop() async {
    // Also stop any active sleep timer
    try { SleepTimerService.instance.stopTimer(); } catch (_) {}
    await player.stop();
    await _sendProgressImmediate(finished: true);
    _stopProgressSync();
    _setNowPlaying(null);
    _progressItemId = null;
    await _closeActiveSession();
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

    final wasPlaying = player.playing;
    final curPos = player.position;
    final curIndex = np.currentIndex;

    // Replace tracks with local without changing metadata/author
    final updated = np.copyWith(tracks: local);
    _setNowPlaying(updated);

    // Load corresponding local track and seek to the same position
    await _setTrackAt(curIndex, preload: true);
    if (curPos > Duration.zero) {
      await player.seek(curPos);
    }
    if (wasPlaying) {
      await player.play();
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

  void _startProgressSync(String libraryItemId, {String? episodeId}) {
    _progressTimer?.cancel();
    _playingSub?.cancel();

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

    player.positionStream.listen((_) {
      final cur = _computeGlobalPositionSec() ?? _trackOnlyPosSec();
      final total = _computeTotalDurationSec();
      if (cur == null) return;

      final bigJump = (_lastSentSec - cur).abs() >= 30;
      final isDone = (total != null && total > 0) ? (cur / total) >= 0.999 : false;
      if (bigJump || isDone) {
        _sendProgressImmediate(finished: isDone);
      }
    });
  }

  void _stopProgressSync() {
    _progressTimer?.cancel();
    _progressTimer = null;
    _playingSub?.cancel();
    _playingSub = null;
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
    final synced = await _syncSession(cur: cur, total: total, finished: finished, paused: paused);
    if (synced) return;

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
      if (resp.statusCode == 200 || resp.statusCode == 204) return;
    } catch (e) {
      _log("PATCH error: $e");
    }

    // Fallbacks
    try {
      resp = await api.request('PUT', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("PUT ${resp.statusCode} ${resp.body}");
      if (resp.statusCode == 200 || resp.statusCode == 204) return;
    } catch (e) {
      _log("PUT error: $e");
    }

    try {
      resp = await api.request('POST', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("POST ${resp.statusCode} ${resp.body}");
    } catch (e) {
      _log("POST error: $e");
    }
  }

  // ---- Internals ----

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    WidgetsBinding.instance.addObserver(_lifecycleHook);

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
      loadedDuration = await player.setAudioSource(
        AudioSource.uri(Uri.parse(track.url), headers: headers),
        preload: preload,
      );
    }
    
    final updatedNowPlaying = cur.copyWith(currentIndex: index);
    _setNowPlaying(updatedNowPlaying);
    
    // Notify audio service about track change
    _notifyAudioServiceTrackChange(index);
    
    // Update chapter navigation service
    ChapterNavigationService.instance.initialize(this);
    
    // Update sleep timer service
    SleepTimerService.instance.initialize(this);
    
    // Update playback speed service
    PlaybackSpeedService.instance.initialize(this);

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

    try {
      final remote = await _streamTracks(libraryItemId, episodeId: episodeId);
      final byIndex = {for (final t in remote) t.index: t.duration};
      return tracks
          .map((t) => t.duration > 0
          ? t
          : t.copyWith(duration: (byIndex[t.index] ?? 0.0)))
          .toList();
    } catch (_) {
      return tracks;
    }
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
          'supportedMimeTypes': ['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/flac']
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
          'supportedMimeTypes': ['audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/flac']
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
            : (ext == 'm4a' || ext == 'aac')
            ? 'audio/mp4'
            : ext == 'flac'
            ? 'audio/flac'
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
    String? _pick(String? s) => (s != null && s.trim().isNotEmpty) ? s : null;

    // Prefer simple string fields across common locations
    final simple = _pick(meta['author'] as String?) ??
        _pick(meta['authorName'] as String?) ??
        _pick(meta['media']?['metadata']?['author'] as String?) ??
        _pick(meta['media']?['metadata']?['authorName'] as String?) ??
        _pick(meta['book']?['author'] as String?) ??
        _pick(meta['book']?['authorName'] as String?);
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

    void _parseList(List list, {String? sourceName}) {
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
      _parseList(toc, sourceName: 'root');
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

class _LifecycleHook extends WidgetsBindingObserver {
  final Future<void> Function() onPauseOrDetach;
  _LifecycleHook({required this.onPauseOrDetach});

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      onPauseOrDetach();
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