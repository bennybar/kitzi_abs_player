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
      debugPrint('Audio service already initialized');
      return;
    }

    try {
      debugPrint('=== AUDIO SERVICE INITIALIZATION START ===');
      debugPrint('Initializing audio service...');
      
      // Configure audio session
      debugPrint('Configuring audio session...');
      final session = await AudioSession.instance;
      await _configureAudioSession(session);
      debugPrint('✓ Audio session configured successfully');

      // Create audio handler
      debugPrint('Creating audio handler...');
      _audioHandler = KitziAudioHandler(playbackRepository, playbackRepository.player);
      debugPrint('✓ Audio handler created successfully');

      // Start audio service
      debugPrint('Starting AudioService.init...');
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
      debugPrint('✓ AudioService.init completed successfully');

      // Do not force playback start; keep service lazy for battery savings.

      _isInitialized = true;
      debugPrint('=== AUDIO SERVICE INITIALIZATION COMPLETE ===');
    } catch (e) {
      debugPrint('❌ Failed to initialize audio service: $e');
      debugPrint('Stack trace: ${StackTrace.current}');
      _isInitialized = false;
    }
  }

  KitziAudioHandler? get audioHandler => _audioHandler;

  Future<void> updateNowPlaying(NowPlaying nowPlaying) async {
    debugPrint('AudioServiceManager: updateNowPlaying called with ${nowPlaying.title}');
    
    // Check status before update
    await checkAudioServiceStatus();
    
    if (_audioHandler != null) {
      try {
        await _audioHandler!.updateQueueFromNowPlaying(nowPlaying);
        debugPrint('✓ Audio handler updated successfully');
        
        // Check status after update
        await checkAudioServiceStatus();
      } catch (e) {
        debugPrint('❌ Error updating audio handler: $e');
      }
    } else {
      debugPrint('❌ Audio handler is null - audio service not initialized');
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
    debugPrint('=== AUDIO SERVICE STATUS CHECK ===');
    debugPrint('Is initialized: $_isInitialized');
    debugPrint('Audio handler: ${_audioHandler != null ? 'exists' : 'null'}');
    
    if (_audioHandler != null) {
      try {
        final queue = _audioHandler!.queue.value;
        final mediaItem = _audioHandler!.mediaItem.value;
        final playbackState = _audioHandler!.playbackState.value;
        
        debugPrint('Queue length: ${queue.length}');
        debugPrint('Current media item: ${mediaItem?.title ?? 'null'}');
        debugPrint('Playback state: ${playbackState.playing ? 'playing' : 'paused'}');
        debugPrint('Queue index: ${playbackState.queueIndex}');
      } catch (e) {
        debugPrint('Error checking audio service status: $e');
      }
    }
    debugPrint('=== END STATUS CHECK ===');
  }

  Future<void> dispose() async {
    if (_audioHandler != null) {
      await _audioHandler!.stop();
      _audioHandler = null;
    }
    _isInitialized = false;
  }
}
