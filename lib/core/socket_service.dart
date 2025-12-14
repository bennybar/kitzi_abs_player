// lib/core/socket_service.dart
import 'dart:async';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';

/// Socket.io service for real-time updates from Audiobookshelf server
class SocketService {
  static SocketService? _instance;
  static SocketService get instance {
    _instance ??= SocketService._();
    return _instance!;
  }

  SocketService._();

  IO.Socket? _socket;
  bool _connected = false;
  bool _isAuthenticated = false;
  String? _serverAddress;
  DateTime? _lastReconnectAttempt;
  
  final StreamController<bool> _connectionController = StreamController<bool>.broadcast();
  final StreamController<Map<String, dynamic>> _userUpdatedController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<Map<String, dynamic>> _progressUpdatedController = StreamController<Map<String, dynamic>>.broadcast();
  final StreamController<void> _playlistAddedController = StreamController<void>.broadcast();

  /// Stream of connection status changes
  Stream<bool> get connectionStream => _connectionController.stream;
  
  /// Stream of user update events
  Stream<Map<String, dynamic>> get userUpdatedStream => _userUpdatedController.stream;
  
  /// Stream of progress update events from other devices
  Stream<Map<String, dynamic>> get progressUpdatedStream => _progressUpdatedController.stream;
  
  /// Stream of playlist added events
  Stream<void> get playlistAddedStream => _playlistAddedController.stream;

  bool get isConnected => _connected;
  bool get isAuthenticated => _isAuthenticated;

  /// Connect to server Socket.io endpoint
  Future<void> connect(String serverAddress, String? accessToken) async {
    if (_socket != null && _connected) {
      debugPrint('[SOCKET] Already connected, disconnecting first');
      await disconnect();
    }

    _serverAddress = serverAddress;
    
    try {
      final serverUrl = Uri.parse(serverAddress);
      final serverHost = '${serverUrl.scheme}://${serverUrl.host}';
      final serverPath = serverUrl.path == '/' ? '' : serverUrl.path;

      debugPrint('[SOCKET] Connecting to $serverHost with path $serverPath/socket.io');

      _socket = IO.io(
        serverHost,
        IO.OptionBuilder()
            .setTransports(['websocket'])
            .setPath('$serverPath/socket.io')
            .setReconnectionDelayMax(15000)
            .setTimeout(20000)
            .build(),
      );

      _setupSocketListeners(accessToken);
    } catch (e) {
      debugPrint('[SOCKET] Connection error: $e');
      _connectionController.add(false);
    }
  }

  void _setupSocketListeners(String? accessToken) {
    if (_socket == null) return;

    _socket!.onConnect((_) {
      debugPrint('[SOCKET] Socket Connected ${_socket!.id}');
      _connected = true;
      _connectionController.add(true);
      
      // Authenticate immediately after connection
      if (accessToken != null) {
        _sendAuthenticate(accessToken);
      }
    });

    _socket!.onDisconnect((reason) {
      debugPrint('[SOCKET] Socket Disconnected: $reason');
      _connected = false;
      _isAuthenticated = false;
      _connectionController.add(false);
    });

    _socket!.on('init', (data) {
      debugPrint('[SOCKET] Initial socket data received: $data');
      _isAuthenticated = true;
    });

    _socket!.on('auth_failed', (data) {
      debugPrint('[SOCKET] Auth failed: $data');
      _isAuthenticated = false;
    });

    _socket!.on('user_updated', (data) {
      debugPrint('[SOCKET] User updated: $data');
      if (data is Map<String, dynamic>) {
        _userUpdatedController.add(data);
      }
    });

    _socket!.on('user_item_progress_updated', (data) {
      debugPrint('[SOCKET] User Item Progress Updated: $data');
      if (data is Map<String, dynamic> && data['data'] is Map<String, dynamic>) {
        _progressUpdatedController.add(data['data'] as Map<String, dynamic>);
      }
    });

    _socket!.on('playlist_added', (_) {
      debugPrint('[SOCKET] Playlist added');
      _playlistAddedController.add(null);
    });

    _socket!.onError((error) {
      debugPrint('[SOCKET] Socket error: $error');
    });

    // Handle reconnection events via socket's event system
    // Note: socket_io_client may handle reconnection automatically via the OptionBuilder settings
    // These events are logged for debugging but may not be available in all versions
    try {
      // Try to listen for reconnection events if available
      _socket!.on('reconnect_attempt', (attemptNumber) {
        final now = DateTime.now();
        final timeSinceLastAttempt = _lastReconnectAttempt != null
            ? now.difference(_lastReconnectAttempt!).inMilliseconds
            : 0;
        _lastReconnectAttempt = now;
        debugPrint('[SOCKET] Reconnect attempt $attemptNumber ${timeSinceLastAttempt > 0 ? 'after ${timeSinceLastAttempt}ms' : ''}');
      });

      _socket!.on('reconnect_error', (error) {
        debugPrint('[SOCKET] Reconnect error: $error');
      });

      _socket!.on('reconnect_failed', (_) {
        debugPrint('[SOCKET] Reconnect failed');
      });
    } catch (e) {
      // Reconnection events may not be available in this version
      debugPrint('[SOCKET] Reconnection event handlers not available: $e');
    }
  }

  void _sendAuthenticate(String accessToken) {
    if (_socket == null || !_connected) {
      debugPrint('[SOCKET] Cannot authenticate: socket not connected');
      return;
    }
    debugPrint('[SOCKET] Sending authentication');
    _socket!.emit('auth', accessToken);
  }

  /// Re-authenticate with new token (e.g., after token refresh)
  void reauthenticate(String accessToken) {
    if (_socket != null && _connected && !_isAuthenticated) {
      _sendAuthenticate(accessToken);
    }
  }

  /// Disconnect from server
  Future<void> disconnect() async {
    if (_socket != null) {
      debugPrint('[SOCKET] Disconnecting');
      _socket!.disconnect();
      _socket!.dispose();
      _socket = null;
    }
    _connected = false;
    _isAuthenticated = false;
    _serverAddress = null;
    _connectionController.add(false);
  }

  /// Cleanup resources
  void dispose() {
    disconnect();
    _connectionController.close();
    _userUpdatedController.close();
    _progressUpdatedController.close();
    _playlistAddedController.close();
  }
}

