import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
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

    // Trust a comfortably-fresh access token without a network round-trip.
    // This check runs frequently (e.g. the 2-min foreground auth poll), so
    // hitting /auth/refresh every time would wake the radio and rotate tokens
    // pointlessly. ApiClient.request() already refreshes on a real 401, which
    // is the authoritative backstop for a token revoked/expired between checks.
    if (_api.hasFreshAccessToken(leewaySeconds: 300)) {
      return true;
    }

    // Token is near/past its assumed expiry — refresh authoritatively now.
    final ok = await _api.refreshAccessToken();
    if (ok) {
      return true;
    }

    // Refresh failed (e.g. offline or no refresh token). Fall back to trusting a
    // still-fresh access token so we can degrade gracefully rather than force a
    // logout on a transient/network failure.
    return _api.hasFreshAccessToken(leewaySeconds: 60);
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

  // ===== OpenID Connect (SSO) =====

  // Transient PKCE/session state held between [openIdBegin] and [openIdFinish].
  String? _oidcVerifier;
  String? _oidcState;
  String? _oidcCookies;

  /// The auth methods the server advertises (e.g. `['local','openid']`).
  Future<List<String>> serverAuthMethods(String baseUrl) async {
    try {
      final s = await _api.publicStatus(baseUrl);
      final m = s['authMethods'];
      if (m is List) return m.map((e) => e.toString()).toList();
    } catch (_) {}
    return const [];
  }

  /// Full unauthenticated status (for the OIDC button text, etc.).
  Future<Map<String, dynamic>> serverStatus(String baseUrl) async {
    try {
      return await _api.publicStatus(baseUrl);
    } catch (_) {
      return const {};
    }
  }

  /// Begin SSO: generate PKCE, hit `/auth/openid`, and return the IdP authorize
  /// URL to open in a browser. Returns null on failure.
  Future<String?> openIdBegin({
    required String baseUrl,
    required String redirectUri,
  }) async {
    final verifier = _randomUrlSafe(64);
    final challenge =
        base64Url.encode(sha256.convert(ascii.encode(verifier)).bytes)
            .replaceAll('=', '');
    final state = _randomUrlSafe(16);
    final res = await _api.openIdStart(
      baseUrl: baseUrl,
      redirectUri: redirectUri,
      codeChallenge: challenge,
      state: state,
    );
    if (res == null) return null;
    _oidcVerifier = verifier;
    _oidcState = state;
    _oidcCookies = res.cookies;
    return res.authUrl;
  }

  /// Finish SSO after the browser returns the custom-scheme [callbackUrl].
  /// Verifies state, exchanges the code, and stores tokens. Returns true on
  /// success.
  Future<bool> openIdFinish({
    required String baseUrl,
    required String callbackUrl,
  }) async {
    final verifier = _oidcVerifier;
    final state = _oidcState;
    final cookies = _oidcCookies ?? '';
    try {
      if (verifier == null || state == null) return false;
      final uri = Uri.tryParse(callbackUrl);
      final code = uri?.queryParameters['code'];
      final returnedState = uri?.queryParameters['state'];
      if (code == null || returnedState != state) return false;
      return await _api.openIdComplete(
        baseUrl: baseUrl,
        code: code,
        state: state,
        codeVerifier: verifier,
        cookies: cookies,
      );
    } finally {
      _oidcVerifier = null;
      _oidcState = null;
      _oidcCookies = null;
    }
  }

  String _randomUrlSafe(int bytes) {
    final rnd = Random.secure();
    final b = List<int>.generate(bytes, (_) => rnd.nextInt(256));
    return base64Url.encode(b).replaceAll('=', '');
  }
}
