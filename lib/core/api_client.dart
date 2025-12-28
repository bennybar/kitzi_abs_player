import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'session_logger_service.dart';

class ApiClient {
  ApiClient(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;
  static const String _customHeadersKey = 'abs_custom_headers';
  Map<String, String>? _customHeadersCache;

  String? get baseUrl => _prefs.getString('abs_base_url');

  Future<void> setBaseUrl(String url) async {
    final original = url;
    url = url.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    url = url.replaceAll(RegExp(r'/+$'), '');
    // '[API] setBaseUrl: input="$original" -> stored="$url"');
    await _prefs.setString('abs_base_url', url);
  }

  /// Custom header management (used for Zero-Trust tunnels/service tokens)
  Map<String, String> get customHeaders =>
      Map<String, String>.from(_currentCustomHeaders());

  Future<void> setCustomHeaders(Map<String, String> headers) async {
    final sanitized = <String, String>{};
    headers.forEach((key, value) {
      final k = key.trim();
      final v = value.trim();
      if (k.isEmpty || v.isEmpty) return;
      sanitized[k] = v;
    });

    if (sanitized.isEmpty) {
      await _prefs.remove(_customHeadersKey);
      _customHeadersCache = const <String, String>{};
    } else {
      await _prefs.setString(_customHeadersKey, jsonEncode(sanitized));
      _customHeadersCache = Map<String, String>.unmodifiable(sanitized);
    }
  }

  Map<String, String> _currentCustomHeaders() {
    final cache = _customHeadersCache;
    if (cache != null) return cache;
    final decoded = _decodeCustomHeaders(_prefs.getString(_customHeadersKey));
    final frozen = Map<String, String>.unmodifiable(decoded);
    _customHeadersCache = frozen;
    return frozen;
  }

  Map<String, String> _decodeCustomHeaders(String? raw) {
    if (raw == null || raw.isEmpty) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final result = <String, String>{};
        decoded.forEach((key, value) {
          final k = key.toString().trim();
          final v = value == null ? '' : value.toString().trim();
          if (k.isEmpty || v.isEmpty) return;
          result[k] = v;
        });
        return result;
      }
    } catch (_) {}
    return const <String, String>{};
  }

  // === Access/Refresh storage ===
  Future<String?> _getAccessToken() async => _prefs.getString('abs_access');
  Future<void> _setAccessToken(String token, DateTime expiry) async {
    await _prefs.setString('abs_access', token);
    await _prefs.setString('abs_access_exp', expiry.toIso8601String());
  }
  DateTime? _getAccessExpiry() {
    final s = _prefs.getString('abs_access_exp');
    return s != null ? DateTime.tryParse(s) : null;
  }
  Future<String?> _getRefreshToken() => _secure.read(key: 'abs_refresh');
  Future<void> _setRefreshToken(String token) =>
      _secure.write(key: 'abs_refresh', value: token);

  /// Public helper: get current access token (nullable).
  Future<String?> accessToken() => _getAccessToken();
  /// Public helper: get access token expiry (nullable UTC timestamp string parsed to DateTime).
  DateTime? accessTokenExpiry() => _getAccessExpiry();
  /// Public helper: true if we have a non-expired access token with optional leeway seconds.
  bool hasFreshAccessToken({int leewaySeconds = 60}) {
    final exp = _getAccessExpiry();
    if (exp == null) return false;
    return exp.isAfter(DateTime.now().toUtc().add(Duration(seconds: leewaySeconds)));
  }

  Future<void> clearTokens() async {
    await _prefs.remove('abs_access');
    await _prefs.remove('abs_access_exp');
    await _secure.delete(key: 'abs_refresh');
  }

  // === Requests with auto-refresh ===
  Future<http.Response> request(
      String method,
      String path, {
        Map<String, String>? headers,
        Object? body,
        bool auth = true,
      }) async {
    final base = baseUrl;
    if (base == null) throw Exception('Base URL not set');
    if (auth) {
      await _ensureAccessValid();
    }

    final uri = Uri.parse('$base$path');
    final reqHeaders = <String, String>{
      'Content-Type': 'application/json',
      'User-Agent': 'Kitzi-ABS-Player/1.0 (Flutter)',
      ..._currentCustomHeaders(),
      ...?headers,
    };

    if (auth) {
      final access = await _getAccessToken();
      if (access != null) reqHeaders['Authorization'] = 'Bearer $access';
    }

    Future<http.Response> send(String m) async {
      switch (m) {
        case 'GET':
          return http.get(uri, headers: reqHeaders);
        case 'POST':
          return http.post(uri, headers: reqHeaders, body: body as String?);
        case 'DELETE':
          return http.delete(uri, headers: reqHeaders, body: body as String?);
        case 'PUT':
          return http.put(uri, headers: reqHeaders, body: body as String?);
        case 'PATCH':
          return http.patch(uri, headers: reqHeaders, body: body as String?);
        default:
          throw UnimplementedError(m);
      }
    }

    var upper = method.toUpperCase();
    
    // Log request if logging session is active
    final logger = SessionLoggerService.instance;
    if (logger.isActive) {
      final sanitizedHeaders = Map<String, String>.from(reqHeaders);
      if (sanitizedHeaders.containsKey('Authorization')) {
        final authValue = sanitizedHeaders['Authorization']!;
        if (authValue.startsWith('Bearer ')) {
          sanitizedHeaders['Authorization'] = 'Bearer [REDACTED]';
        }
      }
      await logger.log('HTTP REQUEST: $upper $uri');
      await logger.log('  Headers: ${jsonEncode(sanitizedHeaders)}');
      if (body != null) {
        final bodyStr = body.toString();
        final bodyPreview = bodyStr.length > 1000 ? '${bodyStr.substring(0, 1000)}...[truncated ${bodyStr.length - 1000} chars]' : bodyStr;
        await logger.log('  Body: $bodyPreview');
      }
    }
    
    var resp = await send(upper);

    if (auth && resp.statusCode == 401) {
      if (logger.isActive) {
        await logger.log('HTTP 401 Unauthorized - attempting token refresh');
      }
      final refreshed = await _refreshAccessToken();
      if (refreshed) {
        final retryHeaders = Map<String, String>.from(reqHeaders);
        retryHeaders['Authorization'] = 'Bearer ${await _getAccessToken()}';
        resp = await send(upper);
        if (logger.isActive) {
          await logger.log('HTTP REQUEST RETRY: $upper $uri (after token refresh)');
        }
      }
    }
    
    // Log response if logging session is active
    if (logger.isActive) {
      final respBody = resp.body;
      final respBodyPreview = respBody.length > 2000 
          ? '${respBody.substring(0, 2000)}...[truncated ${respBody.length - 2000} chars]' 
          : respBody;
      await logger.log('HTTP RESPONSE: $upper $uri');
      await logger.log('  Status: ${resp.statusCode} ${resp.reasonPhrase}');
      await logger.log('  Headers: ${jsonEncode(resp.headers)}');
      await logger.log('  Body: $respBodyPreview');
    }
    
    return resp;
  }

  Future<void> _ensureAccessValid() async {
    final exp = _getAccessExpiry();
    if (exp == null) return;
    final now = DateTime.now().toUtc();
    if (exp.isBefore(now.add(const Duration(seconds: 60)))) {
      await _refreshAccessToken();
    }
  }

  Future<bool> _refreshAccessToken() async {
    final logger = SessionLoggerService.instance;
    final base = baseUrl;
    final refresh = await _getRefreshToken();
    if (base == null || refresh == null) {
      if (logger.isActive) {
        await logger.log('TOKEN REFRESH: Failed - missing baseUrl or refresh token');
      }
      return false;
    }

    try {
      final refreshHeaders = <String, String>{
        'Content-Type': 'application/json',
        'User-Agent': 'Kitzi-ABS-Player/1.0 (Flutter)',
        ..._currentCustomHeaders(),
      };
      
      if (logger.isActive) {
        final sanitizedHeaders = Map<String, String>.from(refreshHeaders);
        sanitizedHeaders['x-refresh-token'] = '[REDACTED]';
        await logger.log('TOKEN REFRESH REQUEST: POST $base/auth/refresh');
        await logger.log('  Headers: ${jsonEncode(sanitizedHeaders)}');
      }
      
      refreshHeaders['x-refresh-token'] = refresh;
      final resp = await http.post(
        Uri.parse('$base/auth/refresh'),
        headers: refreshHeaders,
      );
      
      if (logger.isActive) {
        await logger.log('TOKEN REFRESH RESPONSE: Status ${resp.statusCode}');
        if (resp.statusCode != 200) {
          await logger.log('  Body: ${resp.body}');
        }
      }
      
      if (resp.statusCode != 200) {
        return false;
      }

      final data = jsonDecode(resp.body);
      final user = data['user'] as Map<String, dynamic>?;
      final access = user?['accessToken'] as String?;
      final newRefresh = user?['refreshToken'] as String?;
      
      if (access == null) {
        if (logger.isActive) {
          await logger.log('TOKEN REFRESH: Failed - no access token in response');
        }
        return false;
      }

      final assumedExpiry = DateTime.now().toUtc().add(const Duration(hours: 12));
      await _setAccessToken(access, assumedExpiry);
      if (newRefresh != null && newRefresh.isNotEmpty) {
        await _setRefreshToken(newRefresh);
      }
      
      if (logger.isActive) {
        await logger.log('TOKEN REFRESH: Success');
      }
      return true;
    } catch (e) {
      if (logger.isActive) {
        await logger.logError('TOKEN REFRESH: Failed', e);
      }
      return false;
    }
  }

  Future<bool> refreshAccessToken() => _refreshAccessToken();

  Future<bool> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    final logger = SessionLoggerService.instance;
    await setBaseUrl(baseUrl);
    final loginUrl = '$baseUrl/login';
    
    if (logger.isActive) {
      await logger.log('LOGIN REQUEST: POST $loginUrl');
      await logger.log('  Username: $username');
      await logger.log('  HasPassword: ${password.isNotEmpty}');
    }
    
    http.Response resp;
    try {
      final loginHeaders = <String, String>{
        'Content-Type': 'application/json',
        'User-Agent': 'Kitzi-ABS-Player/1.0 (Flutter)',
        ..._currentCustomHeaders(),
      };
      loginHeaders['x-return-tokens'] = 'true';
      
      if (logger.isActive) {
        await logger.log('  Headers: ${jsonEncode(loginHeaders)}');
      }
      
      resp = await http.post(
        Uri.parse(loginUrl),
        headers: loginHeaders,
        body: jsonEncode({'username': username, 'password': password}),
      );
      
      if (logger.isActive) {
        await logger.log('LOGIN RESPONSE: Status ${resp.statusCode}');
        await logger.log('  Body length: ${resp.body.length}');
        if (resp.statusCode != 200) {
          await logger.log('  Body: ${resp.body}');
        }
      }
    } catch (e) {
      if (logger.isActive) {
        await logger.logError('LOGIN: Network error', e);
      }
      return false;
    }

    if (resp.statusCode != 200) return false;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(resp.body) as Map<String, dynamic>;
    } catch (e) {
      // '[API] login: JSON decode error: $e');
      return false;
    }
    final user = data['user'] as Map<String, dynamic>?;
    final access = user?['accessToken'] as String?;
    final refresh = user?['refreshToken'] as String?;
    // Some servers may return tokens at top-level instead of nested user
    final topLevelAccess = data['accessToken'] as String?;
    final topLevelRefresh = data['refreshToken'] as String?;
    final chosenAccess = access ?? topLevelAccess;
    final chosenRefresh = refresh ?? topLevelRefresh;
    // '[API] login: tokens present -> access=${chosenAccess != null} refresh=${chosenRefresh != null}');
    if (chosenAccess == null) return false;

    final assumedExpiry = DateTime.now().toUtc().add(
      (chosenRefresh == null || chosenRefresh.isEmpty)
          ? const Duration(hours: 1)
          : const Duration(hours: 12),
    );
    await _setAccessToken(chosenAccess, assumedExpiry);
    if (chosenRefresh != null && chosenRefresh.isNotEmpty) {
      await _setRefreshToken(chosenRefresh);
    }
    return true;
  }

  Future<void> logout() async {
    final base = baseUrl;
    final refresh = await _getRefreshToken();
    try {
      if (base != null && refresh != null) {
        await http.post(
          Uri.parse('$base/logout'),
          headers: {
            'Content-Type': 'application/json',
            ..._currentCustomHeaders(),
            'x-refresh-token': refresh,
          },
        );
      }
    } finally {
      await clearTokens();
    }
  }
}
