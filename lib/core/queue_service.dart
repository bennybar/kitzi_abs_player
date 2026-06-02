import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'playback_repository.dart';
import '../models/book.dart';

/// A single entry in the up-next play queue.
class QueueItem {
  final String libraryItemId;
  final String title;
  final String? author;
  final String? coverUrl;

  const QueueItem({
    required this.libraryItemId,
    required this.title,
    this.author,
    this.coverUrl,
  });

  factory QueueItem.fromBook(Book b) => QueueItem(
        libraryItemId: b.id,
        title: b.title,
        author: b.author,
        coverUrl: b.coverUrl,
      );

  Map<String, dynamic> toJson() => {
        'id': libraryItemId,
        'title': title,
        if (author != null) 'author': author,
        if (coverUrl != null) 'coverUrl': coverUrl,
      };

  static QueueItem? fromJson(dynamic j) {
    if (j is! Map) return null;
    final id = (j['id'] ?? '').toString();
    if (id.isEmpty) return null;
    return QueueItem(
      libraryItemId: id,
      title: (j['title'] ?? '').toString(),
      author: j['author']?.toString(),
      coverUrl: j['coverUrl']?.toString(),
    );
  }
}

/// Persisted "up next" queue with auto-advance.
///
/// The queue holds items to be played *after* the current book. When the
/// playing book finishes (PlaybackRepository.bookCompletedStream), the head of
/// the queue is popped and played automatically.
class QueueService {
  QueueService(this._playback);

  static const String _prefsKey = 'play_queue_v1';

  final PlaybackRepository _playback;
  SharedPreferences? _prefs;
  StreamSubscription<String>? _completionSub;
  bool _advancing = false;

  /// Observable queue contents (order = play order). UI listens to this.
  final ValueNotifier<List<QueueItem>> queue =
      ValueNotifier<List<QueueItem>>(const []);

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    _load();
    // Auto-advance when a book finishes.
    _completionSub = _playback.bookCompletedStream.listen(_onBookCompleted);
  }

  void dispose() {
    _completionSub?.cancel();
    queue.dispose();
  }

  bool contains(String libraryItemId) =>
      queue.value.any((e) => e.libraryItemId == libraryItemId);

  int get length => queue.value.length;

  /// Append to the end of the queue (no duplicates).
  void addToBack(QueueItem item) {
    if (contains(item.libraryItemId)) return;
    _set([...queue.value, item]);
  }

  /// Insert at the front so it plays next.
  void addNext(QueueItem item) {
    final rest =
        queue.value.where((e) => e.libraryItemId != item.libraryItemId).toList();
    _set([item, ...rest]);
  }

  /// Play this item immediately. If it was queued, remove it from the queue.
  Future<bool> playNow(QueueItem item) async {
    _set(queue.value
        .where((e) => e.libraryItemId != item.libraryItemId)
        .toList());
    return _playback.playItem(item.libraryItemId);
  }

  void removeId(String libraryItemId) {
    _set(queue.value
        .where((e) => e.libraryItemId != libraryItemId)
        .toList());
  }

  void reorder(int oldIndex, int newIndex) {
    final list = [...queue.value];
    if (oldIndex < 0 || oldIndex >= list.length) return;
    // ReorderableListView semantics: newIndex is the slot before removal.
    if (newIndex > oldIndex) newIndex -= 1;
    newIndex = newIndex.clamp(0, list.length - 1);
    final moved = list.removeAt(oldIndex);
    list.insert(newIndex, moved);
    _set(list);
  }

  void clear() => _set(const []);

  // --- internals ---

  Future<void> _onBookCompleted(String finishedId) async {
    if (_advancing) return;
    // Drop the finished item if it happens to be queued, then play the head.
    var list = queue.value
        .where((e) => e.libraryItemId != finishedId)
        .toList();
    if (list.isEmpty) {
      if (list.length != queue.value.length) _set(list);
      return;
    }
    _advancing = true;
    try {
      final next = list.first;
      _set(list.sublist(1));
      await _playback.playItem(next.libraryItemId);
    } catch (_) {
      // leave remaining queue intact on failure
    } finally {
      _advancing = false;
    }
  }

  void _set(List<QueueItem> list) {
    queue.value = List.unmodifiable(list);
    _persist();
  }

  void _load() {
    try {
      final raw = _prefs?.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! List) return;
      final items = <QueueItem>[];
      for (final e in decoded) {
        final item = QueueItem.fromJson(e);
        if (item != null) items.add(item);
      }
      queue.value = List.unmodifiable(items);
    } catch (_) {
      // Corrupt cache: start empty.
    }
  }

  void _persist() {
    try {
      _prefs?.setString(
        _prefsKey,
        jsonEncode(queue.value.map((e) => e.toJson()).toList()),
      );
    } catch (_) {}
  }
}
