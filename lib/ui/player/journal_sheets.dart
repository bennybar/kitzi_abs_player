import 'package:flutter/material.dart';

import '../../core/playback_journal_service.dart';

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

class BookmarksSheet extends StatelessWidget {
  const BookmarksSheet({
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
                'Bookmarks',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
              ),
              Text(
                bookTitle,
                style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: FutureBuilder<List<BookmarkEntry>>(
                  future: PlaybackJournalService.instance.bookmarksFor(libraryItemId),
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

String _fmtDuration(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  if (hours > 0) {
    return '$hours:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}

