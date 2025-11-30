import 'package:flutter/material.dart';

import '../../core/playback_journal_service.dart';
import '../../core/playback_repository.dart';

String _formatTimestamp(DateTime dt) {
  final local = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
}

class PlayHistorySheet extends StatelessWidget {
  const PlayHistorySheet({
    super.key,
    required this.libraryItemId,
    required this.bookTitle,
  });

  final String libraryItemId;
  final String bookTitle;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: SizedBox(
        height: size.height * 0.65,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Text(
                'Play history',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                bookTitle,
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<PlaybackHistoryEntry>>(
                  future: PlaybackJournalService.instance.historyFor(libraryItemId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final entries = snapshot.data ?? const [];
                    if (entries.isEmpty) {
                      return Center(
                        child: Text(
                          'No recent pauses recorded.',
                          style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      );
                    }
                    return ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final subtitle =
                            '${_formatTimestamp(entry.createdAt)} • ${_fmtDuration(entry.position)}';
                        final title = entry.chapterTitle?.trim().isNotEmpty == true
                            ? entry.chapterTitle!
                            : 'Chapter ${entry.chapterIndex != null ? entry.chapterIndex! + 1 : index + 1}';
                        return ListTile(
                          leading: const Icon(Icons.history_rounded),
                          title: Text(title),
                          subtitle: Text(subtitle),
                          onTap: () => Navigator.of(context).pop(entry),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class BookmarksSheet extends StatefulWidget {
  const BookmarksSheet({
    super.key,
    required this.libraryItemId,
    required this.bookTitle,
    this.playback,
  });

  final String libraryItemId;
  final String bookTitle;
  final PlaybackRepository? playback;

  @override
  State<BookmarksSheet> createState() => _BookmarksSheetState();
}

class _BookmarksSheetState extends State<BookmarksSheet> {
  late Future<List<BookmarkEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = PlaybackJournalService.instance.bookmarksFor(widget.libraryItemId);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = PlaybackJournalService.instance.bookmarksFor(widget.libraryItemId);
    });
  }

  Future<void> _playFromBookmark(BuildContext context, BookmarkEntry entry) async {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          'Play from here?',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Go to "${entry.chapterTitle ?? widget.bookTitle}" at ${_fmtDuration(entry.position)}?',
          style: text.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
            child: const Text('Play'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final playback = widget.playback;
      if (playback == null) return;
      Navigator.of(context).pop();
      await playback.seekGlobal(entry.position, reportNow: true);
      await playback.player.play();
    }
  }

  Future<void> _removeBookmark(BuildContext context, BookmarkEntry entry) async {
    final localId = entry.localId;
    if (localId == null) return;
    await PlaybackJournalService.instance.deleteBookmark(localId);
    if (mounted) {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    return SafeArea(
      child: SizedBox(
        height: size.height * 0.65,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 32,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: cs.outlineVariant,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
              Text(
                'Bookmarks',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                widget.bookTitle,
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<BookmarkEntry>>(
                  future: _future,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    final entries = snapshot.data ?? const [];
                    if (entries.isEmpty) {
                      return Center(
                        child: Text(
                          'No bookmarks saved yet.',
                          style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      );
                    }
                    return ListView.separated(
                      itemCount: entries.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        final subtitle =
                            '${_formatTimestamp(entry.createdAt)} • ${_fmtDuration(entry.position)}';
                        final title = entry.chapterTitle?.trim().isNotEmpty == true
                            ? entry.chapterTitle!
                            : 'Chapter ${entry.chapterIndex != null ? entry.chapterIndex! + 1 : index + 1}';
                        return ListTile(
                          leading: const Icon(Icons.bookmark_rounded),
                          title: Text(title),
                          subtitle: Text(subtitle),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.play_arrow_rounded),
                                tooltip: 'Play from here',
                                onPressed: () => _playFromBookmark(context, entry),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete_outline_rounded),
                                tooltip: 'Remove bookmark',
                                onPressed: () => _removeBookmark(context, entry),
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _fmtDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

