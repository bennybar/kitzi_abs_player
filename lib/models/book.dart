class Book {
  final String id;
  final String title;
  final String? author;
  final String coverUrl; // always a usable URL
  final String? description;
  final int? durationMs;
  final int? sizeBytes;
  final DateTime? updatedAt;

  Book({
    required this.id,
    required this.title,
    required this.coverUrl,
    this.author,
    this.description,
    this.durationMs,
    this.sizeBytes,
    this.updatedAt,
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
    final author =
    (j['author'] ?? meta['authorName'] ?? meta['author'] ?? meta['authors']?.toString());

    // Construct cover URL, add ?token= only if provided
    var coverUrl = '$baseUrl/api/items/$id/cover';
    if (token != null && token.isNotEmpty) {
      coverUrl = '$coverUrl?token=$token';
    }

    final description = (meta['description'] ?? j['description'])?.toString();
    final durationSecs = media['duration'] is num ? (media['duration'] as num).toDouble() : null;
    final updatedEpoch = j['updatedAt'] is num ? j['updatedAt'] as num : null;
    final sizeBytes = media['size'] is num ? (media['size'] as num).toInt() : null;

    return Book(
      id: id,
      title: title,
      author: author,
      coverUrl: coverUrl,
      description: description,
      durationMs: durationSecs != null ? (durationSecs * 1000).round() : null,
      sizeBytes: sizeBytes,
      updatedAt: updatedEpoch != null
          ? DateTime.fromMillisecondsSinceEpoch(updatedEpoch.toInt(), isUtc: true)
          : null,
    );
  }
}
