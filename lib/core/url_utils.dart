// lib/core/url_utils.dart

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
    // Resolve relative to the FULL base path so reverse-proxy/subpath installs
    // (e.g. https://host/audiobookshelf) are preserved. An absolute-path ref
    // ('/api/...') would replace the entire base path per RFC 3986 and drop the
    // subpath, so strip any leading slash and ensure the base path ends with '/'
    // so the last base segment is not treated as a file and discarded.
    final rel = raw.startsWith('/') ? raw.substring(1) : raw;
    final basePath = base.path.endsWith('/') ? base.path : '${base.path}/';
    u = base.replace(path: basePath).resolve(rel);
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
