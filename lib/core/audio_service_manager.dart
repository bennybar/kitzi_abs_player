import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart';

import 'playback_repository.dart';
import 'audio_service_handler.dart';

class AudioServiceManager {
  static AudioServiceManager? _instance;
  static AudioServiceManager get instance => _instance ??= AudioServiceManager._();
  
  AudioServiceManager._();

  KitziAudioHandler? _audioHandler;
  bool _isInitialized = false;

  Future<void> initialize(PlaybackRepository playbackRepository) async {
    if (_isInitialized) return;

    try {
      // Configure audio session
      final session = await AudioSession.instance;
      await session.configure(AudioSessionConfiguration.music());

      // Create audio handler
      _audioHandler = KitziAudioHandler(playbackRepository, playbackRepository.player);

      // Start audio service
      await AudioService.init(
        builder: () => _audioHandler!,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.bennybar.kitzi.channel.audio',
          androidNotificationChannelName: 'Kitzi Audio',
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: false,
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidShowNotificationBadge: true,
        ),
      );

      _isInitialized = true;
      debugPrint('Audio service initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize audio service: $e');
    }
  }

  KitziAudioHandler? get audioHandler => _audioHandler;

  Future<void> updateNowPlaying(NowPlaying nowPlaying) async {
    if (_audioHandler != null) {
      await _audioHandler!.updateQueueFromNowPlaying(nowPlaying);
    }
  }

  Future<void> updateCurrentTrack(int trackIndex) async {
    if (_audioHandler != null) {
      _audioHandler!.updateCurrentMediaItem(trackIndex);
    }
  }

  Future<void> dispose() async {
    if (_audioHandler != null) {
      await _audioHandler!.stop();
      _audioHandler = null;
    }
    _isInitialized = false;
  }
}
