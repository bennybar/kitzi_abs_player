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
        (authorsList != null ? authorsList.join(', ') : null);

    // Construct cover URL, add ?token= only if provided
    var coverUrl = '$baseUrl/api/items/$id/cover';
    if (token != null && token.isNotEmpty) {
      coverUrl = '$coverUrl?token=$token';
    }

    final description = (meta['description'] ?? j['description'])?.toString();
    final durationSecs = media['duration'] is num
        ? (media['duration'] as num).toDouble()
        : (meta['duration'] is num ? (meta['duration'] as num).toDouble() : null);
    final updatedEpoch = j['updatedAt'] is num ? j['updatedAt'] as num : null;
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

    return Book(
      id: id,
      title: title,
      author: authorStr,
      coverUrl: coverUrl,
      description: description,
      durationMs: durationSecs != null ? (durationSecs * 1000).round() : null,
      sizeBytes: sizeBytes,
      updatedAt: updatedEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(updatedEpoch.toInt(), isUtc: true)
          : null,
      authors: authorsList,
      narrators: narratorsList,
      publisher: publisher,
      publishYear: publishYear,
      genres: genresList,
    );
  }
}
