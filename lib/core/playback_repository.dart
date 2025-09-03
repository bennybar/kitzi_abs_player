// lib/core/playback_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
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

  late final WidgetsBindingObserver _lifecycleHook = _LifecycleHook(
    onPauseOrDetach: () => _sendProgressImmediate(),
  );

  Future<List<PlaybackTrack>> getPlayableTracks(String libraryItemId,
      {String? episodeId}) =>
      _getTracksPreferLocal(libraryItemId, episodeId: episodeId);

  /// Always fetch remote/stream tracks (ignores local files) for metadata like total count.
  Future<List<PlaybackTrack>> getRemoteTracks(String libraryItemId, {String? episodeId}) {
    return _streamTracks(libraryItemId, episodeId: episodeId);
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

      final meta = await _getItemMeta(last);
      var chapters = _extractChapters(meta);
      final tracks = await _getTracksPreferLocal(last);
      final tracksWithDur = await _ensureDurations(tracks, last);
      if (chapters.isEmpty && tracksWithDur.isNotEmpty) {
        chapters = _chaptersFromTracks(tracksWithDur);
      }

      final np = NowPlaying(
        libraryItemId: last,
        title: _titleFromMeta(meta) ?? 'Audiobook',
        author: _authorFromMeta(meta),
        coverUrl: await _coverUrl(last),
        tracks: tracksWithDur,
        currentIndex: 0,
        chapters: chapters,
      );
      _setNowPlaying(np);
      _progressItemId = last;

      final resumeSec = await fetchServerProgress(last) ??
          prefs.getDouble('$_kLocalProgPrefix$last');

      // Map to track and seek BEFORE starting
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
    } catch (e) {
      _log('warmLoadLastItem error: $e');
    }
  }

  Future<double?> fetchServerProgress(String libraryItemId) async {
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
  }

  Future<void> playItem(String libraryItemId, {String? episodeId}) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastItemKey, libraryItemId);

    final meta = await _getItemMeta(libraryItemId);
    var chapters = _extractChapters(meta);

    var tracks = await _getTracksPreferLocal(libraryItemId, episodeId: episodeId);
    tracks = await _ensureDurations(tracks, libraryItemId, episodeId: episodeId);
    if (chapters.isEmpty && tracks.isNotEmpty) {
      chapters = _chaptersFromTracks(tracks);
    }

    final np = NowPlaying(
      libraryItemId: libraryItemId,
      title: _titleFromMeta(meta) ?? 'Audiobook',
      author: _authorFromMeta(meta),
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

    // Update audio service with new now playing info
    _log('Updating audio service with now playing: ${np.title}');
    try {
      await AudioServiceBinding.instance.updateNowPlaying(np);
      _log('✓ Audio service updated successfully');
    } catch (e) {
      _log('❌ Failed to update audio service: $e');
    }

    // SERVER WINS: try server position first; fallback to local cache
    double? resumeSec = await fetchServerProgress(libraryItemId);
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
        }
      }
    });

    await player.play();
    await _sendProgressImmediate();
  }

  /// UPDATED: Send position to server on pause
  Future<void> pause() async {
    await player.pause();
    await _sendProgressImmediate();
  }

  /// UPDATED: Check server position and sync before resuming
  Future<void> resume() async {
    final itemId = _progressItemId;
    if (itemId != null) {
      await _syncPositionFromServer();
    }
    await player.play();
    await _sendProgressImmediate();
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
    await player.stop();
    await _sendProgressImmediate(finished: true);
    _stopProgressSync();
    _setNowPlaying(null);
    _progressItemId = null;
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
    _log("Sending progress: cur=$cur, total=$total, finished=$finished");

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
      if (event.begin) {
        // On any interruption start, pause playback
        await pause();
      }
      // We avoid auto-resume to be conservative for user intent/battery
    });
  }

  Future<void> _setTrackAt(int index, {bool preload = false}) async {
    final cur = _nowPlaying!;
    final track = cur.tracks[index];

    if (track.isLocal) {
      await player.setFilePath(track.url, preload: preload);
    } else {
      await player.setUrl(track.url, preload: preload);
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
      if (token != null && token.isNotEmpty) {
        abs = abs.replace(queryParameters: {
          ...abs.queryParameters,
          'token': token,
        });
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
    final a = (meta['author'] as String?) ??
        (meta['media']?['metadata']?['author'] as String?);
    if (a != null) return a;
    final authors = meta['authors'];
    if (authors is List && authors.isNotEmpty) {
      final first = authors.first;
      if (first is Map && first['name'] is String) return first['name'] as String;
      if (first is String) return first;
    }
    return null;
  }

  List<Chapter> _extractChapters(Map<String, dynamic> meta) {
    final chapters = <Chapter>[];
    final toc = meta['chapters'] ?? meta['tableOfContents'];
    if (toc is List) {
      for (final c in toc) {
        if (c is Map) {
          final title = (c['title'] ?? c['name'] ?? '').toString();
          final startMs = (c['start'] is num)
              ? (c['start'] as num).toDouble() * 1000
              : (c['startMs'] as num?)?.toDouble();
          if (startMs != null) {
            chapters.add(Chapter(title: title, start: Duration(milliseconds: startMs.round())));
          }
        }
      }
    }
    return chapters;
  }

  List<Chapter> _chaptersFromTracks(List<PlaybackTrack> tracks) {
    final chapters = <Chapter>[];
    double cursorSec = 0.0;
    for (final t in tracks) {
      chapters.add(Chapter(
        title: 'Track ${t.index + 1}',
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