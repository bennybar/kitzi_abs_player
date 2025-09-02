import 'dart:async';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import 'dart:io';
import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/downloads_repository.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.repo});
  final DownloadsRepository repo;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final Stream<TaskUpdate> _updates;
  StreamSubscription<TaskUpdate>? _sub;

  // latest update by taskId so we can show immediate progress
  final Map<String, TaskUpdate> _latest = {};

  @override
  void initState() {
    super.initState();
    // make sure repo is initialized (no-op if already)
    widget.repo.init();

    _updates = widget.repo.progressStream();
    _sub = _updates.listen((u) {
      _latest[u.task.taskId] = u;
      if (mounted) setState(() {}); // trigger rebuild
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We rebuild on each stream event via setState above.
    return FutureBuilder<List<String>>(
      future: widget.repo.listTrackedItemIds(),
      builder: (context, idsSnap) {
        final ids = idsSnap.data ?? const [];
        if (ids.isEmpty) {
          return const Center(child: Text('No downloads'));
        }
        return FutureBuilder<BooksRepository>(
          future: BooksRepository.create(),
          builder: (context, repoSnap) {
            if (!repoSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final repo = repoSnap.data!;
            return ListView.separated(
              itemCount: ids.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (ctx, i) {
                final itemId = ids[i];
                return FutureBuilder<Book>(
                  future: repo.getBook(itemId),
                  builder: (context, bookSnap) {
                    final book = bookSnap.data;
                    return _BookDownloadTile(
                      itemId: itemId,
                      title: book?.title ?? 'Item $itemId',
                      coverUrl: book?.coverUrl,
                      repo: widget.repo,
                      latest: _latest,
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _BookDownloadTile extends StatefulWidget {
  const _BookDownloadTile({
    required this.itemId,
    required this.title,
    required this.coverUrl,
    required this.repo,
    required this.latest,
  });
  final String itemId;
  final String title;
  final String? coverUrl;
  final DownloadsRepository repo;
  final Map<String, TaskUpdate> latest;

  @override
  State<_BookDownloadTile> createState() => _BookDownloadTileState();
}

class _BookDownloadTileState extends State<_BookDownloadTile> {
  List<TaskRecord> _records = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await FileDownloader().database.allRecords();
    setState(() {
      _records = all.where((r) {
        final id = (r.task.metaData ?? '').contains(widget.itemId);
        return id;
      }).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    int total = _records.length;
    int done = _records.where((r) => r.status == TaskStatus.complete).length;
    double sum = 0.0;
    for (final r in _records) {
      if (r.status == TaskStatus.complete) sum += 1.0; else sum += (r.progress ?? 0.0);
    }
    final progress = total == 0 ? 0.0 : (sum / total);
    final isComplete = total > 0 && done == total;

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      leading: _cover(widget.coverUrl, cs),
      title: Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: isComplete ? 1.0 : progress,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 4),
          Text(isComplete ? 'Complete' : 'Downloading • ${(progress * 100).toStringAsFixed(0)}%'),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!isComplete)
            IconButton(
              tooltip: 'Cancel',
              icon: const Icon(Icons.cancel_rounded),
              onPressed: () async {
                for (final r in _records) {
                  await FileDownloader().cancelTaskWithId(r.taskId);
                }
                await _load();
                if (mounted) setState(() {});
              },
            ),
          IconButton(
            tooltip: 'Delete files',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () async {
              await widget.repo.deleteLocal(widget.itemId);
              await _load();
              if (mounted) setState(() {});
            },
          ),
        ],
      ),
    );
  }

  Widget _cover(String? url, ColorScheme cs) {
    final radius = BorderRadius.circular(12);
    final ph = Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: const Icon(Icons.menu_book_outlined),
    );
    if (url == null || url.isEmpty) return ph;
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') {
      final f = File(uri.toFilePath());
      if (f.existsSync()) {
        return ClipRRect(
          borderRadius: radius,
          child: Image.file(f, width: 56, height: 56, fit: BoxFit.cover),
        );
      }
      return ph;
    }
    return ClipRRect(
      borderRadius: radius,
      child: Image.network(url, width: 56, height: 56, fit: BoxFit.cover, errorBuilder: (_, __, ___) => ph),
    );
  }
}

