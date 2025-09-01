// lib/core/playback_repository.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'auth_repository.dart';

const _kProgressPing = Duration(seconds: 15);
const _kLocalProgPrefix = 'abs_progress:';

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
  PlaybackRepository(this._auth) {
    _init();
  }

  final AuthRepository _auth;
  final AudioPlayer player = AudioPlayer();

  // ---- logging (opt-in UI can subscribe) ----
  final StreamController<String> _debugLogCtr = StreamController.broadcast();
  Stream<String> get debugLogStream => _debugLogCtr.stream;
  void _log(String msg) {
    debugPrint("[ABS] $msg");
    _debugLogCtr.add(msg);
  }

  // Now Playing state
  final StreamController<NowPlaying?> _nowPlayingCtr =
  StreamController.broadcast();
  NowPlaying? _nowPlaying;
  Stream<NowPlaying?> get nowPlayingStream => _nowPlayingCtr.stream;
  NowPlaying? get nowPlaying => _nowPlaying;

  // Exposed streams to wire UI
  Stream<bool> get playingStream => player.playingStream;
  Stream<Duration> get positionStream => player.createPositionStream();
  Stream<Duration?> get durationStream => player.durationStream;
  Stream<PlayerState> get playerStateStream => player.playerStateStream;
  Stream<ProcessingState> get processingStateStream =>
      player.processingStateStream;

  String? _progressItemId; // which item we report progress for
  double? _metaTotalDurationSec; // from item metadata (seconds)
  double? _sumTrackDurationsSec; // sum of tracks (seconds) if known

  // Track duration learned at runtime from ExoPlayer
  final Map<int, double> _observedDurationsSec = {};

  // Debounce/throttle progress signaling
  Timer? _debounceSeekTimer;
  bool _userSeekActive = false;
  DateTime? _lastSentAt;
  static const _minSendGap = Duration(milliseconds: 500);
  static const _seekDebounce = Duration(milliseconds: 700);

  // lifecycle hook to send on background/exit
  late final WidgetsBindingObserver _lifecycleHook = _LifecycleHook(
    onPauseOrDetach: () => _sendProgressImmediate(),
  );

  // ---- Public API ----

  /// Prefer local files when available (used by player UI).
  Future<List<PlaybackTrack>> getPlayableTracks(String libraryItemId,
      {String? episodeId}) =>
      _getTracksPreferLocal(libraryItemId, episodeId: episodeId);

  /// Always fetch REMOTE streaming tracks (needed by downloader).
  Future<List<PlaybackTrack>> getRemoteStreamTracks(String libraryItemId,
      {String? episodeId}) =>
      _streamTracks(libraryItemId, episodeId: episodeId);

  /// Query server for last known position (seconds). Returns null if none.
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

  /// Server-first resume, else local fallback if offline or server has none.
  Future<void> playItem(String libraryItemId, {String? episodeId}) async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());

    // Always pull metadata to get cover/author/chapters + total duration
    final meta = await _getItemMeta(libraryItemId);
    final chapters = _extractChapters(meta);
    _metaTotalDurationSec = _extractMetaDurationSec(meta); // seconds

    // Prefer local, but merge remote durations if local durations are unknown
    var tracks =
    await _getTracksPreferLocal(libraryItemId, episodeId: episodeId);
    tracks =
    await _ensureDurations(tracks, libraryItemId, episodeId: episodeId);
    _sumTrackDurationsSec = _sumDurations(tracks);

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
    _setNowPlaying(np);
    _progressItemId = libraryItemId;

    // Prepare first track (we'll seek after resume source is chosen)
    await _playTrackAt(0);

    // --- RESUME ORDER: SERVER -> LOCAL ---
    double? resumeSec;
    bool serverTried = false;
    try {
      resumeSec = await fetchServerProgress(libraryItemId);
      serverTried = true;
    } catch (e) {
      _log('fetchServerProgress error (will use local if any): $e');
    }

    if ((resumeSec == null || resumeSec <= 0)) {
      // try local per-server key
      final prefs = await SharedPreferences.getInstance();
      final localKey = _progressKey(libraryItemId, episodeId: episodeId);
      final localSec = prefs.getDouble(localKey);
      if (localSec != null && localSec > 0) {
        resumeSec = localSec;
        _log('Using LOCAL resume $resumeSec (serverTried=$serverTried)');
      } else {
        _log('No resume position available (serverTried=$serverTried)');
      }
    } else {
      _log('Using SERVER resume $resumeSec');
    }

    if (resumeSec != null && resumeSec > 0) {
      final map = _mapGlobalSecondsToTrack(resumeSec, tracks);
      await _playTrackAt(map.index);
      await player.seek(Duration(milliseconds: (map.offsetSec * 1000).round()));
    }

    _startProgressSync(libraryItemId, episodeId: episodeId);

    // Auto-next on completion
    player.processingStateStream.listen((state) async {
      if (state == ProcessingState.completed) {
        final cur = _nowPlaying;
        if (cur == null) return;
        final next = cur.currentIndex + 1;
        if (next < cur.tracks.length) {
          await _playTrackAt(next);
          await player.play();
          await _sendProgressImmediate(); // send on track change
        }
      }
    });

    await player.play();
    await _sendProgressImmediate(); // initial ping (global)
  }

  Future<void> pause() async {
    await player.pause();
    await _sendProgressImmediate();
  }

  Future<void> resume() async {
    await player.play();
    await _sendProgressImmediate();
  }

  /// Seek to [pos] but **debounce** the server update (prevents PATCH spam).
  Future<void> seek(Duration pos, {bool reportNow = true}) async {
    await player.seek(pos);
    _debouncedProgress();
  }

  /// Convenience: move by +/- seconds. Also debounced.
  Future<void> nudgeSeconds(int delta) async {
    final total = player.duration ?? Duration.zero;
    var target = player.position + Duration(seconds: delta);
    if (target < Duration.zero) target = Duration.zero;
    if (target > total) target = total;
    await player.seek(target);
    _debouncedProgress();
  }

  /// Manually trigger a progress push (e.g. from UI)
  Future<void> reportProgressNow() => _sendProgressImmediate();

  Future<void> setSpeed(double speed) => player.setSpeed(speed.clamp(0.5, 3.0));
  bool get hasPrev => _nowPlaying != null && _nowPlaying!.currentIndex > 0;
  bool get hasNext =>
      _nowPlaying != null &&
          _nowPlaying!.currentIndex + 1 < _nowPlaying!.tracks.length;

  Future<void> prevTrack() async {
    if (!hasPrev) return;
    final idx = _nowPlaying!.currentIndex - 1;
    await _playTrackAt(idx);
    await player.play();
    await _sendProgressImmediate();
  }

  Future<void> nextTrack() async {
    if (!hasNext) return;
    final idx = _nowPlaying!.currentIndex + 1;
    await _playTrackAt(idx);
    await player.play();
    await _sendProgressImmediate();
  }

  Future<void> stop() async {
    await player.stop();
    await _sendProgressImmediate(finished: true);
    _stopProgressSync();
    _setNowPlaying(null);
    _progressItemId = null;
    _metaTotalDurationSec = null;
    _sumTrackDurationsSec = null;
  }

  // ---- Progress sync ----

  Timer? _progressTimer;
  double _lastSentSec = -1;

  void _startProgressSync(String libraryItemId, {String? episodeId}) {
    _progressTimer?.cancel();

    _progressTimer = Timer.periodic(_kProgressPing, (_) {
      _sendProgressImmediate();
    });

    // Big jumps / finish detection (GLOBAL seconds)
    player.positionStream.listen((_) {
      final cur = _computeGlobalPositionSec() ?? _trackOnlyPosSec();
      final total = _computeTotalDurationSec();
      if (cur == null) return;

      final bigJump = (_lastSentSec - cur).abs() >= 30;
      final isDone =
      (total != null && total > 0) ? (cur / total) >= 0.999 : false;

      // Don't auto-send while user is actively scrubbing
      if (!_userSeekActive && (bigJump || isDone)) {
        _sendProgressImmediate(finished: isDone);
      }
    });
  }

  void _stopProgressSync() {
    _progressTimer?.cancel();
    _progressTimer = null;
  }

  void _debouncedProgress() {
    _userSeekActive = true;
    _debounceSeekTimer?.cancel();
    _debounceSeekTimer = Timer(_seekDebounce, () {
      _userSeekActive = false;
      _sendProgressImmediate();
    });
  }

  /// Always try to send at least `currentTime`. Include `progress`
  /// only when we know the total. Throttled to avoid bursts.
  Future<void> _sendProgressImmediate({
    double? overrideTrackPosSec,
    bool finished = false,
  }) async {
    final itemId = _progressItemId;
    final np = _nowPlaying;
    if (itemId == null || np == null) return;

    // Throttle
    final now = DateTime.now();
    if (_lastSentAt != null &&
        now.difference(_lastSentAt!) < _minSendGap &&
        !finished) {
      return;
    }
    _lastSentAt = now;

    final total = _computeTotalDurationSec();
    final cur = (overrideTrackPosSec != null)
        ? _computeGlobalFromTrackPos(overrideTrackPosSec)
        : (_computeGlobalPositionSec() ?? _trackOnlyPosSec());

    if (cur == null) return;

    // Persist locally with per-server key so switching servers won't mix states
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(
          _progressKey(itemId, episodeId: np.episodeId), cur);
    } catch (_) {}

    _lastSentSec = cur;

    final api = _auth.api;
    final path = (np.episodeId == null)
        ? '/api/me/progress/$itemId'
        : '/api/me/progress/$itemId/${np.episodeId}';

    // Let server-side item duration drive UI; send progress only.
    final bodyMap = <String, dynamic>{
      'currentTime': cur,
      'isFinished':
      finished || (total != null && total > 0 && (cur / total) >= 0.995),
      if (total != null && total > 0)
        'progress': (cur / total).clamp(0.0, 1.0),
    };

    http.Response? resp;
    _log("Sending progress: cur=$cur, total=$total, finished=${bodyMap['isFinished']}");

    try {
      resp = await api.request('PATCH', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("PATCH ${resp.statusCode} ${resp.reasonPhrase}");
      if (resp.statusCode == 200 || resp.statusCode == 204) return;
    } catch (e) {
      _log("PATCH error: $e");
    }

    try {
      resp = await api.request('PUT', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("PUT ${resp.statusCode} ${resp.reasonPhrase}");
      if (resp.statusCode == 200 || resp.statusCode == 204) return;
    } catch (e) {
      _log("PUT error: $e");
    }

    try {
      resp = await api.request('POST', path,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(bodyMap));
      _log("POST ${resp.statusCode} ${resp.reasonPhrase}");
    } catch (e) {
      _log("POST error: $e");
    }
  }

  // ---- Internals ----

  Future<void> _init() async {
    final session = await AudioSession.instance;
    await session.configure(const AudioSessionConfiguration.music());
    WidgetsBinding.instance.addObserver(_lifecycleHook);
  }

  Future<void> _playTrackAt(int index) async {
    final cur = _nowPlaying!;
    final track = cur.tracks[index];

    if (track.isLocal) {
      await player.setFilePath(track.url, preload: true);
    } else {
      await player.setUrl(track.url, preload: true);
    }
    _setNowPlaying(cur.copyWith(currentIndex: index));

    // Learn this track's actual duration from the player
    final sub = player.durationStream.listen((d) {
      final ms = d?.inMilliseconds ?? 0;
      if (ms > 0) {
        final sec = ms / 1000.0;
        _observedDurationsSec[index] = sec;

        // Patch track duration if unknown
        final np = _nowPlaying;
        if (np != null) {
          final patched = [...np.tracks];
          if (patched[index].duration <= 0) {
            patched[index] = patched[index].copyWith(duration: sec);
            _setNowPlaying(np.copyWith(tracks: patched));
          }
        }

        _sumTrackDurationsSec = _sumDurations(_nowPlaying?.tracks ?? const []);
      }
    });

    // Avoid leak
    Future.delayed(const Duration(seconds: 5), () => sub.cancel());
  }

  Future<List<PlaybackTrack>> _getTracksPreferLocal(String libraryItemId,
      {String? episodeId}) async {
    final local = await _localTracks(libraryItemId);
    if (local.isNotEmpty) return local;
    return _streamTracks(libraryItemId, episodeId: episodeId);
  }

  /// If any track durations are unknown (0) for local playback, fetch remote
  /// stream metadata once and merge durations by index.
  Future<List<PlaybackTrack>> _ensureDurations(
      List<PlaybackTrack> tracks, String libraryItemId,
      {String? episodeId}) async {
    final missing = tracks.any((t) => t.duration <= 0);
    if (!missing) return tracks;

    try {
      final remote = await _streamTracks(libraryItemId, episodeId: episodeId);
      final byIndex = {for (final t in remote) t.index: t.duration};
      final patched = tracks
          .map((t) => t.duration > 0
          ? t
          : t.copyWith(duration: (byIndex[t.index] ?? 0.0)))
          .toList();
      return patched;
    } catch (_) {
      return tracks; // keep as-is if remote metadata fails
    }
  }

  Future<List<PlaybackTrack>> _streamTracks(String libraryItemId,
      {String? episodeId}) async {
    final api = _auth.api;
    final token = await _auth.api.accessToken();
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
        final rel =
        contentUrl.startsWith('/') ? contentUrl.substring(1) : contentUrl;
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
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/abs/$libraryItemId');
      if (!await dir.exists()) return const [];
      final files =
      (await dir.list().toList()).whereType<File>().toList()
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
          duration: 0.0, // unknown for local until we merge from stream meta
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
      meta = meta.replace(
        queryParameters: <String, String>{
          ...meta.queryParameters,
          'token': token,
        },
      );
    }

    final r = await http.get(meta);
    try {
      final j = jsonDecode(r.body) as Map<String, dynamic>;
      return (j['item'] as Map?)?.cast<String, dynamic>() ??
          j.cast<String, dynamic>();
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
      cov = cov.replace(
        queryParameters: <String, String>{
          ...cov.queryParameters,
          'token': token,
        },
      );
    }
    return cov.toString();
  }

  void _setNowPlaying(NowPlaying? np) {
    _nowPlaying = np;
    _nowPlayingCtr.add(np);
  }

  // ----- Mapping / helpers -----

  double? _computeTotalDurationSec() {
    // 1) Prefer explicit total from metadata if present
    if (_metaTotalDurationSec != null && _metaTotalDurationSec! > 0) {
      return _metaTotalDurationSec;
    }

    // 2) Sum known/observed per-track durations
    final np = _nowPlaying;
    if (np == null) return null;

    double sum = 0.0;
    bool hasUnknown = false;
    for (var i = 0; i < np.tracks.length; i++) {
      final t = np.tracks[i];
      final observed = _observedDurationsSec[i];
      final d = (t.duration > 0) ? t.duration : (observed ?? 0.0);
      if (d <= 0) {
        hasUnknown = true;
      } else {
        sum += d;
      }
    }

    // 3) Only cache if we have a complete total (no unknowns)
    if (!hasUnknown && sum > 0) {
      _sumTrackDurationsSec = sum;
      return sum;
    }

    // 4) Otherwise, use any previously cached full total
    if (_sumTrackDurationsSec != null && _sumTrackDurationsSec! > 0) {
      return _sumTrackDurationsSec;
    }

    // 5) No reliable total yet
    return null;
  }

  // track-only pos in seconds (fallback when global mapping impossible)
  double? _trackOnlyPosSec() => player.position.inMilliseconds / 1000.0;

  double _sumDurations(List<PlaybackTrack> tracks) {
    var s = 0.0;
    for (final t in tracks) {
      if (t.duration > 0) s += t.duration;
    }
    return s;
  }

  double? _computeGlobalPositionSec() {
    final np = _nowPlaying;
    if (np == null) return null;
    final idx = np.currentIndex;
    final pos = player.position.inMilliseconds / 1000.0;
    // Sum durations of previous tracks; if any unknown, we cannot compute reliably.
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
        // If unknown, assume it's the target track.
        return _TrackMap(index: i, offsetSec: remain);
      }
      if (remain < d) {
        return _TrackMap(index: i, offsetSec: remain);
      }
      remain -= d;
    }
    // If beyond total, clamp to last track end.
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
            chapters.add(Chapter(
                title: title, start: Duration(milliseconds: startMs.round())));
          }
        }
      }
    }
    return chapters;
  }

  double? _extractMetaDurationSec(Map<String, dynamic> meta) {
    num? candidate;
    final d1 = meta['duration'];
    final d2 = meta['media'] is Map ? (meta['media'] as Map)['duration'] : null;
    final d3 = meta['media'] is Map
        ? ((meta['media'] as Map)['metadata'] is Map
        ? ((meta['media'] as Map)['metadata'] as Map)['duration']
        : null)
        : null;
    dynamic pick = d1 ?? d2 ?? d3;
    if (pick is String) {
      candidate = num.tryParse(pick);
    } else if (pick is num) {
      candidate = pick;
    }
    if (candidate == null) return null;
    double sec = candidate.toDouble();
    if (sec > 1e6) sec = sec / 1000.0; // ms->s heuristic
    if (sec <= 0) return null;
    return sec;
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

  String _progressKey(String libraryItemId, {String? episodeId}) {
    final base = _auth.api.baseUrl ?? '';
    final host = Uri.tryParse(base)?.host ?? base;
    final ep = episodeId ?? '';
    // Per-server (+episode-safe) namespacing
    return '$_kLocalProgPrefix$host:$libraryItemId:$ep';
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
