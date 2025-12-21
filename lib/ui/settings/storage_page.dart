import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/books_repository.dart';
import '../../core/download_storage.dart';
import '../../core/streaming_cache_service.dart';
import '../../main.dart';

class StoragePage extends StatefulWidget {
  const StoragePage({super.key});

  @override
  State<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends State<StoragePage> {
  bool _loading = true;
  String? _error;

  int _downloadBytesTotal = 0;
  int _streamCacheBytesTotal = 0;
  int _streamCacheLimitBytes = StreamingCacheService.defaultBytes;

  final List<_StorageItem> _items = <_StorageItem>[];
  BooksRepository? _booksRepo;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    final repo = _booksRepo;
    _booksRepo = null;
    unawaited(repo?.dispose());
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await StreamingCacheService.instance.init();
      _streamCacheLimitBytes = StreamingCacheService.instance.maxCacheBytes.value;

      final downloadsTotal = await DownloadStorage.totalDownloadedBytes();
      final streamTotal = await StreamingCacheService.instance.currentUsageBytes();

      final downloadIds = await DownloadStorage.listItemIdsWithLocalDownloads();
      final streamIds = await StreamingCacheService.instance.listCachedItemIds();
      final ids = <String>{...downloadIds, ...streamIds}.toList()..sort();

      // Recreate repo per load to avoid stale DB connections across library changes.
      final oldRepo = _booksRepo;
      _booksRepo = null;
      if (oldRepo != null) {
        unawaited(oldRepo.dispose());
      }
      final booksRepo = await BooksRepository.create();
      _booksRepo = booksRepo;

      final items = <_StorageItem>[];
      for (final id in ids) {
        final dlBytes = await DownloadStorage.downloadedBytesForItem(id);
        final scBytes = await StreamingCacheService.instance.usageBytesForItem(id);
        BookSummary summary;
        try {
          final b = await booksRepo.getBookFromDb(id);
          if (b != null) {
            summary = BookSummary(
              title: b.title.isNotEmpty ? b.title : id,
              author: b.author,
              coverUrl: b.coverUrl,
            );
          } else {
            summary = BookSummary(title: id, author: null, coverUrl: null);
          }
        } catch (_) {
          summary = BookSummary(title: id, author: null, coverUrl: null);
        }
        if (dlBytes == 0 && scBytes == 0) continue;
        items.add(_StorageItem(
          libraryItemId: id,
          title: summary.title,
          author: summary.author,
          coverUrl: summary.coverUrl,
          downloadBytes: dlBytes,
          streamCacheBytes: scBytes,
        ));
      }

      if (!mounted) return;
      setState(() {
        _downloadBytesTotal = downloadsTotal;
        _streamCacheBytesTotal = streamTotal;
        _items
          ..clear()
          ..addAll(items);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _clearStreamingCacheForItem(String itemId) async {
    await StreamingCacheService.instance.evictForItem(itemId);
    await _load();
  }

  Future<void> _clearDownloadsForItem(String itemId) async {
    final downloads = ServicesScope.of(context).services.downloads;
    await downloads.deleteLocal(itemId);
    await _load();
  }

  Future<void> _clearBothForItem(String itemId) async {
    await StreamingCacheService.instance.evictForItem(itemId);
    final downloads = ServicesScope.of(context).services.downloads;
    await downloads.deleteLocal(itemId);
    await _load();
  }

  Future<void> _clearAllStreamingCache() async {
    await StreamingCacheService.instance.clear();
    await _load();
  }

  Future<void> _deleteAllDownloads() async {
    final downloads = ServicesScope.of(context).services.downloads;
    await downloads.deleteAllLocal();
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Storage'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
                        const SizedBox(height: 12),
                        Text('Failed to load storage info', style: Theme.of(context).textTheme.titleMedium),
                        const SizedBox(height: 8),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 12),
                        FilledButton(
                          onPressed: _load,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    children: [
                      _OverviewCard(
                        downloadBytes: _downloadBytesTotal,
                        streamBytes: _streamCacheBytesTotal,
                        streamLimitBytes: _streamCacheLimitBytes,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _items.isEmpty ? null : _deleteAllDownloads,
                              icon: const Icon(Icons.delete_outline_rounded),
                              label: const Text('Delete all downloads'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _streamCacheBytesTotal == 0 ? null : _clearAllStreamingCache,
                              icon: const Icon(Icons.cached_rounded),
                              label: const Text('Clear streaming cache'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 20),
                      Text('Per book', style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      if (_items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 24),
                          child: Center(
                            child: Text(
                              'No downloads or streaming cache yet.',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ),
                        )
                      else
                        ..._items.map((it) => _StorageTile(
                              item: it,
                              onClearDownloads: () => _clearDownloadsForItem(it.libraryItemId),
                              onClearStreamCache: () => _clearStreamingCacheForItem(it.libraryItemId),
                              onClearBoth: () => _clearBothForItem(it.libraryItemId),
                            )),
                    ],
                  ),
                ),
    );
  }
}

class BookSummary {
  final String title;
  final String? author;
  final String? coverUrl;
  BookSummary({required this.title, required this.author, required this.coverUrl});
}

class _StorageItem {
  final String libraryItemId;
  final String title;
  final String? author;
  final String? coverUrl;
  final int downloadBytes;
  final int streamCacheBytes;

  const _StorageItem({
    required this.libraryItemId,
    required this.title,
    required this.author,
    required this.coverUrl,
    required this.downloadBytes,
    required this.streamCacheBytes,
  });

  int get totalBytes => downloadBytes + streamCacheBytes;
}

class _OverviewCard extends StatelessWidget {
  const _OverviewCard({
    required this.downloadBytes,
    required this.streamBytes,
    required this.streamLimitBytes,
  });

  final int downloadBytes;
  final int streamBytes;
  final int streamLimitBytes;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Overview', style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            _kvRow(context, Icons.download_rounded, 'Downloads', _formatBytes(downloadBytes), cs.primary),
            const SizedBox(height: 10),
            _kvRow(
              context,
              Icons.cached_rounded,
              'Streaming cache',
              '${_formatBytes(streamBytes)} / ${_formatBytes(streamLimitBytes)}',
              cs.secondary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _kvRow(BuildContext context, IconData icon, String k, String v, Color iconColor) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Row(
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(k, style: text.bodyLarge?.copyWith(fontWeight: FontWeight.w600)),
        ),
        Text(v, style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
      ],
    );
  }
}

class _StorageTile extends StatelessWidget {
  const _StorageTile({
    required this.item,
    required this.onClearDownloads,
    required this.onClearStreamCache,
    required this.onClearBoth,
  });

  final _StorageItem item;
  final Future<void> Function() onClearDownloads;
  final Future<void> Function() onClearStreamCache;
  final Future<void> Function() onClearBoth;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 10),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        leading: _Cover(url: item.coverUrl),
        title: Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if ((item.author ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  item.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 6),
            Text(
              _buildSizeLine(),
              style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
            ),
          ],
        ),
        trailing: PopupMenuButton<_StorageAction>(
          tooltip: 'Cleanup',
          onSelected: (action) async {
            switch (action) {
              case _StorageAction.clearDownloads:
                await onClearDownloads();
                break;
              case _StorageAction.clearStreamingCache:
                await onClearStreamCache();
                break;
              case _StorageAction.clearBoth:
                await onClearBoth();
                break;
            }
          },
          itemBuilder: (_) => [
            if (item.downloadBytes > 0)
              const PopupMenuItem(
                value: _StorageAction.clearDownloads,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.delete_outline_rounded),
                  title: Text('Delete downloads'),
                ),
              ),
            if (item.streamCacheBytes > 0)
              const PopupMenuItem(
                value: _StorageAction.clearStreamingCache,
                child: ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.cached_rounded),
                  title: Text('Clear streaming cache'),
                ),
              ),
            const PopupMenuItem(
              value: _StorageAction.clearBoth,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.cleaning_services_rounded),
                title: Text('Clear both'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _buildSizeLine() {
    final parts = <String>[];
    if (item.downloadBytes > 0) parts.add('Downloads ${_formatBytes(item.downloadBytes)}');
    if (item.streamCacheBytes > 0) parts.add('Cache ${_formatBytes(item.streamCacheBytes)}');
    if (parts.isEmpty) parts.add(_formatBytes(item.totalBytes));
    return parts.join(' • ');
  }
}

enum _StorageAction { clearDownloads, clearStreamingCache, clearBoth }

class _Cover extends StatelessWidget {
  const _Cover({required this.url});
  final String? url;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    final resolved = url;
    final uri = resolved != null ? Uri.tryParse(resolved) : null;
    return ClipRRect(
      borderRadius: radius,
      child: Container(
        width: 52,
        height: 52,
        color: cs.surfaceContainerHighest,
        child: (resolved == null || resolved.isEmpty)
            ? Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant)
            : (uri != null && uri.scheme == 'file')
                ? Image.file(
                    File(uri.toFilePath()),
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant),
                  )
                : Image.network(
                    resolved,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.menu_book_outlined, color: cs.onSurfaceVariant),
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

