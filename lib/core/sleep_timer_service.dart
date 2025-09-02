import 'dart:async';
import 'package:flutter/material.dart';

import 'playback_repository.dart';

class SleepTimerService {
  static SleepTimerService? _instance;
  static SleepTimerService get instance => _instance ??= SleepTimerService._();
  
  SleepTimerService._();

  Timer? _sleepTimer;
  Duration? _remainingTime;
  bool _isActive = false;
  PlaybackRepository? _playbackRepository;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
  }

  /// Start sleep timer with specified duration
  void startTimer(Duration duration) {
    _stopTimer(); // Stop any existing timer
    
    _remainingTime = duration;
    _isActive = true;
    
    _sleepTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
      if (_remainingTime != null) {
        _remainingTime = _remainingTime! - const Duration(minutes: 1);
        
        if (_remainingTime!.inMinutes <= 0) {
          _stopTimer();
          _pausePlayback();
        }
      }
    });
    
    debugPrint('Sleep timer started for ${duration.inMinutes} minutes');
  }

  /// Stop sleep timer
  void stopTimer() {
    _stopTimer();
  }

  /// Pause sleep timer (keeps remaining time)
  void pauseTimer() {
    if (_sleepTimer != null) {
      _sleepTimer!.cancel();
      _sleepTimer = null;
      _isActive = false;
      debugPrint('Sleep timer paused');
    }
  }

  /// Resume sleep timer
  void resumeTimer() {
    if (_remainingTime != null && !_isActive) {
      _isActive = true;
      _sleepTimer = Timer.periodic(const Duration(minutes: 1), (timer) {
        if (_remainingTime != null) {
          _remainingTime = _remainingTime! - const Duration(minutes: 1);
          
          if (_remainingTime!.inMinutes <= 0) {
            _stopTimer();
            _pausePlayback();
          }
        }
      });
      debugPrint('Sleep timer resumed');
    }
  }

  /// Get remaining time
  Duration? get remainingTime => _remainingTime;

  /// Check if timer is active
  bool get isActive => _isActive;

  /// Get formatted remaining time string
  String get formattedRemainingTime {
    if (_remainingTime == null) return '';
    
    final hours = _remainingTime!.inHours;
    final minutes = _remainingTime!.inMinutes % 60;
    
    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }

  /// Add time to existing timer
  void addTime(Duration additionalTime) {
    if (_remainingTime != null) {
      _remainingTime = _remainingTime! + additionalTime;
      debugPrint('Added ${additionalTime.inMinutes} minutes to sleep timer');
    }
  }

  /// Subtract time from existing timer
  void subtractTime(Duration timeToSubtract) {
    if (_remainingTime != null) {
      _remainingTime = _remainingTime! - timeToSubtract;
      if (_remainingTime!.isNegative) {
        _remainingTime = Duration.zero;
      }
      debugPrint('Subtracted ${timeToSubtract.inMinutes} minutes from sleep timer');
    }
  }

  void _stopTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _isActive = false;
    _remainingTime = null;
    debugPrint('Sleep timer stopped');
  }

  void _pausePlayback() {
    try {
      _playbackRepository?.pause();
      debugPrint('Playback paused due to sleep timer');
    } catch (e) {
      debugPrint('Failed to pause playback: $e');
    }
  }

  /// Dispose service
  void dispose() {
    _stopTimer();
    _playbackRepository = null;
  }
}
