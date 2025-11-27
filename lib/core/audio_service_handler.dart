import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_repository.dart';
import 'books_repository.dart';
import 'ui_prefs.dart';

class KitziAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final PlaybackRepository _playback;
  final AudioPlayer _player;
  VoidCallback? _progressPrefListener;
  
  KitziAudioHandler(this._playback, this._player) {
    _loadEmptyPlaylist();
    _notifyAudioHandlerAboutPlaybackEvents();
    _listenForDurationChanges();
    _listenForPositionChanges();
    _listenForCurrentSongIndexChanges();
    _listenForSequenceStateChanges();
    _listenForNowPlayingChanges();
  }

  Future<void> _loadEmptyPlaylist() async {
    try {
      final initialItem = MediaItem(
        id: '1',
        album: "Audiobookshelf",
        title: "Loading...",
        artist: "Loading...",
        duration: Duration.zero,
        playable: true,
      );
      queue.add([initialItem]);
      mediaItem.add(initialItem);
    } catch (e) {
      // Error loading empty playlist
    }
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _player.playbackEventStream.listen(_updateStateFromEvent);
    _progressPrefListener = () => _updateStateFromEvent(_player.playbackEvent);
    UiPrefs.progressPrimary.addListener(_progressPrefListener!);
  }

  void _listenForDurationChanges() {
    _player.durationStream.listen((duration) {
      int? index = _player.currentIndex;
      final currentQueue = queue.value;
      // For single-source (local file) playback, currentIndex can be null.
      // Fall back to the known queue index or 0 when we have items.
      index ??= playbackState.value.queueIndex;
      index ??= currentQueue.isNotEmpty ? 0 : null;
      if (index != null && index >= 0 && index < currentQueue.length) {
        final oldMediaItem = currentQueue[index];
        try {
          final newMediaItem = oldMediaItem.copyWith(duration: duration);
          final newQueue = List<MediaItem>.from(currentQueue);
          newQueue[index] = newMediaItem;
          queue.add(newQueue);
          // If this is the currently displayed item, update it too so
          // the system notification/lock screen gets a determinate duration
          final curIdx = playbackState.value.queueIndex ?? index;
          if (curIdx == index) {
            mediaItem.add(newMediaItem);
          }
        } catch (e) {
          // Error updating MediaItem duration
        }
      }
    });
  }

  void _listenForPositionChanges() {
    // Push frequent position/buffer updates so Android notification/lock screen
    // show a moving progress bar between playback events.
    _player.positionStream.listen((pos) {
      final progress = _resolveNotificationProgress();
      playbackState.add(playbackState.value.copyWith(
        updatePosition: progress.position,
        bufferedPosition: progress.buffered,
        speed: _player.speed,
      ));

      // If the current mediaItem has no duration yet but the player knows it
      // (common with local files), update it so system UIs can render progress.
      try {
        final d = progress.duration == Duration.zero ? _player.duration : progress.duration;
        if (d != null && d > Duration.zero) {
          _updateActiveMediaItemDuration(d);
        }
      } catch (_) {}
    });
  }

  void _listenForCurrentSongIndexChanges() {
    _player.currentIndexStream.listen((index) {
      if (index != null && index < queue.value.length) {
        playbackState.add(playbackState.value.copyWith(
          queueIndex: index,
        ));
      }
    });
  }

  void _listenForSequenceStateChanges() {
    _player.sequenceStateStream.listen((SequenceState? sequenceState) {
      if (sequenceState == null) return;
      final effective = sequenceState.effectiveSequence;
      if (effective.isEmpty) return;
      // Only update queue from tags if all tags are valid MediaItems.
      final tags = effective
          .map((source) => source.tag)
          .whereType<MediaItem>()
          .cast<MediaItem>()
          .toList();
      if (tags.isNotEmpty) {
        queue.add(tags);
      }
    });
  }

  void _listenForNowPlayingChanges() {
    _playback.nowPlayingStream.listen((nowPlaying) {
      if (nowPlaying != null) {
        updateQueueFromNowPlaying(nowPlaying);
      }
    });
  }

  void _updateStateFromEvent(PlaybackEvent event) {
    final playing = _player.playing;
    final currentIndex = _player.currentIndex ?? 0;
    final progress = _resolveNotificationProgress();

    playbackState.add(playbackState.value.copyWith(
      controls: [
        MediaControl.skipToPrevious,
        MediaControl.rewind,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.fastForward,
        MediaControl.skipToNext,
        MediaControl.stop,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 2, 4],
      processingState: {
        ProcessingState.idle: AudioProcessingState.idle,
        ProcessingState.loading: AudioProcessingState.loading,
        ProcessingState.buffering: AudioProcessingState.buffering,
        ProcessingState.ready: AudioProcessingState.ready,
        ProcessingState.completed: AudioProcessingState.completed,
      }[_player.processingState]!,
      playing: playing,
      updatePosition: progress.position,
      bufferedPosition: progress.buffered,
      speed: _player.speed,
      queueIndex: currentIndex,
    ));

    _updateActiveMediaItemDuration(progress.duration);
  }

  _NotificationProgress _resolveNotificationProgress() {
    final pref = UiPrefs.progressPrimary.value;
    final globalTotal = _playback.totalBookDuration;
    final globalPos = _playback.globalBookPosition;
    final chapterMetrics = _playback.currentChapterProgress;

    if (pref == ProgressPrimary.book && globalTotal != null && globalPos != null) {
      return _NotificationProgress(
        position: globalPos,
        duration: globalTotal,
        buffered: globalPos,
      );
    }

    if (pref == ProgressPrimary.chapter && chapterMetrics != null) {
      return _NotificationProgress(
        position: chapterMetrics.elapsed,
        duration: chapterMetrics.duration,
        buffered: chapterMetrics.elapsed,
      );
    }

    final trackDuration = _player.duration ?? Duration.zero;
    final trackPosition = _player.position;
    final buffered = _player.bufferedPosition;
    final duration = trackDuration > Duration.zero
        ? trackDuration
        : (trackPosition > Duration.zero ? trackPosition : const Duration(milliseconds: 1));

    return _NotificationProgress(
      position: trackPosition,
      duration: duration,
      buffered: buffered,
    );
  }

  void _updateActiveMediaItemDuration(Duration duration) {
    if (duration <= Duration.zero) return;
    final currentQueue = queue.value;
    int? index = _player.currentIndex ?? playbackState.value.queueIndex;
    index ??= currentQueue.isNotEmpty ? 0 : null;
    if (index == null || index < 0 || index >= currentQueue.length) return;
    final currentItem = currentQueue[index];
    if (currentItem.duration != null &&
        currentItem.duration!.inMilliseconds == duration.inMilliseconds) {
      mediaItem.add(currentItem);
      return;
    }
    final updatedItem = currentItem.copyWith(duration: duration);
    final newQueue = List<MediaItem>.from(currentQueue);
    newQueue[index] = updatedItem;
    queue.add(newQueue);
    mediaItem.add(updatedItem);
  }

  @override
  Future<void> play() async {
    // Always allow manual play commands - this method is called for user-initiated play
    // The bluetooth_auto_play setting only affects automatic play from external sources
    
    // If we already have an active item, just resume
    if (_playback.nowPlaying != null) {
      await _playback.resume(context: null);
      return;
    }
    // Offline-friendly: warm load last item and start playback from cached position
    try {
      await _playback.warmLoadLastItem(playAfterLoad: true);
    } catch (_) {}
  }

  /// Handle automatic play requests (e.g., from Bluetooth connection)
  /// This respects the bluetooth_auto_play user setting
  Future<void> playAutomatically() async {
    // Check if automatic play is enabled
    try {
      final prefs = await SharedPreferences.getInstance();
      final allowAutoPlay = prefs.getBool('bluetooth_auto_play') ?? true;
      if (!allowAutoPlay) {
        return;
      }
    } catch (_) {
      // Default to allowing auto-play if there's an error reading preferences
    }

    // If automatic play is allowed, proceed with normal play logic
    await play();
  }

  @override
  Future<void> pause() => _playback.pause();

  @override
  Future<void> stop() async {
    if (_progressPrefListener != null) {
      UiPrefs.progressPrimary.removeListener(_progressPrefListener!);
      _progressPrefListener = null;
    }
    await _playback.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    final pref = UiPrefs.progressPrimary.value;
    if (pref == ProgressPrimary.book) {
      await _playback.seekGlobal(position, reportNow: true);
      return;
    }
    if (pref == ProgressPrimary.chapter) {
      final chapter = _playback.currentChapterProgress;
      if (chapter != null) {
        final target = chapter.start + position;
        await _playback.seekGlobal(target, reportNow: true);
        return;
      }
    }
    await _playback.seek(position, reportNow: true);
  }

  @override
  Future<void> fastForward() => _playback.nudgeSeconds(30);

  @override
  Future<void> rewind() => _playback.nudgeSeconds(-30);

  @override
  Future<void> skipToNext() async {
    // Map skip to next as a 30s nudge for better hardware button UX in Android Auto
    await _playback.nudgeSeconds(30);
  }

  @override
  Future<void> skipToPrevious() async {
    // Map skip to previous as a 15s rewind for better hardware button UX in Android Auto
    await _playback.nudgeSeconds(-15);
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setAudioSource(AudioSource audioSource) async {
    // This is handled by the PlaybackRepository
    await _player.setAudioSource(audioSource);
  }

  // Update the queue with current playing item
  Future<void> updateQueueFromNowPlaying(NowPlaying nowPlaying) async {
    try {
      final mediaItems = nowPlaying.tracks.map((track) {
        return MediaItem(
          id: '${nowPlaying.libraryItemId}_${track.index}',
          album: nowPlaying.title,
          title: '${nowPlaying.title} - Track ${track.index + 1}',
          artist: nowPlaying.author ?? 'Unknown Author',
          duration: track.duration > 0 
              ? Duration(milliseconds: (track.duration * 1000).round())
              : null,
          artUri: nowPlaying.coverUrl != null ? Uri.parse(nowPlaying.coverUrl!) : null,
          displayTitle: nowPlaying.title,
          displaySubtitle: nowPlaying.author,
          playable: true,
        );
      }).toList(growable: false);

      queue.add(mediaItems);
      
      // Set the current index
      if (nowPlaying.currentIndex < mediaItems.length) {
        playbackState.add(playbackState.value.copyWith(
          queueIndex: nowPlaying.currentIndex,
        ));
        
        // Update the current media item for lock screen
        final currentItem = mediaItems[nowPlaying.currentIndex];
        mediaItem.add(currentItem);
      }
    } catch (e) {
      // Error updating queue from now playing
    }
  }

  // Update current media item when track changes
  void updateCurrentMediaItem(int trackIndex) {
    final currentQueue = queue.value;
    if (trackIndex >= 0 && trackIndex < currentQueue.length) {
      final currentItem = currentQueue[trackIndex];
      mediaItem.add(currentItem);
      
      // Also update the queue index to ensure proper synchronization
      playbackState.add(playbackState.value.copyWith(
        queueIndex: trackIndex,
      ));
    }
  }

  // Update playback state with current position
  void updatePlaybackState({
    required bool playing,
    required Duration position,
    Duration? duration,
    double? speed,
  }) {
    playbackState.add(playbackState.value.copyWith(
      playing: playing,
      updatePosition: position,
      speed: speed ?? 1.0,
      processingState: playing 
          ? AudioProcessingState.ready 
          : AudioProcessingState.ready,
    ));
  }

  // Force update the media session
  void forceUpdateMediaSession() {
    try {
      final currentQueue = queue.value;
      final currentIndex = playbackState.value.queueIndex;
      
      if (currentIndex != null && currentIndex >= 0 && currentIndex < currentQueue.length) {
        final currentItem = currentQueue[currentIndex];
        mediaItem.add(currentItem);
      }
    } catch (e) {
      // Error forcing media session update
    }
  }

  // =================== Android Auto / Browse Tree ===================
  @override
  Future<String> getRoot([Map<String, dynamic>? extras]) async {
    // Support search and browsing
    return 'root';
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    // Handle search queries
    final String? query = options?['android.media.browse.extra.QUERY'] as String?;
    final bool isSearch = query != null && query.trim().isNotEmpty;
    
    if (parentMediaId == 'root') {
      return await _getBrowsableBooks(query: isSearch ? query.trim() : null);
    }
    
    // Handle other parent IDs if needed in the future
    return const <MediaItem>[];
  }

  /// Get browsable books from local cache only, sorted by date added desc, with optional search
  Future<List<MediaItem>> _getBrowsableBooks({String? query}) async {
    try {
      final repo = await BooksRepository.create();
      
      // Get books from local database only (no network calls)
      // Sort by updatedAt desc (date added desc), limit to 50 for Android Auto UI
      final books = await repo.listBooksFromDbPaged(
        page: 1,
        limit: 50,
        sort: 'updatedAt:desc',
        query: query,
      );
      
      // Found cached books
      
      if (books.isEmpty) {
        return <MediaItem>[
          MediaItem(
            id: 'kitzi_placeholder_open_phone',
            album: 'Kitzi',
            title: query != null 
                ? 'No books found for "$query". Sync library on phone.'
                : 'Open Kitzi on phone to sync your library',
            artist: ' ',
            playable: false,
          ),
        ];
      }

      // Convert books to MediaItems
      final List<MediaItem> items = books.map<MediaItem>((book) {
        return MediaItem(
          id: book.id,
          album: 'Audiobooks',
          title: book.title,
          artist: book.author ?? 'Unknown author',
          artUri: Uri.tryParse(book.coverUrl),
          playable: true,
          displayTitle: book.title,
          displaySubtitle: book.author,
          // Add additional metadata for better Android Auto experience
          extras: {
            'duration': book.durationMs,
            'updatedAt': book.updatedAt?.millisecondsSinceEpoch,
            'series': book.series,
            'genres': book.genres?.join(', '),
          },
        );
      }).toList(growable: false);

      return items;
    } catch (e) {
      return <MediaItem>[
        MediaItem(
          id: 'kitzi_placeholder_error',
          album: 'Kitzi',
          title: 'Error loading library. Please try again.',
          artist: ' ',
          playable: false,
        ),
      ];
    }
  }

  @override
  Future<List<MediaItem>> search(String query, [Map<String, dynamic>? extras]) async {
    // Android Auto search - return search results as browsable media items
    try {
      final results = await _getBrowsableBooks(query: query.trim());
      return results;
    } catch (e) {
      return <MediaItem>[
        MediaItem(
          id: 'kitzi_placeholder_search_error',
          album: 'Kitzi',
          title: 'Search error. Please try again.',
          artist: ' ',
          playable: false,
        ),
      ];
    }
  }

  @override
  Future<void> playFromMediaId(String mediaId, [Map<String, dynamic>? extras]) async {
    try {
      if (mediaId.startsWith('kitzi_placeholder_')) {
        // Ignore placeholder items in Android Auto
        return;
      }
      if (mediaId == 'kitzi_resume_current') {
        // If we have a current item, resume; else warm-load last cached and play
        if (_playback.nowPlaying != null) {
          await _playback.resume(context: null);
        } else {
          await _playback.warmLoadLastItem(playAfterLoad: true);
        }
        return;
      }
      await _playback.playItem(mediaId, context: null);
      // Ensure queue reflects current now playing model
      final np = _playback.nowPlaying;
      if (np != null) {
        await updateQueueFromNowPlaying(np);
      }
      // No extra play() here; playItem already handles starting playbook
    } catch (e) {
      // playFromMediaId failed
    }
  }
}

class _NotificationProgress {
  final Duration position;
  final Duration duration;
  final Duration buffered;

  const _NotificationProgress({
    required this.position,
    required this.duration,
    required this.buffered,
  });
}

// No headless factory required for current setup
