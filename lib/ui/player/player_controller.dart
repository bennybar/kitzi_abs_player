// lib/ui/player/player_controller.dart
import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/playback_repository.dart';

/// Very thin wrapper used by some UI code to start playback via the shared
/// app player (defined in core/playback_repository.dart).
class PlayerController {
  final PlaybackRepository playbackRepo;
  PlayerController(this.playbackRepo);

  /// Expose a simple seconds stream for legacy callers (derived from
  /// PlaybackRepository's position stream).
  Stream<double> get positionSecondsStream =>
      playbackRepo.positionStream.map((d) => d.inMilliseconds / 1000.0);

  /// Start playback of a library item (or specific episode) using the shared
  /// player managed by PlaybackRepository.
  Future<bool> playItem(String libraryItemId, {String? episodeId, BuildContext? context}) {
    return playbackRepo.playItem(libraryItemId, episodeId: episodeId);
  }

  /// Pause/resume helpers, if needed by callers.
  Future<void> pause() => playbackRepo.pause();
  Future<bool> resume({BuildContext? context}) => playbackRepo.resume();

  /// Optional cleanup hook — the shared player lives in PlaybackRepository,
  /// so there is nothing to dispose here.
  Future<void> dispose() async {}
}
