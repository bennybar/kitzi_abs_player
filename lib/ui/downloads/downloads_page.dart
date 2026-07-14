import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:background_downloader/background_downloader.dart';
import 'dart:io';
import '../../core/download_storage.dart';
import '../../core/books_repository.dart';
import '../../core/downloads_repository.dart';
import '../book_detail/book_detail_page.dart';
import '../../widgets/skeleton_widgets.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.repo});
  final DownloadsRepository repo;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

enum DownloadsFilter { all, downloading, downloaded }

enum DownloadsSort { status, titleAsc, sizeDesc }

class _DownloadsPageState extends State<DownloadsPage> {
  late final Stream<TaskUpdate> _updates;
  StreamSubscription<TaskUpdate>? _sub;

  // latest update by taskId so we can show immediate progress
  final Map<String, TaskUpdate> _latest = {};

  // Created once so rebuilds (on every progress event) don't reconstruct the
  // repository or restart its work.
  late final Future<BooksRepository> _booksRepoFuture;

  final TextEditingController _searchCtrl = TextEditingController();
  String _query = '';
  DownloadsFilter _filter = DownloadsFilter.all;
  DownloadsSort _sort = DownloadsSort.status;

  // On-disk bytes per item. Measured once per item rather than in build(): the
  // page rebuilds on every progress tick, and scanning directories that often
  // would hammer the filesystem while a download is running.
  final Map<String, int> _bytesByItem = {};
  final Set<String> _sizingIds = {};

