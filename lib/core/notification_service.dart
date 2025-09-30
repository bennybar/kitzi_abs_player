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
      
      // Create notification channels for Android
      await _createNotificationChannels();
      
      _isInitialized = true;
      
      debugPrint('Notification service initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize notification service: $e');
    }
  }
  
  Future<void> _createNotificationChannels() async {
    try {
      // Create download notification channel with proper settings
      const downloadChannel = AndroidNotificationChannel(
        'kitzi_download_channel',
        'Kitzi Downloads',
        description: 'Download notifications',
        importance: Importance.low,
        playSound: false,
        enableVibration: false,
        showBadge: false,
      );
      
      await _notifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.createNotificationChannel(downloadChannel);
      
      debugPrint('Download notification channel created');
    } catch (e) {
      debugPrint('Failed to create notification channels: $e');
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
        ongoing: true, // Prevents swipe-to-dismiss during download
        autoCancel: false,
        showWhen: false,
        icon: '@drawable/ic_download_notification',
        // Use foreground service category to keep download alive in background
        category: AndroidNotificationCategory.service,
        visibility: NotificationVisibility.public,
        onlyAlertOnce: true,
        // Show initial progress at 0%
        showProgress: true,
        maxProgress: 100,
        progress: 0,
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      );
      const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _notifications.show(
        _downloadNotificationId,
        'Downloading: $title',
        'Starting download...',
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

  Future<void> showDownloadProgress(String title, int progress, int maxProgress, {double? speed}) async {
    if (!_isInitialized) return;
    try {
      final percentage = maxProgress > 0 ? ((progress / maxProgress) * 100).round() : 0;
      
      // Format download speed nicely
      String progressText;
      if (speed != null && speed > 0) {
        final speedStr = _formatSpeed(speed);
        progressText = '$speedStr • $percentage%';
      } else {
        progressText = '$percentage% complete';
      }
      
      final androidDetails = AndroidNotificationDetails(
        'kitzi_download_channel',
        'Kitzi Downloads',
        channelDescription: 'Download notifications',
        importance: Importance.low,
        priority: Priority.low,
        ongoing: true, // Prevents swipe-to-dismiss during download
        autoCancel: false,
        showWhen: false,
        icon: '@drawable/ic_download_notification',
        showProgress: true,
        maxProgress: 100,
        progress: percentage,
        // Use service category to maintain foreground service behavior
        category: AndroidNotificationCategory.service,
        visibility: NotificationVisibility.public,
        onlyAlertOnce: true, // Prevents notification sound/vibration on each update
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: false,
        presentBadge: false,
        presentSound: false,
      );
      final details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _notifications.show(
        _downloadNotificationId,
        'Downloading: $title',
        progressText,
        details,
        payload: 'book_download_progress',
      );
    } catch (e) {
      debugPrint('Failed to show download progress notification: $e');
    }
  }
  
  String _formatSpeed(double bytesPerSecond) {
    if (bytesPerSecond < 1024) {
      return '${bytesPerSecond.toStringAsFixed(0)} B/s';
    } else if (bytesPerSecond < 1024 * 1024) {
      final kbps = bytesPerSecond / 1024;
      return '${kbps.toStringAsFixed(1)} KB/s';
    } else {
      final mbps = bytesPerSecond / (1024 * 1024);
      return '${mbps.toStringAsFixed(2)} MB/s';
    }
  }

  Future<void> showDownloadComplete(String title) async {
    if (!_isInitialized) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'kitzi_download_channel',
        'Kitzi Downloads',
        channelDescription: 'Download notifications',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
        autoCancel: true,
        showWhen: true,
        timeoutAfter: 3500,
        icon: '@drawable/ic_download_notification',
      );
      const iosDetails = DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: false,
        presentSound: false,
      );
      const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _notifications.show(
        2002,
        'Download complete',
        title,
        details,
        payload: 'book_download_complete',
      );
    } catch (e) {
      debugPrint('Failed to show download complete notification: $e');
    }
  }
}
