class Book {
  final String id;
  final String title;
  final String? author;
  final String coverUrl; // always a usable URL
  final String? description;
  final int? durationMs;
  final int? sizeBytes;
  final DateTime? updatedAt;
  // Enriched metadata (optional)
  final List<String>? authors;
  final List<String>? narrators;
  final String? publisher;
  final int? publishYear;
  final List<String>? genres;
  // Media kind and support indicator
  final String? mediaKind; // e.g., 'book', 'podcast', 'ebook'
  final bool isAudioBook;  // true when playable audiobook
  final String? libraryId; // source library id when available

  Book({
    required this.id,
    required this.title,
    required this.coverUrl,
    this.author,
    this.description,
    this.durationMs,
    this.sizeBytes,
    this.updatedAt,
    this.authors,
    this.narrators,
    this.publisher,
    this.publishYear,
    this.genres,
    this.mediaKind,
    this.isAudioBook = true,
    this.libraryId,
  });

  /// Build from ABS library item JSON (id + media.metadata.*).
  factory Book.fromLibraryItemJson(
      Map<String, dynamic> j, {
        required String baseUrl,
        String? token, // <-- nullable now
      }) {
    final id = (j['id'] ?? j['_id'] ?? '').toString();

    final media = j['media'] as Map<String, dynamic>? ?? const {};
    final meta = media['metadata'] as Map<String, dynamic>? ?? const {};
    final title = (j['title'] ?? meta['title'] ?? '').toString();

    List<String>? authorsList;
    final authorsRaw = meta['authors'] ?? j['authors'];
    if (authorsRaw is List) {
      authorsList = [];
      for (final it in authorsRaw) {
        if (it is Map && it['name'] != null) authorsList.add(it['name'].toString());
        if (it is String) authorsList.add(it);
      }
      if (authorsList.isEmpty) authorsList = null;
    }
    final authorStr = (j['author'] ?? meta['authorName'] ?? meta['author'])?.toString() ??
        (authorsList?.join(', '));

    // Construct cover URL, add ?token= only if provided
    var coverUrl = '$baseUrl/api/items/$id/cover';
    if (token != null && token.isNotEmpty) {
      coverUrl = '$coverUrl?token=$token';
    }

    final description = (meta['description'] ?? j['description'])?.toString();
    final durationSecs = media['duration'] is num
        ? (media['duration'] as num).toDouble()
        : (meta['duration'] is num ? (meta['duration'] as num).toDouble() : null);
    // Prefer updatedAt (original behavior), then fall back to added/created
    DateTime? bestTimestamp;
    dynamic updatedRaw = j['updatedAt'];
    dynamic addedRaw = j['addedAt'] ?? j['createdAt'];
    bestTimestamp = _parseTimestampFlexible(updatedRaw) ?? _parseTimestampFlexible(addedRaw);
    final sizeBytes = media['size'] is num ? (media['size'] as num).toInt() : null;

    // More metadata
    List<String>? narratorsList;
    final narrRaw = meta['narrators'] ?? j['narrators'];
    if (narrRaw is List) {
      narratorsList = [];
      for (final it in narrRaw) {
        if (it is Map && it['name'] != null) narratorsList.add(it['name'].toString());
        if (it is String) narratorsList.add(it);
      }
      if (narratorsList.isEmpty) narratorsList = null;
    }

    final publisher = (meta['publisher'] ?? j['publisher'])?.toString();
    int? publishYear;
    final y = (meta['publishYear'] ?? meta['year'] ?? j['publishYear'] ?? j['year']);
    if (y is num) publishYear = y.toInt();
    if (y is String) publishYear = int.tryParse(y);

    List<String>? genresList;
    final genRaw = meta['genres'] ?? j['genres'];
    if (genRaw is List) {
      genresList = [];
      for (final it in genRaw) {
        if (it is Map && it['name'] != null) genresList.add(it['name'].toString());
        if (it is String) genresList.add(it);
      }
      if (genresList.isEmpty) genresList = null;
    }

    // Try to detect media type/kind from common shapes
    String? kind;
    try {
      final media = j['media'] as Map<String, dynamic>?;
      final typeA = media?[ 'type']?.toString();
      final typeB = media?[ 'mediaType']?.toString();
      final typeC = j['mediaType']?.toString();
      final typeD = j['type']?.toString();
      kind = (typeA ?? typeB ?? typeC ?? typeD)?.toLowerCase();
    } catch (_) {}
    // Determine audiobook vs ebook/podcast from available hints
    final mediaMap = j['media'] is Map ? (j['media'] as Map).cast<String, dynamic>() : const <String, dynamic>{};
    final audioFiles = mediaMap['audioFiles'];
    final tracks = mediaMap['tracks'];
    final audioTrackCount = mediaMap['audioTrackCount'];
    final hasAudio =
        (durationSecs != null && durationSecs > 0) ||
        (audioFiles is List && audioFiles.isNotEmpty) ||
        (tracks is List && tracks.isNotEmpty) ||
        (audioTrackCount is num && audioTrackCount.toInt() > 0);

    final ebookObj = mediaMap['ebook'] ?? mediaMap['ebookFile'] ?? mediaMap['ebookFormat'];
    final ext = (j['extension'] ?? mediaMap['extension'] ?? '').toString().toLowerCase();
    final isEbookExt = ext.endsWith('epub') || ext.endsWith('pdf') || ext.endsWith('mobi') || ext.endsWith('azw') || ext.endsWith('txt');
    final hasEbook = ebookObj != null || isEbookExt;

    bool isBook;
    // Strict classification: require actual audio evidence
    if (hasAudio && !hasEbook) {
      isBook = true;
    } else {
      isBook = false;
    }

    return Book(
      id: id,
      title: title,
      author: authorStr,
      coverUrl: coverUrl,
      description: description,
      durationMs: durationSecs != null ? (durationSecs * 1000).round() : null,
      sizeBytes: sizeBytes,
      updatedAt: bestTimestamp,
      authors: authorsList,
      narrators: narratorsList,
      publisher: publisher,
      publishYear: publishYear,
      genres: genresList,
      mediaKind: kind,
      isAudioBook: isBook,
      libraryId: (j['libraryId'] ?? '').toString().isNotEmpty ? (j['libraryId'] ?? '').toString() : null,
    );
  }
}

/// Flexible timestamp parser supporting int epoch ms/sec and ISO8601 strings
DateTime? _parseTimestampFlexible(dynamic value) {
  try {
    if (value == null) return null;
    if (value is num) {
      // Heuristic: treat > 10^12 as ms, else seconds
      final n = value.toDouble();
      if (n > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(n.round(), isUtc: true);
      } else if (n > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch((n * 1000).round(), isUtc: true);
      } else {
        return DateTime.fromMillisecondsSinceEpoch(n.round(), isUtc: true);
      }
    }
    if (value is String) {
      return DateTime.tryParse(value);
    }
  } catch (_) {}
  return null;
}
