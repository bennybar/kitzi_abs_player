import 'dart:async';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import 'dart:io';
import '../../core/download_storage.dart';
import '../../core/books_repository.dart';
import '../../core/downloads_repository.dart';
import '../book_detail/book_detail_page.dart';

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
        final allIds = idsSnap.data ?? const [];
        return FutureBuilder<BooksRepository>(
          future: BooksRepository.create(),
          builder: (context, repoSnap) {
            if (!repoSnap.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final repo = repoSnap.data!;
            return FutureBuilder<List<Widget>>(
              future: _buildTiles(repo, allIds),
              builder: (context, tilesSnap) {
                final tiles = tilesSnap.data ?? const <Widget>[];
                final cs = Theme.of(context).colorScheme;
                return SafeArea(
                  top: true,
                  bottom: false,
                  left: false,
                  right: false,
                  child: Column(
                  children: [
                    // Page header
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                      child: Row(
                        children: [
                          Icon(Icons.download_rounded, color: cs.primary),
                          const SizedBox(width: 8),
                          Text(
                            'Downloads',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                          ),
                          const Spacer(),
                          if (tiles.isEmpty)
                            Text('No downloads', style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Swipe left on an item to remove downloaded files',
                          style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Expanded(
                      child: tiles.isEmpty
                          ? const Center(child: Text('No downloads yet'))
                          : ListView.separated(
                              itemCount: tiles.length,
                              separatorBuilder: (_, __) => const Divider(height: 1),
                              itemBuilder: (_, i) => tiles[i],
                            ),
                    ),
                  ],
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  Future<List<Widget>> _buildTiles(BooksRepository repo, List<String> ids) async {
    final tiles = <Widget>[];
    for (final itemId in ids) {
      final recs = await FileDownloader().database.allRecords();
      final records = recs.where((r) => (r.task.metaData ?? '').contains(itemId)).toList()
        ..sort((a, b) => (a.task.filename ?? '').compareTo(b.task.filename ?? ''));
      final total = records.length;
      final done = records.where((r) => r.status == TaskStatus.complete).length;
      final hasLocal = await widget.repo.hasLocalDownloads(itemId);

      final book = await repo.getBook(itemId);
      final w = Dismissible(
        key: ValueKey('dl-$itemId'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          color: Theme.of(context).colorScheme.error,
          child: Icon(
            Icons.delete_forever_rounded,
            color: Theme.of(context).colorScheme.onError,
          ),
        ),
        confirmDismiss: (_) async => true,
        onDismissed: (_) async {
          await widget.repo.cancelForItem(itemId);
          await widget.repo.deleteLocal(itemId);
          if (mounted) setState(() {});
        },
        child: _BookDownloadTile(
          itemId: itemId,
          title: book.title,
          author: book.author,
          coverUrl: book.coverUrl,
           durationMs: book.durationMs,
           sizeBytes: book.sizeBytes,
          repo: widget.repo,
          latest: _latest,
          hasLocalPrefetched: hasLocal,
        ),
      );

      // Show tiles:
      final hasActive = records.any((r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued);
      final isComplete = hasLocal || (total > 0 && done == total);
      if (isComplete || hasActive || (done > 0 && done < total)) {
        tiles.add(w);
      }
    }
    return tiles;
  }
}

class _BookDownloadTile extends StatefulWidget {
  const _BookDownloadTile({
    required this.itemId,
    required this.title,
    this.author,
    required this.coverUrl,
    this.durationMs,
    this.sizeBytes,
    required this.repo,
    required this.latest,
    this.hasLocalPrefetched = false,
  });
  final String itemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final int? durationMs;
  final int? sizeBytes;
  final DownloadsRepository repo;
  final Map<String, TaskUpdate> latest;
  final bool hasLocalPrefetched;

  @override
  State<_BookDownloadTile> createState() => _BookDownloadTileState();
}

class _BookDownloadTileState extends State<_BookDownloadTile> {
  List<TaskRecord> _records = const [];
  bool _hasLocal = false;
  int _localBytes = 0;

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
      }).toList()
        ..sort((a, b) => (a.task.filename ?? '').compareTo(b.task.filename ?? ''));
    });
    try {
      final hasLocal = widget.hasLocalPrefetched || await widget.repo.hasLocalDownloads(widget.itemId);
      int localBytes = 0;
      if (hasLocal) {
        // Sum file sizes
        final dir = await DownloadStorage.itemDir(widget.itemId);
        if (await dir.exists()) {
          final files = await dir
              .list()
              .where((x) => x is File)
              .cast<File>()
              .toList();
          for (final f in files) {
            try {
              final len = await f.length();
              localBytes = localBytes + len;
            } catch (_) {}
          }
        }
      }
      if (mounted) setState(() { _hasLocal = hasLocal; _localBytes = localBytes; });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final total = _records.length;
    final done = _records.where((r) => r.status == TaskStatus.complete).length;

    // Find the active task (running or enqueued)
    TaskRecord? active;
    if (_records.isNotEmpty) {
      try {
        active = _records.firstWhere(
          (r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued,
          orElse: () => _records.last,
        );
      } catch (_) {
        active = _records.last;
      }
    }
    double filePct = 0.0;
    int fileIndex = done + ((active != null && active.status != TaskStatus.complete) ? 1 : 0);
    if (active != null && active.status == TaskStatus.running) {
      filePct = (active.progress ?? 0.0).clamp(0.0, 1.0);
    }

    final overallPct = (total == 0 && _hasLocal)
        ? 1.0
        : total == 0
            ? 0.0
            : ((done.toDouble()) + filePct) / total.toDouble();

    final isComplete = _hasLocal || (total > 0 && done == total);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: () {
        showModalBottomSheet(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          backgroundColor: Colors.transparent,
          builder: (context) => Container(
            height: MediaQuery.of(context).size.height * 0.95,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: BookDetailPage(bookId: widget.itemId),
          ),
        );
      },
      leading: Hero(
        tag: 'downloads-cover-${widget.itemId}',
        child: _cover(widget.coverUrl, cs),
      ),
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          if ((widget.author ?? '').isNotEmpty)
            Text(
              widget.author!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: isComplete ? 1.0 : overallPct,
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 4),
          if (!isComplete && total > 0)
            Text(
              'Overall ${(overallPct * 100).toStringAsFixed(0)}% • File ${fileIndex.clamp(1, total)} of $total',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
            )
          else
            Text(_metaLine(), style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
        ],
      ),
      // No trailing actions; swipe-to-delete only
    );
  }

  String _metaLine() {
    final parts = <String>[];
    // Size
    final size = _hasLocal ? _formatBytes(_localBytes) : (widget.sizeBytes != null ? _formatBytes(widget.sizeBytes!) : null);
    if (size != null) parts.add(size);
    // Duration
    if (widget.durationMs != null && widget.durationMs! > 0) parts.add(_formatDurationMs(widget.durationMs!));
    parts.add('Complete');
    return parts.join(' • ');
  }

  String _formatBytes(int bytes) {
    const k = 1024;
    if (bytes < k) return '$bytes B';
    final kb = bytes / k;
    if (kb < k) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / k;
    if (mb < k) return '${mb.toStringAsFixed(1)} MB';
    final gb = mb / k;
    return '${gb.toStringAsFixed(2)} GB';
  }

  String _formatDurationMs(int ms) {
    final d = Duration(milliseconds: ms);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h}h ${m}m' : '${d.inMinutes}m';
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

