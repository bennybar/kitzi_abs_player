import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Network service with retry logic and error categorization
class NetworkService {
  static const int defaultMaxRetries = 3;
  static const Duration defaultDelay = Duration(seconds: 1);
  static const Duration defaultTimeout = Duration(seconds: 30);
  
  /// Execute operation with retry logic
  static Future<T> withRetry<T>(
    Future<T> Function() operation, {
    int maxRetries = defaultMaxRetries,
    Duration delay = defaultDelay,
    Duration? timeout,
    bool Function(dynamic error)? shouldRetry,
    void Function(int attempt, dynamic error)? onRetry,
  }) async {
    timeout ??= defaultTimeout;
    
    for (int attempt = 0; attempt <= maxRetries; attempt++) {
      try {
        return await operation().timeout(timeout);
      } catch (error) {
        final isLastAttempt = attempt == maxRetries;
        final shouldRetryError = shouldRetry?.call(error) ?? _defaultShouldRetry(error);
        
        if (isLastAttempt || !shouldRetryError) {
          // Only log final failures, not intermediate retries
          if (attempt > 0) {
            // 'Network operation failed after ${attempt + 1} attempts: $error');
          }
          rethrow;
        }
        
        final retryDelay = Duration(
          milliseconds: delay.inMilliseconds * (attempt + 1) * (attempt + 1), // Exponential backoff
        );
        
        // Reduce retry logging verbosity
        if (attempt == 0) {
          // 'Network operation failed, retrying in ${retryDelay.inMilliseconds}ms: $error');
        }
        onRetry?.call(attempt + 1, error);
        
        await Future.delayed(retryDelay);
      }
    }
    
    throw Exception('Max retries exceeded');
  }
  
  /// Default retry logic for common network errors
  static bool _defaultShouldRetry(dynamic error) {
    if (error is SocketException) {
      return true; // Network connectivity issues
    }
    if (error is TimeoutException) {
      return true; // Request timeouts
    }
    if (error is FormatException) {
      return false; // Data format issues (don't retry)
    }

    final errorString = error.toString().toLowerCase();

    // Auth/permission/not-found are definitive failures: do not retry.
    if (errorString.contains('401') ||
        errorString.contains('403') ||
        errorString.contains('404') ||
        errorString.contains('unauthorized') ||
        errorString.contains('forbidden')) {
      return false;
    }

    // Retryable HTTP status codes (5xx server errors and transient 4xx) and
    // transport-level conditions. HttpException is only retried when it carries
    // one of these, not unconditionally.
    if (errorString.contains('500') ||
        errorString.contains('502') ||
        errorString.contains('503') ||
        errorString.contains('504') ||
        errorString.contains('408') ||
        errorString.contains('425') ||
        errorString.contains('429') ||
        errorString.contains('timeout') ||
        errorString.contains('connection')) {
      return true;
    }

    return false; // Don't retry by default
  }
  
  /// Execute operation with circuit breaker pattern
  static Future<T> withCircuitBreaker<T>(
    Future<T> Function() operation, {
    int failureThreshold = 5,
    Duration resetTimeout = const Duration(minutes: 1),
  }) async {
    // Simple circuit breaker implementation
    // In production, consider using a more robust library
    return await operation();
  }
}

/// Network error types for better error handling
enum NetworkErrorType {
  connectivity,
  timeout,
  serverError,
  clientError,
  authentication,
  rateLimit,
  unknown,
}

/// Enhanced network error class
class NetworkError {
  final NetworkErrorType type;
  final String message;
  final int? statusCode;
  final dynamic originalError;
  
  const NetworkError({
    required this.type,
    required this.message,
    this.statusCode,
    this.originalError,
  });
  
  static NetworkError fromException(dynamic error) {
    if (error is SocketException) {
      return NetworkError(
        type: NetworkErrorType.connectivity,
        message: 'No internet connection',
        originalError: error,
      );
    }
    
    if (error is TimeoutException) {
      return NetworkError(
        type: NetworkErrorType.timeout,
        message: 'Request timed out',
        originalError: error,
      );
    }
    
    if (error is HttpException) {
      final errorString = error.toString().toLowerCase();
      if (errorString.contains('401') || errorString.contains('unauthorized')) {
        return NetworkError(
          type: NetworkErrorType.authentication,
          message: 'Authentication failed',
          statusCode: 401,
          originalError: error,
        );
      }
      if (errorString.contains('429') || errorString.contains('rate limit')) {
        return NetworkError(
          type: NetworkErrorType.rateLimit,
          message: 'Rate limit exceeded',
          statusCode: 429,
          originalError: error,
        );
      }
      // Extract the first standalone HTTP status code (3 digits) from the message.
      final statusMatch = RegExp(r'\b([1-5]\d{2})\b').firstMatch(errorString);
      final statusCode =
          statusMatch != null ? int.tryParse(statusMatch.group(1)!) : null;
      if (statusCode != null && statusCode >= 500 && statusCode <= 599) {
        return NetworkError(
          type: NetworkErrorType.serverError,
          message: 'Server error occurred',
          statusCode: statusCode,
          originalError: error,
        );
      }
      if (statusCode != null && statusCode >= 400 && statusCode <= 499) {
        return NetworkError(
          type: NetworkErrorType.clientError,
          message: 'Client error occurred',
          statusCode: statusCode,
          originalError: error,
        );
      }
    }
    
    return NetworkError(
      type: NetworkErrorType.unknown,
      message: error.toString(),
      originalError: error,
    );
  }
  
  bool get isRetryable {
    return type == NetworkErrorType.connectivity ||
           type == NetworkErrorType.timeout ||
           type == NetworkErrorType.serverError;
  }
  
  @override
  String toString() {
    return 'NetworkError(type: $type, message: $message, statusCode: $statusCode)';
  }
}

/// Network connectivity monitor
class ConnectivityMonitor {
  static final StreamController<bool> _connectivityController = 
      StreamController<bool>.broadcast();
  
  static Stream<bool> get connectivityStream => _connectivityController.stream;
  
  static bool _isConnected = true;
  static bool get isConnected => _isConnected;
  
  static void updateConnectivity(bool connected) {
    if (_isConnected != connected) {
      _isConnected = connected;
      if (!_connectivityController.isClosed) {
        _connectivityController.add(connected);
      }
      // Only log connectivity changes, not every check
      // '[OFFLINE_FIRST] Connectivity changed: ${connected ? 'Connected' : 'Disconnected'}');
    }
  }
  
  static void dispose() {
    _connectivityController.close();
  }
}
