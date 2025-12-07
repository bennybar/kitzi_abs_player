// lib/core/session_logger_service.dart
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

/// Service for logging session that captures all logs to a file for up to 15 minutes
class SessionLoggerService {
  SessionLoggerService._();
  static final SessionLoggerService instance = SessionLoggerService._();

  File? _logFile;
  IOSink? _logSink;
  Timer? _timeoutTimer;
  bool _isActive = false;
  DateTime? _sessionStartTime;
  final List<String> _logBuffer = [];
  static const Duration _maxSessionDuration = Duration(minutes: 15);

  /// Check if logging session is currently active
  bool get isActive => _isActive;

  /// Get the log file path (null if no session active)
  File? get logFile => _logFile;

  /// Get session start time
  DateTime? get sessionStartTime => _sessionStartTime;

  /// Get remaining time in session
  Duration? get remainingTime {
    if (!_isActive || _sessionStartTime == null) return null;
    final elapsed = DateTime.now().difference(_sessionStartTime!);
    final remaining = _maxSessionDuration - elapsed;
    return remaining.isNegative ? Duration.zero : remaining;
  }

  /// Start a logging session
  Future<bool> startSession() async {
    if (_isActive) {
      // Already active, restart it
      await stopSession();
    }

    try {
      final dir = await getApplicationDocumentsDirectory();
      final timestamp = DateTime.now().toIso8601String().replaceAll(':', '-');
      final fileName = 'kitzi-session-log-$timestamp.txt';
      _logFile = File(p.join(dir.path, fileName));
      _logSink = _logFile!.openWrite(mode: FileMode.write);
      _sessionStartTime = DateTime.now();
      _isActive = true;
      _logBuffer.clear();

      // Write session header
      await _write('=== Kitzi Logging Session Started ===');
      await _write('Start Time: ${_sessionStartTime!.toIso8601String()}');
      await _write('Max Duration: ${_maxSessionDuration.inMinutes} minutes');
      await _write('');

      // Set up timeout to auto-stop after 15 minutes
      _timeoutTimer = Timer(_maxSessionDuration, () {
        stopSession();
      });

      // Intercept print statements
      _interceptPrints();

      return true;
    } catch (e) {
      debugPrint('Failed to start logging session: $e');
      await stopSession();
      return false;
    }
  }

  /// Stop the logging session
  Future<void> stopSession() async {
    if (!_isActive) return;

    try {
      if (_sessionStartTime != null) {
        final duration = DateTime.now().difference(_sessionStartTime!);
        await _write('');
        await _write('=== Kitzi Logging Session Ended ===');
        await _write('End Time: ${DateTime.now().toIso8601String()}');
        await _write('Duration: ${duration.inMinutes}m ${duration.inSeconds % 60}s');
      }

      _restorePrints();
      await _logSink?.flush();
      await _logSink?.close();
      _logSink = null;
      _isActive = false;
      _timeoutTimer?.cancel();
      _timeoutTimer = null;
    } catch (e) {
      debugPrint('Error stopping logging session: $e');
    }
  }

  /// Write a log entry
  Future<void> _write(String message) async {
    if (!_isActive || _logSink == null) return;

    try {
      final timestamp = DateTime.now().toIso8601String();
      final entry = '[$timestamp] $message\n';
      _logBuffer.add(entry);
      _logSink!.write(entry);
      await _logSink!.flush();
    } catch (e) {
      debugPrint('Error writing to log file: $e');
    }
  }

  /// Intercept print statements and redirect to log file
  void _interceptPrints() {
    // Note: In Flutter, we can't easily intercept all print statements globally
    // Components should use SessionLoggerService.instance.log() to log messages
    // This ensures logs are captured during the session
  }

  /// Restore original print behavior
  void _restorePrints() {
    // No-op: we're not actually intercepting prints
  }

  /// Log a message (call this from components that want to log)
  Future<void> log(String message) async {
    if (!_isActive) return;
    await _write(message);
  }

  /// Log an error
  Future<void> logError(String message, [Object? error, StackTrace? stackTrace]) async {
    if (!_isActive) return;
    await _write('ERROR: $message');
    if (error != null) {
      await _write('  Error: $error');
    }
    if (stackTrace != null) {
      await _write('  StackTrace: $stackTrace');
    }
  }

  /// Get the log file content as string
  Future<String?> getLogContent() async {
    if (_logFile == null || !await _logFile!.exists()) return null;
    try {
      return await _logFile!.readAsString();
    } catch (e) {
      debugPrint('Error reading log file: $e');
      return null;
    }
  }

  /// Delete the current log file
  Future<void> deleteLogFile() async {
    if (_logFile != null && await _logFile!.exists()) {
      try {
        await _logFile!.delete();
      } catch (e) {
        debugPrint('Error deleting log file: $e');
      }
    }
    _logFile = null;
  }
}

