import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_repository.dart';
import 'audio_service_handler.dart';

class AudioServiceManager {
  static AudioServiceManager? _instance;
  static AudioServiceManager get instance => _instance ??= AudioServiceManager._();
  
  AudioServiceManager._();

  KitziAudioHandler? _audioHandler;
  bool _isInitialized = false;

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

  Future<void> initialize(PlaybackRepository playbackRepository) async {
    if (_isInitialized) {
      return;
    }

    try {
      // Configure audio session
      final session = await AudioSession.instance;
      await _configureAudioSession(session);

      // Create audio handler
      _audioHandler = KitziAudioHandler(playbackRepository, playbackRepository.player);

      // Start audio service
      await AudioService.init(
        builder: () => _audioHandler!,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.bennybar.kitzi.channel.audio',
          androidNotificationChannelName: 'Kitzi Audio',
          // Per audio_service assertion, keep these consistent
          androidNotificationOngoing: true,
          androidStopForegroundOnPause: true,
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidShowNotificationBadge: true,
          notificationColor: Colors.deepPurple,
        ),
      );

      // Do not force playback start; keep service lazy for battery savings.

      _isInitialized = true;
    } catch (e) {
      _isInitialized = false;
    }
  }

  KitziAudioHandler? get audioHandler => _audioHandler;

  Future<void> updateNowPlaying(NowPlaying nowPlaying) async {
    if (_audioHandler != null) {
      try {
        await _audioHandler!.updateQueueFromNowPlaying(nowPlaying);
      } catch (e) {
        // Error updating audio handler
      }
    }
  }

  Future<void> updateCurrentTrack(int trackIndex) async {
    if (_audioHandler != null) {
      _audioHandler!.updateCurrentMediaItem(trackIndex);
    }
  }

  Future<void> forceUpdateMediaSession() async {
    if (_audioHandler != null) {
      _audioHandler!.forceUpdateMediaSession();
    }
  }

  bool get isInitialized => _isInitialized;

  Future<void> checkAudioServiceStatus() async {
    // Status check method - implementation removed for cleaner logs
  }

  Future<void> dispose() async {
    if (_audioHandler != null) {
      await _audioHandler!.pause();
      _audioHandler = null;
    }
    _isInitialized = false;
  }
}
