import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_repository.dart';

class PlaybackSpeedService {
  static PlaybackSpeedService? _instance;
  static PlaybackSpeedService get instance => _instance ??= PlaybackSpeedService._();
  
  PlaybackSpeedService._();

  static const String _speedKey = 'playback_speed';
  static const double _defaultSpeed = 1.0;
  static const List<double> _availableSpeeds = [
    0.5, 0.75, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0
  ];

  double _currentSpeed = _defaultSpeed;
  PlaybackRepository? _playbackRepository;

  void initialize(PlaybackRepository playbackRepository) {
    _playbackRepository = playbackRepository;
    _loadSpeed();
  }

  /// Get available playback speeds
  List<double> get availableSpeeds => _availableSpeeds;

  /// Get current playback speed
  double get currentSpeed => _currentSpeed;

  /// Set playback speed
  Future<void> setSpeed(double speed) async {
    if (!_availableSpeeds.contains(speed)) {
      debugPrint('Invalid speed: $speed');
      return;
    }

    try {
      await _playbackRepository?.setSpeed(speed);
      _currentSpeed = speed;
      await _saveSpeed();
      debugPrint('Playback speed set to: ${speed}x');
    } catch (e) {
      debugPrint('Failed to set playback speed: $e');
    }
  }

  /// Increase speed by one step
  Future<void> increaseSpeed() async {
    final currentIndex = _availableSpeeds.indexOf(_currentSpeed);
    if (currentIndex < _availableSpeeds.length - 1) {
      final newSpeed = _availableSpeeds[currentIndex + 1];
      await setSpeed(newSpeed);
    }
  }

  /// Decrease speed by one step
  Future<void> decreaseSpeed() async {
    final currentIndex = _availableSpeeds.indexOf(_currentSpeed);
    if (currentIndex > 0) {
      final newSpeed = _availableSpeeds[currentIndex - 1];
      await setSpeed(newSpeed);
    }
  }

  /// Reset to default speed
  Future<void> resetToDefault() async {
    await setSpeed(_defaultSpeed);
  }

  /// Get formatted speed string
  String get formattedSpeed => '${_currentSpeed.toStringAsFixed(2)}x';

  /// Get speed percentage
  int get speedPercentage => (_currentSpeed * 100).round();

  /// Check if speed is at minimum
  bool get isAtMinSpeed => _currentSpeed == _availableSpeeds.first;

  /// Check if speed is at maximum
  bool get isAtMaxSpeed => _currentSpeed == _availableSpeeds.last;

  /// Get next available speed
  double? get nextSpeed {
    final currentIndex = _availableSpeeds.indexOf(_currentSpeed);
    if (currentIndex < _availableSpeeds.length - 1) {
      return _availableSpeeds[currentIndex + 1];
    }
    return null;
  }

  /// Get previous available speed
  double? get previousSpeed {
    final currentIndex = _availableSpeeds.indexOf(_currentSpeed);
    if (currentIndex > 0) {
      return _availableSpeeds[currentIndex - 1];
    }
    return null;
  }

  /// Load saved speed from preferences
  Future<void> _loadSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedSpeed = prefs.getDouble(_speedKey);
      if (savedSpeed != null && _availableSpeeds.contains(savedSpeed)) {
        _currentSpeed = savedSpeed;
        debugPrint('Loaded saved speed: ${savedSpeed}x');
      }
    } catch (e) {
      debugPrint('Failed to load speed: $e');
    }
  }

  /// Save current speed to preferences
  Future<void> _saveSpeed() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_speedKey, _currentSpeed);
    } catch (e) {
      debugPrint('Failed to save speed: $e');
    }
  }

  /// Get speed description
  String getSpeedDescription(double speed) {
    switch (speed) {
      case 0.5:
        return 'Very Slow';
      case 0.75:
        return 'Slow';
      case 0.9:
        return 'Slightly Slow';
      case 1.0:
        return 'Normal';
      case 1.1:
        return 'Slightly Fast';
      case 1.25:
        return 'Fast';
      case 1.5:
        return 'Very Fast';
      case 1.75:
        return 'Very Fast +';
      case 2.0:
        return '2x Speed';
      case 2.5:
        return '2.5x Speed';
      case 3.0:
        return '3x Speed';
      default:
        return '${speed.toStringAsFixed(2)}x';
    }
  }

  /// Check if speed is in normal range
  bool get isNormalSpeed => _currentSpeed >= 0.9 && _currentSpeed <= 1.1;

  /// Check if speed is slow
  bool get isSlowSpeed => _currentSpeed < 0.9;

  /// Check if speed is fast
  bool get isFastSpeed => _currentSpeed > 1.1;

  /// Get recommended speed for current content
  double get recommendedSpeed {
    // This could be enhanced with content analysis
    // For now, return a reasonable default
    return 1.0;
  }

  /// Apply speed to current playback
  Future<void> applyCurrentSpeed() async {
    if (_playbackRepository != null) {
      try {
        await _playbackRepository!.setSpeed(_currentSpeed);
      } catch (e) {
        debugPrint('Failed to apply current speed: $e');
      }
    }
  }
}
