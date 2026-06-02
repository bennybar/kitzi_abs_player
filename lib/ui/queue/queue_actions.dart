import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/queue_service.dart';
import '../../models/book.dart';
import '../../main.dart';

/// Shared "Add to queue" helpers so the queue actions look/behave identically
/// from the book list, book detail, and the player.

void addBookToQueue(BuildContext context, Book book, {bool next = false}) {
  final queue = ServicesScope.of(context).services.queue;
  final item = QueueItem.fromBook(book);
  final already = queue.contains(item.libraryItemId);
  if (next) {
    queue.addNext(item);
  } else {
    queue.addToBack(item);
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(
    SnackBar(
      content: Text(already
          ? 'Moved "${book.title}" in queue'
          : next
              ? 'Playing next: "${book.title}"'
              : 'Added "${book.title}" to queue'),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ),
  );
}

/// Bottom sheet offering "Play next" / "Add to end" for a book.
Future<void> showQueueSheet(BuildContext context, Book book) async {
  final queued = ServicesScope.of(context).services.queue.contains(book.id);
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Symbols.playlist_play),
            title: const Text('Play next'),
            subtitle: const Text('Put at the top of the queue'),
            onTap: () {
              Navigator.pop(ctx);
              addBookToQueue(context, book, next: true);
            },
          ),
          ListTile(
            leading: const Icon(Symbols.playlist_add),
            title: Text(queued ? 'Already in queue' : 'Add to queue'),
            subtitle: const Text('Add to the end'),
            enabled: !queued,
            onTap: queued
                ? null
                : () {
                    Navigator.pop(ctx);
                    addBookToQueue(context, book);
                  },
          ),
        ],
      ),
    ),
  );
}
