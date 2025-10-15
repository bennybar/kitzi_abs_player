import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:audio_session/audio_session.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_repository.dart';
import 'audio_service_handler.dart';

class AudioServiceBinding {
  static AudioServiceBinding? _instance;
  static AudioServiceBinding get instance => _instance ??= AudioServiceBinding._();
  
  AudioServiceBinding._();

  KitziAudioHandler? _audioHandler;
  bool _isBound = false;
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

  Future<void> bindAudioService(PlaybackRepository playbackRepository) async {
    if (_isBound) {
      return;
    }

    try {
      // Step 1: Configure audio session
      final session = await AudioSession.instance;
      await _configureAudioSession(session);

      // Step 2: Create audio handler
      _audioHandler = KitziAudioHandler(playbackRepository, playbackRepository.player);

      // Step 3: Initialize audio service
      await AudioService.init(
        builder: () => _audioHandler!,
        config: AudioServiceConfig(
          androidNotificationChannelId: 'com.bennybar.kitzi.channel.audio',
          androidNotificationChannelName: 'Kitzi Audio',
          androidNotificationIcon: 'mipmap/ic_launcher',
          androidShowNotificationBadge: true,
          // Per audio_service assertion, if ongoing=true then stopOnPause must be true
          androidStopForegroundOnPause: true,
          androidNotificationOngoing: true,
        ),
      );

      // Step 4: Do not force playback start; remain lazy to save battery
      _isBound = true;
      _isInitialized = true;
      
    } catch (e) {
      _isBound = false;
      _isInitialized = false;
    }
  }

  Future<void> updateNowPlaying(NowPlaying nowPlaying) async {
    if (!_isBound || _audioHandler == null) {
      return;
    }

    try {
      await _audioHandler!.updateQueueFromNowPlaying(nowPlaying);
    } catch (e) {
      // Failed to update now playing
    }
  }

  Future<void> updateCurrentTrack(int trackIndex) async {
    if (!_isBound || _audioHandler == null) return;

    try {
      _audioHandler!.updateCurrentMediaItem(trackIndex);
    } catch (e) {
      // Failed to update current track
    }
  }

  Future<void> forceUpdateMediaSession() async {
    if (!_isBound || _audioHandler == null) return;

    try {
      _audioHandler!.forceUpdateMediaSession();
    } catch (e) {
      // Failed to force update media session
    }
  }

  bool get isBound => _isBound;
  bool get isInitialized => _isInitialized;
  KitziAudioHandler? get audioHandler => _audioHandler;

  Future<void> checkStatus() async {
    // Status check method - implementation removed for cleaner logs
  }

  Future<void> unbind() async {
    if (_audioHandler != null) {
      try {
        await _audioHandler!.pause();
        await AudioService.stop();
      } catch (e) {
        // Error stopping audio service
      }
    }
    _audioHandler = null;
    _isBound = false;
    _isInitialized = false;
  }
}
