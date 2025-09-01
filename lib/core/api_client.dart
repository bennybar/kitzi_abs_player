import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ApiClient {
  ApiClient(this._prefs, this._secure);

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  String? get baseUrl => _prefs.getString('abs_base_url');

  Future<void> setBaseUrl(String url) async {
    url = url.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    url = url.replaceAll(RegExp(r'/+$'), '');
    await _prefs.setString('abs_base_url', url);
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
      ...?headers,
    };

    if (auth) {
      final access = await _getAccessToken();
      if (access != null) reqHeaders['Authorization'] = 'Bearer $access';
    }

    Future<http.Response> _send(String m) async {
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
    var resp = await _send(upper);

    if (auth && resp.statusCode == 401) {
      final refreshed = await _refreshAccessToken();
      if (refreshed) {
        final retryHeaders = Map<String, String>.from(reqHeaders);
        retryHeaders['Authorization'] = 'Bearer ${await _getAccessToken()}';
        resp = await _send(upper);
      }
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
    final base = baseUrl;
    final refresh = await _getRefreshToken();
    if (base == null || refresh == null) return false;

    final resp = await http.post(
      Uri.parse('$base/auth/refresh'),
      headers: {
        'Content-Type': 'application/json',
        'x-refresh-token': refresh,
      },
    );
    if (resp.statusCode != 200) return false;

    final data = jsonDecode(resp.body);
    final user = data['user'] as Map<String, dynamic>?;
    final access = user?['accessToken'] as String?;
    final newRefresh = user?['refreshToken'] as String?;
    if (access == null) return false;

    final assumedExpiry = DateTime.now().toUtc().add(const Duration(hours: 12));
    await _setAccessToken(access, assumedExpiry);
    if (newRefresh != null && newRefresh.isNotEmpty) {
      await _setRefreshToken(newRefresh);
    }
    return true;
  }

  Future<bool> refreshAccessToken() => _refreshAccessToken();

  Future<bool> login({
    required String baseUrl,
    required String username,
    required String password,
  }) async {
    await setBaseUrl(baseUrl);
    final resp = await http.post(
      Uri.parse('$baseUrl/login'),
      headers: {
        'Content-Type': 'application/json',
        'x-return-tokens': 'true',
      },
      body: jsonEncode({'username': username, 'password': password}),
    );

    if (resp.statusCode != 200) return false;

    final data = jsonDecode(resp.body) as Map<String, dynamic>;
    final user = data['user'] as Map<String, dynamic>?;
    final access = user?['accessToken'] as String?;
    final refresh = user?['refreshToken'] as String?;
    if (access == null || refresh == null) return false;

    final assumedExpiry = DateTime.now().toUtc().add(const Duration(hours: 12));
    await _setAccessToken(access, assumedExpiry);
    await _setRefreshToken(refresh);
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
            'x-refresh-token': refresh,
          },
        );
      }
    } finally {
      await clearTokens();
    }
  }
}
