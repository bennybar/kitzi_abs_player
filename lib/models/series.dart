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

    // Build cover URL if available
    String? coverUrl;
    if (json['cover'] is String && (json['cover'] as String).isNotEmpty && baseUrl != null) {
      final cover = json['cover'] as String;
      if (cover.startsWith('http')) {
        coverUrl = cover;
      } else {
        coverUrl = '$baseUrl$cover';
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
