import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'socket_service.dart';
import 'package:flutter/foundation.dart';

/// AuthRepository
/// -------------------------
/// - Singleton: use `await AuthRepository.ensure()` at startup
/// - Persists/refreshes tokens via ApiClient
/// - Exposes simple `login`, `logout`, `hasValidSession`
class AuthRepository {
  AuthRepository._(this._prefs, this._secure) : _api = ApiClient(_prefs, _secure) {
    // Set up token refresh callback for socket re-authentication
    _api.onTokenRefreshed = (newToken) {
      SocketService.instance.reauthenticate(newToken);
    };
  }

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  late final ApiClient _api;

  static AuthRepository? _instanceInternal;

  /// Access the initialized singleton.
  /// Make sure to call `await AuthRepository.ensure()` first.
  static AuthRepository get instance {
    final inst = _instanceInternal;
    if (inst == null) {
      throw StateError('AuthRepository not initialized. Call AuthRepository.ensure() first.');
    }
    return inst;
  }

  /// Initialize (or return existing) singleton.
  static Future<AuthRepository> ensure() async {
    if (_instanceInternal != null) return _instanceInternal!;
    final prefs = await SharedPreferences.getInstance();
    const secure = FlutterSecureStorage();
    _instanceInternal = AuthRepository._(prefs, secure);
    return _instanceInternal!;
  }

  /// Returns true if we have a base URL + refresh token and a refresh succeeds.
  Future<bool> hasValidSession() async {
    if (_api.baseUrl == null) {
      return false;
    }
    
    // Trust non-expired access tokens first to avoid forcing refresh on every launch
    if (_api.hasFreshAccessToken(leewaySeconds: 60)) {
      return true;
    }
    
    // Check if we have a refresh token before attempting refresh
    // We'll let the refresh method handle this check internally
    
    // Otherwise try refresh
    final ok = await _api.refreshAccessToken();
    return ok;
  }

  Future<bool> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final success = await _api.login(baseUrl: baseUrl, username: username, password: password);
    if (success) {
      // Connect socket after successful login
      final token = await _api.accessToken();
      if (token != null && baseUrl.isNotEmpty) {
        try {
          await SocketService.instance.connect(baseUrl, token);
        } catch (e) {
          debugPrint('[AUTH] Failed to connect socket after login: $e');
          // Don't fail login if socket connection fails
        }
      }
    }
    return success;
  }

  Future<void> logout() async {
    // Disconnect socket before logout
    try {
      await SocketService.instance.disconnect();
    } catch (e) {
      debugPrint('[AUTH] Error disconnecting socket during logout: $e');
    }
    await _api.logout();
  }

  ApiClient get api => _api;
}
