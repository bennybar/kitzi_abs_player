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
    final bluetoothAutoPlay = await _isBluetoothAutoPlayEnabled();
    
    if (bluetoothAutoPlay) {
      // Enable Bluetooth auto-play (default behavior)
      await session.configure(const AudioSessionConfiguration.music());
    } else {
      // Disable Bluetooth auto-play by using a custom configuration
      await session.configure(AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playback,
        avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker,
        avAudioSessionMode: AVAudioSessionMode.defaultMode,
        avAudioSessionRouteSharingPolicy: AVAudioSessionRouteSharingPolicy.defaultPolicy,
        avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.music,
          flags: AndroidAudioFlags.none,
          usage: AndroidAudioUsage.media,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gain,
        androidWillPauseWhenDucked: true,
      ));
    }
  }

  Future<void> bindAudioService(PlaybackRepository playbackRepository) async {
    if (_isBound) {
      debugPrint('Audio service already bound');
      return;
    }

    try {
      debugPrint('=== BINDING AUDIO SERVICE ===');
      
      // Step 1: Configure audio session
      debugPrint('1. Configuring audio session...');
      final session = await AudioSession.instance;
      await _configureAudioSession(session);
      debugPrint('✓ Audio session configured');

      // Step 2: Create audio handler
      debugPrint('2. Creating audio handler...');
      _audioHandler = KitziAudioHandler(playbackRepository, playbackRepository.player);
      debugPrint('✓ Audio handler created');

      // Step 3: Initialize audio service
      debugPrint('3. Initializing audio service...');
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
      debugPrint('✓ Audio service initialized');

      // Step 4: Do not force playback start; remain lazy to save battery
      _isBound = true;
      _isInitialized = true;
      debugPrint('=== AUDIO SERVICE BOUND SUCCESSFULLY (lazy) ===');
      
    } catch (e) {
      debugPrint('❌ Failed to bind audio service: $e');
      debugPrint('Stack trace: ${StackTrace.current}');
      _isBound = false;
      _isInitialized = false;
    }
  }

  Future<void> updateNowPlaying(NowPlaying nowPlaying) async {
    if (!_isBound || _audioHandler == null) {
      debugPrint('❌ Audio service not bound, attempting to bind...');
      return;
    }

    try {
      debugPrint('Updating now playing: ${nowPlaying.title}');
      await _audioHandler!.updateQueueFromNowPlaying(nowPlaying);
      debugPrint('✓ Now playing updated successfully');
    } catch (e) {
      debugPrint('❌ Failed to update now playing: $e');
    }
  }

  Future<void> updateCurrentTrack(int trackIndex) async {
    if (!_isBound || _audioHandler == null) return;

    try {
      _audioHandler!.updateCurrentMediaItem(trackIndex);
    } catch (e) {
      debugPrint('❌ Failed to update current track: $e');
    }
  }

  Future<void> forceUpdateMediaSession() async {
    if (!_isBound || _audioHandler == null) return;

    try {
      _audioHandler!.forceUpdateMediaSession();
    } catch (e) {
      debugPrint('❌ Failed to force update media session: $e');
    }
  }

  bool get isBound => _isBound;
  bool get isInitialized => _isInitialized;
  KitziAudioHandler? get audioHandler => _audioHandler;

  Future<void> checkStatus() async {
    debugPrint('=== AUDIO SERVICE BINDING STATUS ===');
    debugPrint('Is bound: $_isBound');
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
        debugPrint('Error checking status: $e');
      }
    }
    debugPrint('=== END STATUS CHECK ===');
  }

  Future<void> unbind() async {
    if (_audioHandler != null) {
      try {
        await _audioHandler!.stop();
        await AudioService.stop();
      } catch (e) {
        debugPrint('Error stopping audio service: $e');
      }
    }
    _audioHandler = null;
    _isBound = false;
    _isInitialized = false;
    debugPrint('Audio service unbound');
  }
}
