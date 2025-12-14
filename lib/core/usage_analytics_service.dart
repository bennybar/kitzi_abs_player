// lib/core/usage_analytics_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Service for tracking daily active users (DAU)
/// Sends a single event per device per day to the analytics endpoint
class UsageAnalyticsService {
  static const String _lastActiveDateKey = 'usage_last_active_date';
  static const String _analyticsEndpoint = 'https://customapi.kenes.com/listenedabs/ovrmyte2590254nm7y698n28v0jm';
  
  /// Track daily active user (call on app start)
  /// Only sends once per device per day
  static Future<void> trackDailyActive() async {
    try {
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] Starting daily active tracking...');
      }
      
      final prefs = await SharedPreferences.getInstance();
      final today = _getTodayDateString();
      final lastActive = prefs.getString(_lastActiveDateKey);
      
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] Today: $today, Last active: $lastActive');
      }
      
      // Only send if this is a new day (or first time)
      if (lastActive != today) {
        if (kDebugMode) {
          debugPrint('[UsageAnalytics] New day detected, tracking...');
        }
        
        // Mark today as tracked BEFORE sending (optimistic update)
        await prefs.setString(_lastActiveDateKey, today);
        
        // Send to analytics endpoint
        await _sendDailyActiveEvent(today);
      } else {
        if (kDebugMode) {
          debugPrint('[UsageAnalytics] Already tracked today, skipping');
        }
      }
    } catch (e) {
      // Fail silently - don't break app if analytics fails
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] Failed to track daily active: $e');
      }
    }
  }
  
  /// Get today's date as YYYY-MM-DD string
  static String _getTodayDateString() {
    final now = DateTime.now().toUtc();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }
  
  /// Send daily active event to analytics endpoint
  static Future<void> _sendDailyActiveEvent(String date) async {
    try {
      final timestamp = DateTime.now().toUtc().toIso8601String();
      
      // Prepare data to send
      final data = {
        'date': date,
        'timestamp': timestamp,
        'event': 'daily_active',
      };
      
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] Sending to $_analyticsEndpoint');
        debugPrint('[UsageAnalytics] Data: $data');
      }
      
      // Send POST request
      final response = await http.post(
        Uri.parse(_analyticsEndpoint),
        headers: {
          'Content-Type': 'application/json',
        },
        body: jsonEncode(data),
      ).timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          if (kDebugMode) {
            debugPrint('[UsageAnalytics] Request timeout after 10 seconds');
          }
          throw Exception('Analytics request timeout');
        },
      );
      
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] Response status: ${response.statusCode}');
        debugPrint('[UsageAnalytics] Response body: ${response.body}');
        if (response.statusCode == 200) {
          debugPrint('[UsageAnalytics] ✅ Daily active tracked successfully for $date');
        } else {
          debugPrint('[UsageAnalytics] ❌ Failed to track: ${response.statusCode}');
        }
      }
    } catch (e, stackTrace) {
      // Fail silently - analytics should never break the app
      if (kDebugMode) {
        debugPrint('[UsageAnalytics] ❌ Error sending event: $e');
        debugPrint('[UsageAnalytics] Stack trace: $stackTrace');
      }
    }
  }
  
  /// Get the last date this device was tracked (for debugging)
  static Future<String?> getLastTrackedDate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getString(_lastActiveDateKey);
    } catch (_) {
      return null;
    }
  }
  
  /// Reset tracking (for testing purposes)
  static Future<void> resetTracking() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_lastActiveDateKey);
    } catch (_) {
      // Ignore errors
    }
  }
}

