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
  final StreamController<Duration?> _remainingCtr = StreamController.broadcast();
  
  Stream<Duration?> get remainingTimeStream => _remainingCtr.stream;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
  }

  /// Start sleep timer with specified duration
  void startTimer(Duration duration) {
    _stopTimer(); // Stop any existing timer
    
    _remainingTime = duration;
    _isActive = true;
    _remainingCtr.add(_remainingTime);
    
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_remainingTime != null) {
        _remainingTime = _remainingTime! - const Duration(seconds: 1);
        _remainingCtr.add(_remainingTime);
        if (_remainingTime! <= Duration.zero) {
          _stopTimer();
          _pausePlayback();
        }
      }
    });
    
    // 'Sleep timer started for ${duration.inMinutes} minutes');
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
      // 'Sleep timer paused');
    }
  }

  /// Resume sleep timer
  void resumeTimer() {
    if (_remainingTime != null && !_isActive) {
      _isActive = true;
      _sleepTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (_remainingTime != null) {
          _remainingTime = _remainingTime! - const Duration(seconds: 1);
          _remainingCtr.add(_remainingTime);
          if (_remainingTime! <= Duration.zero) {
            _stopTimer();
            _pausePlayback();
          }
        }
      });
      // 'Sleep timer resumed');
    }
  }

  /// Get remaining time
  Duration? get remainingTime => _remainingTime;

  /// Check if timer is active
  bool get isActive => _isActive;


  /// Get formatted remaining time string
  String get formattedRemainingTime {
    if (_remainingTime == null) return '';
    final d = _remainingTime! < Duration.zero ? Duration.zero : _remainingTime!;
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) {
      final mm = minutes.toString().padLeft(2, '0');
      final ss = seconds.toString().padLeft(2, '0');
      return '$hours:$mm:$ss';
    }
    final mm = d.inMinutes;
    final ss = seconds.toString().padLeft(2, '0');
    return '${mm.toString().padLeft(2, '0')}:$ss';
  }

  /// Add time to existing timer
  void addTime(Duration additionalTime) {
    if (_remainingTime != null) {
      _remainingTime = _remainingTime! + additionalTime;
      _remainingCtr.add(_remainingTime);
      // 'Added ${additionalTime.inMinutes} minutes to sleep timer');
    }
  }

  /// Subtract time from existing timer
  void subtractTime(Duration timeToSubtract) {
    if (_remainingTime != null) {
      _remainingTime = _remainingTime! - timeToSubtract;
      if (_remainingTime!.isNegative) {
        _remainingTime = Duration.zero;
      }
      _remainingCtr.add(_remainingTime);
      // 'Subtracted ${timeToSubtract.inMinutes} minutes from sleep timer');
    }
  }

  void _stopTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _isActive = false;
    _remainingTime = null;
    _remainingCtr.add(null);
    // 'Sleep timer stopped');
  }

  void _pausePlayback() {
    try {
      _playbackRepository?.pause();
      // 'Playback paused due to sleep timer');
    } catch (e) {
      // 'Failed to pause playback: $e');
    }
  }

  

  /// Dispose service
  void dispose() {
    _stopTimer();
    _playbackRepository = null;
    _remainingCtr.close();
  }
}
