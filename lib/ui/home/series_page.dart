import 'package:flutter/material.dart';
import 'dart:io';
import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../book_detail/book_detail_page.dart';

class SeriesPage extends StatefulWidget {
  const SeriesPage({super.key});

  @override
  State<SeriesPage> createState() => _SeriesPageState();
}

class _SeriesPageState extends State<SeriesPage> {
  late final Future<BooksRepository> _repoFut;
  bool _loading = true;
  String? _error;
  Map<String, List<Book>> _series = const {};

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() { _loading = true; _error = null; });
    try {
      final repo = await _repoFut;
      // Ensure full sync to DB then read everything from local DB (paged)
      await repo.syncAllBooksToDb(pageSize: 200);
      final all = <Book>[];
      int page = 1;
      const limit = 200;
      while (true) {
        final chunk = await repo.listBooksFromDbPaged(page: page, limit: limit);
        if (chunk.isEmpty) break;
        all.addAll(chunk);
        if (chunk.length < limit) break;
        page += 1;
      }
      // Avoid per-item network fetches here to keep UI responsive
      final map = <String, List<Book>>{};
      for (final b in all) {
        final name = (b.series ?? '').trim();
        if (name.isEmpty) continue;
        (map[name] ??= <Book>[]).add(b);
      }
      // keep only series with >= 2 books
      map.removeWhere((_, v) => v.length < 2);
      // sort each series by sequence then title
      for (final e in map.entries) {
        e.value.sort((a, b) {
          final sa = a.seriesSequence ?? double.nan;
          final sb = b.seriesSequence ?? double.nan;
          final aNum = !sa.isNaN;
          final bNum = !sb.isNaN;
          if (aNum && bNum) return sa.compareTo(sb);
          if (aNum && !bNum) return -1;
          if (!aNum && bNum) return 1;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      }
      if (!mounted) return;
      setState(() { _series = map; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
              const SizedBox(height: 12),
              Text('Failed to load series', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.error)),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _loadAll, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    if (_series.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.collections_bookmark_outlined, size: 64, color: cs.onSurfaceVariant),
              const SizedBox(height: 16),
              Text('No series yet', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text('Series appear when a collection has 2 or more books', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
            ],
          ),
        ),
      );
    }

    final keys = _series.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return RefreshIndicator(
      onRefresh: _loadAll,
      edgeOffset: 100,
      color: cs.primary,
      backgroundColor: cs.surface,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverAppBar(
            title: const Text('Series'),
            pinned: true,
            backgroundColor: cs.surface,
            elevation: 0,
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            sliver: SliverList.builder(
              itemCount: keys.length,
              itemBuilder: (context, i) {
                final name = keys[i];
                final items = _series[name]!;
                return _SeriesCard(
                  name: name,
                  books: items,
                  onTapBook: (b) {
                    Navigator.of(context).push(MaterialPageRoute(builder: (_) => BookDetailPage(bookId: b.id)));
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SeriesCard extends StatelessWidget {
  const _SeriesCard({required this.name, required this.books, required this.onTapBook});
  final String name;
  final List<Book> books;
  final void Function(Book) onTapBook;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outline.withOpacity(0.1), width: 1),
      ),
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.collections_bookmark_rounded, size: 20, color: cs.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                  child: Text('${books.length}', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)),
                )
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: books.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final b = books[i];
                  return AspectRatio(
                    aspectRatio: 2/3,
                    child: InkWell(
                      onTap: () => onTapBook(b),
                      borderRadius: BorderRadius.circular(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: _CoverThumb(url: b.coverUrl),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final uri = Uri.tryParse(url);
    if (uri != null && uri.scheme == 'file') {
      final f = File(uri.toFilePath());
      if (f.existsSync()) {
        return Image.file(f, fit: BoxFit.cover);
      }
    }
    return Image.network(url, fit: BoxFit.cover);
  }
}


