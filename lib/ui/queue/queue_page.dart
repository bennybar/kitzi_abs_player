import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../../core/image_cache_manager.dart';
import '../../core/queue_service.dart';
import '../../main.dart';

/// "Up Next" queue tab: reorder, remove, clear, tap-to-play.
class QueuePage extends StatelessWidget {
  const QueuePage({super.key});

  @override
  Widget build(BuildContext context) {
    final queue = ServicesScope.of(context).services.queue;
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        backgroundColor: cs.surface,
        title: const Text('Up Next'),
        actions: [
          ValueListenableBuilder<List<QueueItem>>(
            valueListenable: queue.queue,
            builder: (_, items, __) => items.isEmpty
                ? const SizedBox.shrink()
                : TextButton.icon(
                    onPressed: () => _confirmClear(context, queue),
                    icon: const Icon(Symbols.clear_all, size: 20),
                    label: const Text('Clear'),
                  ),
          ),
        ],
      ),
      body: ValueListenableBuilder<List<QueueItem>>(
        valueListenable: queue.queue,
        builder: (_, items, __) {
          if (items.isEmpty) {
            return _EmptyQueue(cs: cs);
          }
          return ReorderableListView.builder(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 120),
            itemCount: items.length,
            onReorder: queue.reorder,
            itemBuilder: (context, i) {
              final item = items[i];
              return _QueueTile(
                key: ValueKey(item.libraryItemId),
                item: item,
                index: i,
                onPlay: () => queue.playNow(item),
                onRemove: () => queue.removeId(item.libraryItemId),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context, QueueService queue) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Clear queue?'),
        content: const Text('Remove all items from Up Next.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Clear')),
        ],
      ),
    );
    if (ok == true) queue.clear();
  }
}

class _QueueTile extends StatelessWidget {
  const _QueueTile({
    super.key,
    required this.item,
    required this.index,
    required this.onPlay,
    required this.onRemove,
  });

  final QueueItem item;
  final int index;
  final VoidCallback onPlay;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Dismissible(
      key: ValueKey('dismiss_${item.libraryItemId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 24),
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        decoration: BoxDecoration(
          color: cs.errorContainer,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Icon(Symbols.delete, color: cs.onErrorContainer),
      ),
      onDismissed: (_) => onRemove(),
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        color: cs.surfaceContainerHigh,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPlay,
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: SizedBox(
                    width: 52,
                    height: 52,
                    child: (item.coverUrl != null && item.coverUrl!.isNotEmpty)
                        ? EnhancedCoverImage(
                            url: item.coverUrl!, width: 52, height: 52)
                        : Container(
                            color: cs.surfaceContainerHighest,
                            child: Icon(Symbols.book, color: cs.onSurfaceVariant),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        item.title.isEmpty ? 'Untitled' : item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15),
                      ),
                      if (item.author != null && item.author!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          item.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: cs.onSurfaceVariant, fontSize: 13),
                        ),
                      ],
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Play now',
                  icon: const Icon(Symbols.play_arrow, fill: 1),
                  onPressed: onPlay,
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Icon(Symbols.drag_handle, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyQueue extends StatelessWidget {
  const _EmptyQueue({required this.cs});
  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Symbols.queue_music, size: 64, color: cs.onSurfaceVariant),
          const SizedBox(height: 16),
          Text('Your queue is empty',
              style: TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                  color: cs.onSurface)),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Add books with "Add to queue" and they will play one after another.',
              textAlign: TextAlign.center,
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}
