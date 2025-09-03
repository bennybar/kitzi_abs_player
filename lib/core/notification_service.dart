import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static NotificationService? _instance;
  static NotificationService get instance => _instance ??= NotificationService._();
  
  NotificationService._();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _isInitialized = false;
  static const int _downloadNotificationId = 2001;

  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      // Initialize Android settings
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      
      // Initialize iOS settings
      const iosSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );

      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: iosSettings,
      );

      await _notifications.initialize(initSettings);
      _isInitialized = true;
      
      debugPrint('Notification service initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize notification service: $e');
    }
  }

  Future<void> showMediaNotification({
    required String title,
    required String author,
    required String? coverUrl,
    required bool isPlaying,
    required Duration position,
    Duration? duration,
    double speed = 1.0,
  }) async {
    if (!_isInitialized) return;

    try {
      const androidDetails = AndroidNotificationDetails(
        'kitzi_media_channel',
        'Kitzi Media',
        channelDescription: 'Media playback notifications',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
        enableVibration: false,
        enableLights: false,
        playSound: false,
        category: AndroidNotificationCategory.service,
        visibility: NotificationVisibility.public,
        actions: [
          AndroidNotificationAction('prev', 'Previous'),
          AndroidNotificationAction('play_pause', 'Play/Pause'),
          AndroidNotificationAction('next', 'Next'),
        ],
      );

      const iosDetails = DarwinNotificationDetails(
        categoryIdentifier: 'media_controls',
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      );

      const details = NotificationDetails(
        android: androidDetails,
        iOS: iosDetails,
      );

      await _notifications.show(
        1001, // Media notification ID
        title,
        author,
        details,
        payload: 'media_playback',
      );
    } catch (e) {
      debugPrint('Failed to show media notification: $e');
    }
  }

  Future<void> hideMediaNotification() async {
    if (!_isInitialized) return;
    
    try {
      await _notifications.cancel(1001);
    } catch (e) {
      debugPrint('Failed to hide media notification: $e');
    }
  }

  Future<void> updateMediaNotification({
    required String title,
    required String author,
    required bool isPlaying,
    required Duration position,
    Duration? duration,
    double speed = 1.0,
  }) async {
    if (!_isInitialized) return;

    try {
      await showMediaNotification(
        title: title,
        author: author,
        coverUrl: null, // Keep existing cover
        isPlaying: isPlaying,
        position: position,
        duration: duration,
        speed: speed,
      );
    } catch (e) {
      debugPrint('Failed to update media notification: $e');
    }
  }

  Future<void> dispose() async {
    if (_isInitialized) {
      await hideMediaNotification();
      _isInitialized = false;
    }
  }

  // Simple one-shot download notification that appears once when a book starts
  // downloading and is dismissed when the book completes.
  Future<void> showDownloadStarted(String title) async {
    if (!_isInitialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'kitzi_download_channel',
        'Kitzi Downloads',
        channelDescription: 'Download notifications',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true,
        autoCancel: false,
        showWhen: false,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      );
      const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _notifications.show(
        _downloadNotificationId,
        'Downloading book: $title',
        null,
        details,
        payload: 'book_download',
      );
    } catch (e) {
      debugPrint('Failed to show download notification: $e');
    }
  }

  Future<void> hideDownloadNotification() async {
    if (!_isInitialized) return;
    try {
      await _notifications.cancel(_downloadNotificationId);
    } catch (e) {
      debugPrint('Failed to hide download notification: $e');
    }
  }
}
