import 'dart:async';
import 'package:flutter/material.dart';

import 'playback_repository.dart';

enum SleepTimerMode { none, duration, chapterEnd }

class SleepTimerService {
  static SleepTimerService? _instance;
  static SleepTimerService get instance => _instance ??= SleepTimerService._();
  
  SleepTimerService._();

  Timer? _sleepTimer;
  Duration? _remainingTime;
  bool _isActive = false;
  PlaybackRepository? _playbackRepository;
  final StreamController<Duration?> _remainingCtr = StreamController.broadcast();
  SleepTimerMode _mode = SleepTimerMode.none;
  Duration? _targetChapterEnd;
  String? _targetItemId;
  StreamSubscription<Duration>? _chapterPositionSub;
  
  Stream<Duration?> get remainingTimeStream => _remainingCtr.stream;
  SleepTimerMode get mode => _mode;
  bool get isChapterMode => _mode == SleepTimerMode.chapterEnd;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
  }

  /// Start sleep timer with specified duration
  void startTimer(Duration duration) {
    _stopTimer(); // Stop any existing timer
    
    _mode = SleepTimerMode.duration;
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

  /// Start sleep timer that stops at the end of the current chapter
  bool startSleepUntilChapterEnd() {
    final playback = _playbackRepository;
    final np = playback?.nowPlaying;
    if (playback == null || np == null) return false;
    if (np.chapters.length < 2) return false;
    final metrics = playback.currentChapterProgress;
    if (metrics == null) return false;

    _stopTimer();

    _mode = SleepTimerMode.chapterEnd;
    _isActive = true;
    _targetChapterEnd = metrics.end;
    _targetItemId = np.libraryItemId;
    _remainingTime = metrics.duration - metrics.elapsed;
    if (_remainingTime != null && _remainingTime!.isNegative) {
      _remainingTime = Duration.zero;
    }
    _remainingCtr.add(_remainingTime);

    _chapterPositionSub = playback.positionStream.listen((_) => _handleChapterModeTick());
    _handleChapterModeTick();
    return true;
  }

  /// Cancel chapter-end sleep mode without pausing playback
  void cancelChapterSleepIfActive() {
    if (_mode == SleepTimerMode.chapterEnd) {
      _stopTimer();
    }
  }

  /// Pause sleep timer (keeps remaining time)
  void pauseTimer() {
    if (_mode != SleepTimerMode.duration) return;
    if (_sleepTimer != null) {
      _sleepTimer!.cancel();
      _sleepTimer = null;
      _isActive = false;
      // 'Sleep timer paused');
    }
  }

  /// Resume sleep timer
  void resumeTimer() {
    if (_mode != SleepTimerMode.duration) return;
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
    if (_mode != SleepTimerMode.duration || _remainingTime == null) return;
    _remainingTime = _remainingTime! + additionalTime;
    _remainingCtr.add(_remainingTime);
    // 'Added ${additionalTime.inMinutes} minutes to sleep timer');
  }

  /// Subtract time from existing timer
  void subtractTime(Duration timeToSubtract) {
    if (_mode != SleepTimerMode.duration || _remainingTime == null) return;
    _remainingTime = _remainingTime! - timeToSubtract;
    if (_remainingTime!.isNegative) {
      _remainingTime = Duration.zero;
    }
    _remainingCtr.add(_remainingTime);
    // 'Subtracted ${timeToSubtract.inMinutes} minutes from sleep timer');
  }

  void _stopTimer() {
    _sleepTimer?.cancel();
    _chapterPositionSub?.cancel();
    _chapterPositionSub = null;
    _sleepTimer = null;
    _isActive = false;
    _remainingTime = null;
    _targetChapterEnd = null;
    _targetItemId = null;
    _mode = SleepTimerMode.none;
    _remainingCtr.add(null);
    // 'Sleep timer stopped');
  }

  void _handleChapterModeTick() {
    if (_mode != SleepTimerMode.chapterEnd || !_isActive) {
      return;
    }

    final playback = _playbackRepository;
    final targetEnd = _targetChapterEnd;
    final targetItem = _targetItemId;

    if (playback == null || targetEnd == null || targetItem == null) {
      _stopTimer();
      return;
    }

    final np = playback.nowPlaying;
    if (np == null || np.libraryItemId != targetItem) {
      _stopTimer();
      return;
    }

    final globalPos = playback.globalBookPosition;
    if (globalPos == null) {
      return;
    }

    var remaining = targetEnd - globalPos;
    if (remaining.isNegative) {
      remaining = Duration.zero;
    }

    if (_remainingTime == null || (_remainingTime! - remaining).abs() >= const Duration(milliseconds: 500)) {
      _remainingTime = remaining;
      _remainingCtr.add(_remainingTime);
    } else {
      _remainingTime = remaining;
    }

    if (remaining <= const Duration(milliseconds: 500)) {
      _stopTimer();
      _pausePlayback();
    }
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
