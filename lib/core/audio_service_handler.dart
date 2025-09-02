import 'package:audio_service/audio_service.dart';
import 'package:just_audio/just_audio.dart';
import 'package:flutter/material.dart';

import 'playback_repository.dart';

class KitziAudioHandler extends BaseAudioHandler with QueueHandler, SeekHandler {
  final PlaybackRepository _playback;
  final AudioPlayer _player;
  
  KitziAudioHandler(this._playback, this._player) {
    _loadEmptyPlaylist();
    _notifyAudioHandlerAboutPlaybackEvents();
    _listenForDurationChanges();
    _listenForCurrentSongIndexChanges();
    _listenForSequenceStateChanges();
    _listenForNowPlayingChanges();
  }

  Future<void> _loadEmptyPlaylist() async {
    try {
      queue.add([MediaItem(
        id: '1',
        album: "Audiobookshelf",
        title: "Loading...",
        duration: Duration.zero,
      )]);
    } catch (e) {
      debugPrint("Error: $e");
    }
  }

  void _notifyAudioHandlerAboutPlaybackEvents() {
    _player.playbackEventStream.listen((PlaybackEvent event) {
      final playing = _player.playing;
      final currentIndex = _player.currentIndex ?? 0;
      
      playbackState.add(playbackState.value.copyWith(
        controls: [
          MediaControl.skipToPrevious,
          if (playing) MediaControl.pause else MediaControl.play,
          MediaControl.skipToNext,
          MediaControl.stop,
        ],
        systemActions: {
          MediaAction.seek,
          MediaAction.seekForward,
          MediaAction.seekBackward,
        },
        androidCompactActionIndices: const [0, 1, 2],
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
      
      // Update current media item if available
      if (currentIndex >= 0 && currentIndex < queue.value.length) {
        final currentItem = queue.value[currentIndex];
        mediaItem.add(currentItem);
      }
    });
  }

  void _listenForDurationChanges() {
    _player.durationStream.listen((duration) {
      var index = _player.currentIndex;
      final newQueue = queue.value.toList();
      if (index != null && index < newQueue.length) {
        final oldMediaItem = newQueue[index];
        final newMediaItem = oldMediaItem.copyWith(duration: duration);
        newQueue[index] = newMediaItem;
        queue.add(newQueue);
      }
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
      final queue = sequenceState.effectiveSequence;
      if (queue.isEmpty) return;
      final metadata = queue.map((source) => source.tag).toList().cast<MediaItem>();
      this.queue.add(metadata);
    });
  }

  void _listenForNowPlayingChanges() {
    _playback.nowPlayingStream.listen((nowPlaying) {
      if (nowPlaying != null) {
        updateQueueFromNowPlaying(nowPlaying);
      }
    });
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> stop() => _player.stop();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> skipToNext() async {
    await _playback.nextTrack();
  }

  @override
  Future<void> skipToPrevious() async {
    await _playback.prevTrack();
  }

  @override
  Future<void> setSpeed(double speed) => _player.setSpeed(speed);

  Future<void> setAudioSource(AudioSource audioSource) async {
    // This is handled by the PlaybackRepository
    await _player.setAudioSource(audioSource);
  }

  // Update the queue with current playing item
  Future<void> updateQueueFromNowPlaying(NowPlaying nowPlaying) async {
    final mediaItems = nowPlaying.tracks.map((track) {
      return MediaItem(
        id: '${nowPlaying.libraryItemId}_${track.index}',
        album: nowPlaying.title,
        title: '${nowPlaying.title} - Track ${track.index + 1}',
        artist: nowPlaying.author ?? 'Unknown Author',
        duration: track.duration > 0 
            ? Duration(milliseconds: (track.duration * 1000).round())
            : Duration.zero,
        artUri: nowPlaying.coverUrl != null ? Uri.parse(nowPlaying.coverUrl!) : null,
        displayTitle: nowPlaying.title,
        displaySubtitle: nowPlaying.author,
        playable: true,
      );
    }).toList();

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
}
