import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'package:flutter/foundation.dart';

/// AuthRepository
/// -------------------------
/// - Singleton: use `await AuthRepository.ensure()` at startup
/// - Persists/refreshes tokens via ApiClient
/// - Exposes simple `login`, `logout`, `hasValidSession`
class AuthRepository {
  AuthRepository._(this._prefs, this._secure) : _api = ApiClient(_prefs, _secure);

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
  }) {
    return _api.login(baseUrl: baseUrl, username: username, password: password);
  }

  Future<void> logout() => _api.logout();

  ApiClient get api => _api;
}
