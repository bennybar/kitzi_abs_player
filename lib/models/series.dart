class Series {
  final String id;
  final String name;
  final String? description;
  final int numBooks;
  final List<String> bookIds;
  final String? coverUrl;
  final bool isFinished;
  final DateTime? addedAt;
  final DateTime? updatedAt;
  /// Cover URLs for the first few books, already ordered (release year, then
  /// title). Lets cards render the fanned deck instantly from cached list data
  /// without loading each series' member books.
  final List<String> previewCoverUrls;
  /// First book's author, for instant display on the card.
  final String? author;

  const Series({
    required this.id,
    required this.name,
    this.description,
    required this.numBooks,
    required this.bookIds,
    this.coverUrl,
    this.isFinished = false,
    this.addedAt,
    this.updatedAt,
    this.previewCoverUrls = const <String>[],
    this.author,
  });

  factory Series.fromJson(Map<String, dynamic> json, {String? baseUrl, String? token}) {
    // Extract book IDs from the books array
    final List<String> bookIds = [];
    if (json['books'] is List) {
      for (final book in json['books'] as List) {
        if (book is Map) {
          final id = (book['id'] ?? book['_id'] ?? '').toString();
          if (id.isNotEmpty) bookIds.add(id);
        } else if (book is String) {
          bookIds.add(book);
        }
      }
    }

    // Build ordered preview cover URLs (and author) from the embedded books so
    // cards can render the fanned deck without a secondary per-series load.
    final previewCoverUrls = <String>[];
    String? author;
    if (json['books'] is List && baseUrl != null) {
      final entries = <Map<String, dynamic>>[];
      for (final b in (json['books'] as List)) {
        if (b is! Map) continue;
        final bid = (b['id'] ?? b['_id'] ?? '').toString();
        if (bid.isEmpty) continue;
        final media = (b['media'] is Map) ? b['media'] as Map : const {};
        final meta = (media['metadata'] is Map) ? media['metadata'] as Map : const {};
        int? yr;
        final y = meta['publishedYear'];
        if (y is num) {
          yr = y.toInt();
        } else if (y is String) {
          yr = int.tryParse(y.trim());
        }
        entries.add({
          'id': bid,
          'year': yr,
          'title': (meta['title'] ?? '').toString(),
          'author': (meta['authorName'] ?? '').toString(),
        });
      }
      entries.sort((a, b) {
        final ya = a['year'] as int?;
        final yb = b['year'] as int?;
        if (ya != null && yb != null && ya != yb) return ya.compareTo(yb);
        if (ya != null && yb == null) return -1;
        if (ya == null && yb != null) return 1;
        return (a['title'] as String)
            .toLowerCase()
            .compareTo((b['title'] as String).toLowerCase());
      });
      final tokenParam = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      for (final e in entries.take(4)) {
        previewCoverUrls.add('$baseUrl/api/items/${e['id']}/cover$tokenParam');
      }
      if (entries.isNotEmpty) {
        final a = entries.first['author'] as String;
        if (a.isNotEmpty) author = a;
      }
    }

    // Build cover URL if available
    String? coverUrl;
    if (json['cover'] is String && (json['cover'] as String).isNotEmpty && baseUrl != null) {
      final cover = json['cover'] as String;
      final tokenParam = (token != null && token.isNotEmpty) ? '?token=$token' : '';
      if (cover.startsWith('http')) {
        coverUrl = cover;
      } else {
        coverUrl = '$baseUrl$cover$tokenParam';
      }
    }

    return Series(
      id: (json['id'] ?? json['_id'] ?? '').toString(),
      name: (json['name'] ?? json['title'] ?? '').toString(),
      description: json['description']?.toString(),
      numBooks: (json['numBooks'] ?? json['bookCount'] ?? bookIds.length) is int
          ? (json['numBooks'] ?? json['bookCount'] ?? bookIds.length) as int
          : int.tryParse((json['numBooks'] ?? json['bookCount'] ?? bookIds.length).toString()) ?? bookIds.length,
      bookIds: bookIds,
      coverUrl: coverUrl,
      isFinished: json['isFinished'] == true || json['finished'] == true,
      previewCoverUrls: previewCoverUrls,
      author: author,
      addedAt: json['addedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['addedAt'] as int)
          : DateTime.tryParse(json['addedAt']?.toString() ?? ''),
      updatedAt: json['updatedAt'] is int 
          ? DateTime.fromMillisecondsSinceEpoch(json['updatedAt'] as int)
          : DateTime.tryParse(json['updatedAt']?.toString() ?? ''),
    );
  }

  @override
  String toString() {
    return 'Series(id: $id, name: $name, numBooks: $numBooks, bookIds: ${bookIds.length})';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Series && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}
