import 'dart:async';
import 'package:flutter/material.dart';

import 'playback_repository.dart';

enum SleepTimerMode {
  duration,
  endOfChapter,
}

class SleepTimerService {
  static SleepTimerService? _instance;
  static SleepTimerService get instance => _instance ??= SleepTimerService._();
  
  SleepTimerService._();

  Timer? _sleepTimer;
  Duration? _remainingTime;
  bool _isActive = false;
  PlaybackRepository? _playbackRepository;
  SleepTimerMode? _mode;
  int? _startChapterIndex;
  StreamSubscription<Duration>? _positionSub;
  final StreamController<Duration?> _remainingCtr = StreamController.broadcast();
  
  Stream<Duration?> get remainingTimeStream => _remainingCtr.stream;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
  }

  /// Start sleep timer with specified duration
  void startTimer(Duration duration) {
    _stopTimer(); // Stop any existing timer
    _mode = SleepTimerMode.duration;
    _startChapterIndex = null;
    
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

  /// Start an end-of-chapter sleep timer. Cancels if chapter changes.
  void startEndOfChapter() {
    final repo = _playbackRepository;
    if (repo == null) return;
    final np = repo.nowPlaying;
    if (np == null || np.chapters.isEmpty) {
      debugPrint('Sleep timer: no chapters available for end-of-chapter mode');
      return;
    }

    _stopTimer();
    _mode = SleepTimerMode.endOfChapter;
    _isActive = true;

    // Determine current chapter index at start
    _startChapterIndex = _currentChapterIndex();
    if (_startChapterIndex == null) {
      // Fallback: cancel if cannot determine
      _stopTimer();
      return;
    }

    _updateEndOfChapterRemaining();
    _remainingCtr.add(_remainingTime);

    // Listen to position updates to recompute remaining and detect chapter changes
    _positionSub?.cancel();
    _positionSub = repo.positionStream.listen((_) {
      if (_mode != SleepTimerMode.endOfChapter) return;
      final currentIdx = _currentChapterIndex();
      if (currentIdx == null) {
        _stopTimer();
        return;
      }
      if (currentIdx != _startChapterIndex) {
        debugPrint('Sleep timer (EOC): chapter changed from $_startChapterIndex to $currentIdx → cancel');
        _stopTimer();
        return;
      }

      _updateEndOfChapterRemaining();
      _remainingCtr.add(_remainingTime);
      if (_remainingTime != null && _remainingTime! <= Duration.zero) {
        _stopTimer();
        _pausePlayback();
      }
    });

    debugPrint('Sleep timer started: end of chapter (index=$_startChapterIndex)');
  }

  /// Get remaining time
  Duration? get remainingTime => _remainingTime;

  /// Check if timer is active
  bool get isActive => _isActive;

  /// Current mode
  SleepTimerMode? get mode => _mode;
  bool get isEndOfChapter => _mode == SleepTimerMode.endOfChapter;

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
      _remainingCtr.add(_remainingTime);
      debugPrint('Subtracted ${timeToSubtract.inMinutes} minutes from sleep timer');
    }
  }

  void _stopTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _isActive = false;
    _remainingTime = null;
    _mode = null;
    _startChapterIndex = null;
    _positionSub?.cancel();
    _positionSub = null;
    _remainingCtr.add(null);
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

  int? _currentChapterIndex() {
    final repo = _playbackRepository;
    if (repo == null) return null;
    final np = repo.nowPlaying;
    if (np == null || np.chapters.isEmpty) return null;
    final pos = repo.player.position;
    int idx = 0;
    for (int i = 0; i < np.chapters.length; i++) {
      if (pos >= np.chapters[i].start) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  void _updateEndOfChapterRemaining() {
    final repo = _playbackRepository;
    if (repo == null) return;
    final np = repo.nowPlaying;
    if (np == null) return;

    final pos = repo.player.position;
    final chapters = np.chapters;
    if (chapters.isEmpty) {
      _remainingTime = null;
      return;
    }

    // Find next chapter start
    Duration? nextStart;
    for (final c in chapters) {
      if (c.start > pos) {
        nextStart = c.start;
        break;
      }
    }

    if (nextStart != null) {
      _remainingTime = nextStart - pos;
      return;
    }

    // If last chapter, use end of book based on total track durations
    double totalSec = 0.0;
    for (final t in np.tracks) {
      totalSec += t.duration > 0 ? t.duration : 0.0;
    }
    final total = Duration(milliseconds: (totalSec * 1000).round());
    _remainingTime = total - pos;
  }

  /// Dispose service
  void dispose() {
    _stopTimer();
    _playbackRepository = null;
    _remainingCtr.close();
  }
}