  Future<void> _ensureSizes(List<String> ids) async {
    final missing = ids
        .where((id) => !_bytesByItem.containsKey(id) && !_sizingIds.contains(id))
        .toList();
    if (missing.isEmpty) return;
    _sizingIds.addAll(missing);
    for (final id in missing) {
      final bytes = await DownloadStorage.downloadedBytesForItem(id);
      _bytesByItem[id] = bytes;
      _sizingIds.remove(id);
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    // make sure repo is initialized (no-op if already)
    widget.repo.init();

    _booksRepoFuture = BooksRepository.create();

    _updates = widget.repo.progressStream();
    _sub = _updates.listen((u) {
      _latest[u.task.taskId] = u;
      if (mounted) setState(() {}); // trigger rebuild
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  /// Get all item IDs that have downloads (tracked or in-progress)
  Future<List<String>> _getAllDownloadItemIds() async {
    final tracked = await widget.repo.listTrackedItemIds();
    final trackedSet = tracked.toSet();

    // Also check for items with active download tasks that might not be tracked yet
    try {
      final allRecords = await widget.repo.listAll();
      for (final record in allRecords) {
        final itemId = _deriveItemId(record, trackedSet);
        final isActive =
            record.status == TaskStatus.running ||
            record.status == TaskStatus.enqueued;
        final isPartial =
            record.status == TaskStatus.complete ||
            record.status == TaskStatus.enqueued ||
            record.status == TaskStatus.running;
        // Always include active; include partial only if we already have local
        if (itemId.isNotEmpty &&
            (isActive ||
                isPartial ||
                _latest.containsKey(record.task.taskId))) {
          trackedSet.add(itemId);
        }
      }
    } catch (_) {}

    return trackedSet.toList();
  }

  /// Extract libraryItemId from task metadata or group, with generous fallbacks.
  String? _extractItemId(String meta, Set<String> knownIds, {String? group}) {
    // Primary: JSON meta with common keys
    if (meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map) {
          final keys = ['libraryItemId', 'itemId', 'id'];
          for (final k in keys) {
            final v = decoded[k];
            if (v is String && v.isNotEmpty) return v;
          }
        }
      } catch (_) {}
    }
    // Secondary: task group; often "book-<id>" or just the id
    if (group != null && group.isNotEmpty) {
      if (group.startsWith('book-') && group.length > 5) {
        return group.substring(5);
      }
      return group;
    }
    // Tertiary: meta contains a known id
    for (final id in knownIds) {
      if (meta.contains(id)) return id;
    }
    return null;
  }

  /// Derive an item id from a TaskRecord with generous fallbacks.
  String _deriveItemId(TaskRecord record, Set<String> knownIds) {
    final meta = record.task.metaData ?? '';
    final id = _extractItemId(meta, knownIds, group: record.task.group);
    if (id != null && id.isNotEmpty) return id;
    if (record.task.group != null && record.task.group!.isNotEmpty)
      return record.task.group!;
    // Fallback to taskId to keep it visible if nothing else matches
    return record.task.taskId;
  }

  @override
  Widget build(BuildContext context) {
    // We rebuild on each stream event via setState above.
    final cs = Theme.of(context).colorScheme;
    return FutureBuilder<List<String>>(
      future: _getAllDownloadItemIds(),
      builder: (context, idsSnap) {
        final allIds = idsSnap.data ?? const <String>[];
        return FutureBuilder<BooksRepository>(
          future: _booksRepoFuture,
          builder: (context, repoSnap) {
            if (!repoSnap.hasData) {
              return const Scaffold(body: SkeletonList());
            }
            final repo = repoSnap.data!;
            return FutureBuilder<List<_DownloadEntry>>(
              future: _buildEntries(repo, allIds),
              builder: (context, entriesSnap) {
                final all = entriesSnap.data ?? const <_DownloadEntry>[];
                unawaited(_ensureSizes(all.map((e) => e.itemId).toList()));
                final entries = _visibleEntries(all);
                final totalBytes = all
                    .map((e) => _bytesByItem[e.itemId] ?? 0)
                    .fold<int>(0, (a, b) => a + b);
                final activeCount = all.where((e) => e.hasActive).length;

                return Scaffold(
                  body: NestedScrollView(
                    headerSliverBuilder:
                        (context, innerBoxIsScrolled) => [
                          SliverAppBar(
                            pinned: true,
                            backgroundColor: cs.surface,
                            surfaceTintColor: cs.surfaceTint,
                            elevation: 0,
                            toolbarHeight: 72,
                            titleSpacing: 20,
                            title: Row(
                              children: [
                                Icon(
                                  LucideIcons.download,
                                  color: cs.primary,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      'Downloads',
                                      style: Theme.of(context)
                                          .textTheme
                                          .headlineSmall
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -0.2,
                                          ),
                                    ),
                                    if (all.isNotEmpty)
                                      Text(
                                        _summaryLine(
                                          all.length,
                                          activeCount,
                                          totalBytes,
                                        ),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelMedium
                                            ?.copyWith(
                                              color: cs.onSurfaceVariant,
                                            ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                            actions: [
                              PopupMenuButton<DownloadsSort>(
                                tooltip: 'Sort',
                                initialValue: _sort,
                                icon: const Icon(LucideIcons.arrowUpDown),
                                onSelected:
                                    (v) => setState(() => _sort = v),
                                itemBuilder:
                                    (context) => const [
                                      PopupMenuItem(
                                        value: DownloadsSort.status,
                                        child: Text('Status'),
                                      ),
                                      PopupMenuItem(
                                        value: DownloadsSort.titleAsc,
                                        child: Text('Title A–Z'),
                                      ),
                                      PopupMenuItem(
                                        value: DownloadsSort.sizeDesc,
                                        child: Text('Largest first'),
                                      ),
                                    ],
                              ),
                              const SizedBox(width: 8),
                            ],
                          ),
                        ],
                    body: SafeArea(
                      top: false,
                      bottom: false,
                      left: false,
                      right: false,
                      child: Column(
                        children: [
                          if (all.isNotEmpty) ...[
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                              child: TextField(
                                controller: _searchCtrl,
                                onChanged:
                                    (v) => setState(() => _query = v),
                                decoration: InputDecoration(
                                  hintText: 'Search downloads',
                                  prefixIcon: const Icon(LucideIcons.search),
                                  suffixIcon:
                                      _query.isEmpty
                                          ? null
                                          : IconButton(
                                            icon: const Icon(LucideIcons.x),
                                            onPressed: () {
                                              _searchCtrl.clear();
                                              setState(() => _query = '');
                                            },
                                          ),
                                  filled: true,
                                  fillColor: cs.surfaceContainerHighest,
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(16),
                                    borderSide: BorderSide.none,
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ),
                            SizedBox(
                              height: 40,
                              child: ListView(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                children: [
                                  _filterChip('All', DownloadsFilter.all),
                                  const SizedBox(width: 8),
                                  _filterChip(
                                    'Downloading',
                                    DownloadsFilter.downloading,
                                  ),
                                  const SizedBox(width: 8),
                                  _filterChip(
                                    'Downloaded',
                                    DownloadsFilter.downloaded,
                                  ),
                                ],
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 8, 20, 6),
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: Text(
                                  'Swipe left on an item to remove downloaded files',
                                  style: Theme.of(context).textTheme.labelMedium
                                      ?.copyWith(color: cs.onSurfaceVariant),
                                ),
                              ),
                            ),
                          ],
                          Expanded(
                            child:
                                all.isEmpty
                                    ? _EmptyDownloads(cs: cs)
                                    : entries.isEmpty
                                    ? _NoMatches(cs: cs)
                                    : ListView.separated(
                                      itemCount: entries.length,
                                      separatorBuilder:
                                          (_, __) => const Divider(height: 1),
                                      itemBuilder:
                                          (_, i) => _tileFor(entries[i]),
                                    ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  String _summaryLine(int count, int active, int bytes) {
    final books = '$count book${count == 1 ? '' : 's'}';
    final size = bytes > 0 ? ' · ${_formatBytes(bytes)}' : '';
    final downloading = active > 0 ? ' · $active downloading' : '';
    return '$books$size$downloading';
  }

  Widget _filterChip(String label, DownloadsFilter value) {
    return FilterChip(
      label: Text(label),
      selected: _filter == value,
      onSelected: (_) => setState(() => _filter = value),
    );
  }

  /// Applies the search box, the filter chips and the sort menu.
  List<_DownloadEntry> _visibleEntries(List<_DownloadEntry> all) {
    final q = _query.trim().toLowerCase();
    var list =
        all.where((e) {
          switch (_filter) {
            case DownloadsFilter.downloading:
              if (!e.hasActive) return false;
              break;
            case DownloadsFilter.downloaded:
              if (!e.isComplete) return false;
              break;
            case DownloadsFilter.all:
              break;
          }
          if (q.isEmpty) return true;
          return e.title.toLowerCase().contains(q) ||
              (e.author ?? '').toLowerCase().contains(q);
        }).toList();

    switch (_sort) {
      case DownloadsSort.titleAsc:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        break;
      case DownloadsSort.sizeDesc:
        list.sort(
          (a, b) => (_bytesByItem[b.itemId] ?? 0).compareTo(
            _bytesByItem[a.itemId] ?? 0,
          ),
        );
        break;
      case DownloadsSort.status:
        // Active first, then partially downloaded, then complete.
        list.sort((a, b) {
          if (a.hasActive != b.hasActive) return a.hasActive ? -1 : 1;
          if (a.isComplete != b.isComplete) return a.isComplete ? 1 : -1;
          return 0;
        });
        break;
    }
    return list;
  }

  Widget _tileFor(_DownloadEntry e) {
    return Dismissible(
      key: ValueKey('dl-${e.itemId}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        color: Theme.of(context).colorScheme.error,
        child: Icon(
          LucideIcons.trash2,
          color: Theme.of(context).colorScheme.onError,
        ),
      ),
      confirmDismiss: (_) async => true,
      onDismissed: (_) async {
        await widget.repo.cancelForItem(e.itemId);
        await widget.repo.deleteLocal(e.itemId);
        _bytesByItem.remove(e.itemId);
        if (mounted) setState(() {});
      },
      child: _BookDownloadTile(
        itemId: e.itemId,
        title: e.title,
        author: e.author,
        coverUrl: e.coverUrl,
        durationMs: e.durationMs,
        sizeBytes: e.sizeBytes,
        taskGroup: e.taskGroup,
        taskFilename: e.taskFilename,
        repo: widget.repo,
        latest: _latest,
        hasLocalPrefetched: e.isComplete,
      ),
    );
  }

  /// Returns the download list as data (not widgets) so the page can search,
  /// filter and sort it.
  Future<List<_DownloadEntry>> _buildEntries(
    BooksRepository repo,
    List<String> ids,
  ) async {
    final entries = <_DownloadEntry>[];
    // Fetch once, not per-item, to avoid a listAll() storm on every progress tick.
    final recs = await widget.repo.listAll();
    final idSet = ids.toSet();
    for (final itemId in ids) {
      final records =
          recs.where((r) => _deriveItemId(r, idSet) == itemId).toList()
            ..sort(
              (a, b) =>
                  (a.task.filename ?? '').compareTo(b.task.filename ?? ''),
            );
      final total = records.length;
      final done = records.where((r) => r.status == TaskStatus.complete).length;
      final hasLocal = await widget.repo.hasLocalDownloads(itemId);

      final book = await repo.getBookFromDb(itemId);
      final firstTask = records.isNotEmpty ? records.first.task : null;

      // Live updates can show a task as active before the DB has records.
      bool hasLatestActive = false;
      for (final update in _latest.values) {
        String? metaId;
        final meta = update.task.metaData ?? '';
        if (meta.isNotEmpty) {
          try {
            final decoded = jsonDecode(meta);
            if (decoded is Map && decoded['libraryItemId'] is String) {
              metaId = decoded['libraryItemId'] as String;
            }
          } catch (_) {}
        }
        metaId ??=
            (update.task.group != null &&
                    update.task.group!.startsWith('book-') &&
                    update.task.group!.length > 5)
                ? update.task.group!.substring(5)
                : update.task.group;
        if (metaId != itemId) continue;
        if (update is TaskProgressUpdate) {
          hasLatestActive = true;
        } else if (update is TaskStatusUpdate &&
            (update.status == TaskStatus.running ||
                update.status == TaskStatus.enqueued)) {
          hasLatestActive = true;
        }
      }

      final hasActive =
          records.any(
            (r) =>
                r.status == TaskStatus.running ||
                r.status == TaskStatus.enqueued,
          ) ||
          hasLatestActive;
      final isComplete = hasLocal || (total > 0 && done == total);
      final isInProgress = hasActive || (done > 0 && done < total);
      if (!isComplete && !isInProgress) continue;

      entries.add(
        _DownloadEntry(
          itemId: itemId,
          title: book?.title ?? firstTask?.filename ?? 'Downloading…',
          author: book?.author ?? firstTask?.group,
          coverUrl: book?.coverUrl,
          durationMs: book?.durationMs,
          sizeBytes: book?.sizeBytes,
          taskGroup: firstTask?.group,
          taskFilename: firstTask?.filename,
          hasActive: hasActive,
          isComplete: isComplete,
        ),
      );
    }
    return entries;
  }
}

class _DownloadEntry {
  const _DownloadEntry({
    required this.itemId,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.durationMs,
    required this.sizeBytes,
    required this.taskGroup,
    required this.taskFilename,
    required this.hasActive,
    required this.isComplete,
  });

  final String itemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final int? durationMs;
  final int? sizeBytes;
  final String? taskGroup;
  final String? taskFilename;
  final bool hasActive;
  final bool isComplete;
}

class _NoMatches extends StatelessWidget {
  const _NoMatches({required this.cs});

  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        'No downloads match your search',
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
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
    this.taskGroup,
    this.taskFilename,
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
  final String? taskGroup;
  final String? taskFilename;

  @override
  State<_BookDownloadTile> createState() => _BookDownloadTileState();
}

class _BookDownloadTileState extends State<_BookDownloadTile> {
  List<TaskRecord> _records = const [];
  bool _hasLocal = false;
  int _localBytes = 0;
  Map<String, TaskUpdate> get _latest => widget.latest;
  String? get _taskGroup => widget.taskGroup;
  String? get _taskFilename => widget.taskFilename;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Match the parent's primary id-extraction rule (JSON meta keys, then
  /// group `book-<id>`/`<id>`) so this tile's grouping agrees with _buildTiles.
  String _deriveItemId(TaskRecord record) {
    final meta = record.task.metaData ?? '';
    if (meta.isNotEmpty) {
      try {
        final decoded = jsonDecode(meta);
        if (decoded is Map) {
          for (final k in const ['libraryItemId', 'itemId', 'id']) {
            final v = decoded[k];
            if (v is String && v.isNotEmpty) return v;
          }
        }
      } catch (_) {}
    }
    final group = record.task.group;
    if (group != null && group.isNotEmpty) {
      if (group.startsWith('book-') && group.length > 5) {
        return group.substring(5);
      }
      return group;
    }
    return record.task.taskId;
  }

  Future<void> _load() async {
    final all = await widget.repo.listAll();
    if (!mounted) return;
    setState(() {
      _records =
          all.where((r) {
              final id = _deriveItemId(r) == widget.itemId;
              return id;
            }).toList()
            ..sort(
              (a, b) =>
                  (a.task.filename ?? '').compareTo(b.task.filename ?? ''),
            );
    });
    try {
      final hasLocal =
          widget.hasLocalPrefetched ||
          await widget.repo.hasLocalDownloads(widget.itemId);
      int localBytes = 0;
      if (hasLocal) {
        // Sum file sizes
        final dir = await DownloadStorage.itemDir(widget.itemId);
        if (await dir.exists()) {
          final files =
              await dir.list().where((x) => x is File).cast<File>().toList();
          for (final f in files) {
            try {
              final len = await f.length();
              localBytes = localBytes + len;
            } catch (_) {}
          }
        }
      }
      if (mounted)
        setState(() {
          _hasLocal = hasLocal;
          _localBytes = localBytes;
        });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final total = _records.length;
    final done = _records.where((r) => r.status == TaskStatus.complete).length;
    final hasActive = _records.any(
      (r) => r.status == TaskStatus.running || r.status == TaskStatus.enqueued,
    );

    // Latest progress from stream (more accurate/continuous)
    double latestProgress = 0.0;
    bool hasLatestActive = false;
    bool latestComplete = false;
    bool latestQueued = false;
    int latestCount = 0;
    _latest.forEach((_, update) {
      final meta = update.task.metaData ?? '';
      String? itemId;
      if (meta.isNotEmpty) {
        try {
          final decoded = jsonDecode(meta);
          if (decoded is Map && decoded['libraryItemId'] is String) {
            itemId = decoded['libraryItemId'] as String;
          }
        } catch (_) {}
      }
      itemId ??= widget.itemId; // fallback if meta missing
      if (itemId == widget.itemId) {
        if (update is TaskProgressUpdate) {
          latestProgress += (update.progress ?? 0.0).clamp(0.0, 1.0);
          latestCount++;
          hasLatestActive = true;
          // Do NOT mark complete on progress alone; wait for status update or local files
        } else if (update is TaskStatusUpdate) {
          if (update.status == TaskStatus.running ||
              update.status == TaskStatus.enqueued) {
            hasLatestActive = true;
            if (update.status == TaskStatus.enqueued) {
              latestQueued = true;
            }
          }
          if (update.status == TaskStatus.complete) {
            latestComplete = true;
            hasLatestActive = false;
          }
        }
      }
    });
    if (latestCount > 0) {
      latestProgress = (latestProgress / latestCount).clamp(0.0, 1.0);
    }

    // Fallback to DB-based progress if no latest info
    TaskRecord? active;
    if (_records.isNotEmpty) {
      try {
        active = _records.firstWhere(
          (r) =>
              r.status == TaskStatus.running || r.status == TaskStatus.enqueued,
          orElse: () => _records.last,
        );
      } catch (_) {
        active = _records.last;
      }
    }
    double filePct = 0.0;
    int fileIndex =
        done +
        ((active != null && active.status != TaskStatus.complete) ? 1 : 0);
    if (active != null && active.status == TaskStatus.running) {
      filePct = (active.progress ?? 0.0).clamp(0.0, 1.0);
    }

    double overallPct;
    if (hasLatestActive && latestCount > 0) {
      overallPct = latestProgress;
    } else {
      overallPct =
          (total == 0 && _hasLocal)
              ? 1.0
              : total == 0
              ? 0.0
              : ((done.toDouble()) + filePct) / total.toDouble();
    }

    final isComplete =
        _hasLocal || latestComplete || (total > 0 && done == total);
    final isInProgress =
        hasActive || hasLatestActive || (done > 0 && done < total);

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      onTap: () {
        BookDetailPage.push(context, widget.itemId);
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
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
            ),
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isComplete) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(value: overallPct, minHeight: 6),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    total > 0
                        ? 'Overall ${(overallPct * 100).toStringAsFixed(0)}% • File ${fileIndex.clamp(1, total)} of $total'
                        : 'Queued…',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ),
                if (hasActive)
                  TextButton.icon(
                    onPressed: () async {
                      try {
                        await widget.repo.cancelForItem(widget.itemId);
                        await _load();
                      } catch (_) {}
                    },
                    icon: const Icon(LucideIcons.x, size: 16),
                    label: const Text('Cancel'),
                  ),
              ],
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              _metaLine(),
              style: Theme.of(
                context,
              ).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ],
      ),
      // No trailing actions; swipe-to-delete only
    );
  }

  String _metaLine() {
    final parts = <String>[];
    // Size
    final size =
        _hasLocal
            ? _formatBytes(_localBytes)
            : (widget.sizeBytes != null
                ? _formatBytes(widget.sizeBytes!)
                : null);
    if (size != null) parts.add(size);
    // Duration
    if (widget.durationMs != null && widget.durationMs! > 0)
      parts.add(_formatDurationMs(widget.durationMs!));
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
      child: const Icon(LucideIcons.bookOpen),
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
      child: Image.network(
        url,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => ph,
      ),
    );
  }
}

class _EmptyDownloads extends StatelessWidget {
  const _EmptyDownloads({required this.cs});

  final ColorScheme cs;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(LucideIcons.download, size: 48, color: cs.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No downloads yet', style: text.titleMedium),
            const SizedBox(height: 8),
            Text(
              'Download a book from its detail page to listen offline. '
              'Books download one at a time and queue up behind each other.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
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
