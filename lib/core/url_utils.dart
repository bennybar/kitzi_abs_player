// lib/core/url_utils.dart
import 'package:flutter/foundation.dart';

String normalizeBase(String input) {
  var url = input.trim();
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = 'https://$url';
  }
  // drop trailing slashes
  url = url.replaceAll(RegExp(r'/+$'), '');
  return url;
}

/// Builds a valid ABS URL from a base + (possibly absolute) contentUrl,
/// adding/merging the token as a query param safely.
String buildAbsUrl({
  required String baseUrl,
  required String contentUrl,
  String? token,
}) {
  final base = Uri.parse(normalizeBase(baseUrl));

  // If contentUrl is already absolute, start from it; else resolve against base.
  Uri u;
  final raw = contentUrl.trim();
  if (raw.isEmpty) {
    throw ArgumentError('Empty contentUrl');
  }
  final parsedContent = Uri.tryParse(raw);
  if (parsedContent == null) {
    throw ArgumentError('Unparseable contentUrl: $raw');
  }
  if (parsedContent.hasScheme) {
    u = parsedContent;
  } else {
    // Ensure leading slash so resolve() doesn’t drop path segments unexpectedly
    final rel = raw.startsWith('/') ? raw : '/$raw';
    u = base.resolve(rel);
  }

  // Merge token with existing query parameters (no double ??, no spaces)
  final qp = Map<String, String>.from(u.queryParameters);
  if (token != null && token.isNotEmpty) {
    qp['token'] = token;
  }

  // Rebuild with properly encoded path & query
  u = u.replace(queryParameters: qp);

  // Quick sanity checks (fail fast in debug)
  assert(u.hasScheme && u.hasAuthority);
  assert(!u.toString().contains(' '), 'URL contains spaces');

  return u.toString();
}
