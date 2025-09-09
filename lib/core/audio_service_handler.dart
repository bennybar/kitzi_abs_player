import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';

import 'playback_repository.dart';
import 'books_repository.dart';
import 'play_history_service.dart';
import '../models/book.dart';

class KitziAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final PlaybackRepository _playback;
  final AudioPlayer _player;
  
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
      debugPrint("Error loading empty playlist: $e");
    }
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _player.playbackEventStream.listen((PlaybackEvent event) {
      final playing = _player.playing;
      final currentIndex = _player.currentIndex ?? 0;
      
      // Update playback state
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.rewind,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.fastForward,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: {
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
        updatePosition: _player.position,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
        queueIndex: currentIndex,
      ));
      
      // Update current media item for lock screen
      final q = queue.value;
      if (currentIndex >= 0 && currentIndex < q.length) {
        final currentItem = q[currentIndex];
        mediaItem.add(currentItem);
        // Current media item changed; AA will refresh on next browse request
            }
    });
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
          debugPrint('Error updating MediaItem duration: $e');
        }
      }
    });
  }

  void _listenForPositionChanges() {
    // Push frequent position/buffer updates so Android notification/lock screen
    // show a moving progress bar between playback events.
    _player.positionStream.listen((pos) {
      playbackState.add(playbackState.value.copyWith(
        updatePosition: pos,
        bufferedPosition: _player.bufferedPosition,
        speed: _player.speed,
      ));

      // If the current mediaItem has no duration yet but the player knows it
      // (common with local files), update it so system UIs can render progress.
      try {
        final d = _player.duration;
        if (d != null) {
          final q = queue.value;
          int? idx = playbackState.value.queueIndex;
          idx ??= _player.currentIndex;
          idx ??= q.isNotEmpty ? 0 : null;
          if (idx != null && idx >= 0 && idx < q.length) {
            final current = q[idx];
            if (current.duration == null || current.duration == Duration.zero) {
              final updated = current.copyWith(duration: d);
              final newQ = List<MediaItem>.from(q);
              newQ[idx] = updated;
              queue.add(newQ);
              mediaItem.add(updated);
            }
          }
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
    debugPrint('Setting up now playing listener...');
    _playback.nowPlayingStream.listen((nowPlaying) {
      debugPrint('Received now playing update: ${nowPlaying?.title ?? 'null'}');
      if (nowPlaying != null) {
        updateQueueFromNowPlaying(nowPlaying);
      }
    });
  }

  @override
  Future<void> play() async {
    // If we already have an active item, just resume
    if (_playback.nowPlaying != null) {
      await _playback.resume();
      return;
    }
    // Offline-friendly: warm load last item and start playback from cached position
    try {
      await _playback.warmLoadLastItem(playAfterLoad: true);
    } catch (_) {}
  }

  @override
  Future<void> pause() => _playback.pause();

  @override
  Future<void> stop() => _playback.stop();

  @override
  Future<void> seek(Duration position) => _playback.seek(position, reportNow: true);

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
      debugPrint('Updating queue with now playing: ${nowPlaying.title}');
      
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

      debugPrint('Created ${mediaItems.length} media items');
      queue.add(mediaItems);
      
      // Set the current index
      if (nowPlaying.currentIndex < mediaItems.length) {
        playbackState.add(playbackState.value.copyWith(
          queueIndex: nowPlaying.currentIndex,
        ));
        
        // Update the current media item for lock screen
        final currentItem = mediaItems[nowPlaying.currentIndex];
        mediaItem.add(currentItem);
        debugPrint('Updated current media item: ${currentItem.title}');
      }
    } catch (e) {
      debugPrint('Error updating queue from now playing: $e');
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
        debugPrint('Forced media session update: ${currentItem.title}');
            }
    } catch (e) {
      debugPrint('Error forcing media session update: $e');
    }
  }

  // =================== Android Auto / Browse Tree ===================
  @override
  Future<String> getRoot([Map<String, dynamic>? extras]) async {
    debugPrint('AA:getRoot called');
    // Single root for entire library
    return 'root';
  }

  @override
  Future<List<MediaItem>> getChildren(String parentMediaId, [Map<String, dynamic>? options]) async {
    if (parentMediaId != 'root') return const <MediaItem>[];
    debugPrint('AA:getChildren for parent=$parentMediaId');

    // 1) Load up to 3 recent books from local play history (fast, no network)
    List<Book> recent = const <Book>[];
    try {
      recent = await PlayHistoryService.getLastPlayedBooks(3);
    } catch (_) {}

    // 2) Attempt to load additional books with a short timeout to avoid long spinners
    List<Book> extra = const <Book>[];
    try {
      final repo = await BooksRepository.create();
      extra = await repo.listBooks().timeout(const Duration(milliseconds: 1200));
    } catch (_) {}

    // 3) Compose unique list: recent first, then others not already included
    final seen = <String>{for (final b in recent) b.id};
    final ordered = <Book>[...recent];
    for (final b in extra) {
      if (!seen.contains(b.id)) {
        ordered.add(b);
        seen.add(b.id);
      }
      if (ordered.length >= 20) break; // keep list concise for AA UI
    }

    if (ordered.isEmpty) {
      return const <MediaItem>[
        MediaItem(
          id: 'kitzi_placeholder_open_phone',
          album: 'Kitzi',
          title: 'Open Kitzi on phone to browse your library',
          artist: ' ',
          playable: false,
        ),
      ];
    }

    final List<MediaItem> items = ordered.map<MediaItem>((b) {
      final isRecent = recent.any((r) => r.id == b.id);
      final title = isRecent ? 'Continue: ${b.title}' : b.title;
      return MediaItem(
        id: b.id,
        album: 'Audiobooks',
        title: title,
        artist: b.author ?? 'Unknown author',
        artUri: Uri.tryParse(b.coverUrl),
        playable: true,
      );
    }).toList(growable: false);

    debugPrint('AA:getChildren returning ${items.length} items (recent=${recent.length})');
    return items;
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
          await _playback.resume();
        } else {
          await _playback.warmLoadLastItem(playAfterLoad: true);
        }
        return;
      }
      await _playback.playItem(mediaId);
      // Ensure queue reflects current now playing model
      final np = _playback.nowPlaying;
      if (np != null) {
        await updateQueueFromNowPlaying(np);
      }
      // No extra play() here; playItem already handles starting playback
    } catch (e) {
      debugPrint('playFromMediaId failed: $e'); // Fixed context parameter
    }
  }
}

// No headless factory required for current setup
