import 'package:flutter/material.dart';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../book_detail/book_detail_page.dart';

enum SeriesViewType { series, collections }

extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}

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
  Map<String, List<Book>> _collections = const {};
  SeriesViewType _viewType = SeriesViewType.series;
  
  static const String _viewTypeKey = 'series_view_type_pref';

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _loadViewTypePref().then((_) => _loadAll());
  }
  
  Future<void> _loadViewTypePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final viewTypeString = prefs.getString(_viewTypeKey);
      if (viewTypeString == 'collections') {
        _viewType = SeriesViewType.collections;
      } else {
        _viewType = SeriesViewType.series;
      }
    } catch (_) {
      // Keep default value
    }
  }
  
  Future<void> _saveViewTypePref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_viewTypeKey, _viewType.name);
    } catch (_) {}
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
      
      // Load series
      final seriesMap = <String, List<Book>>{};
      for (final b in all) {
        final name = (b.series ?? '').trim();
        if (name.isEmpty) continue;
        (seriesMap[name] ??= <Book>[]).add(b);
      }
      // keep only series with >= 2 books
      seriesMap.removeWhere((_, v) => v.length < 2);
      // sort each series by sequence then title
      for (final e in seriesMap.entries) {
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
      
      // Load collections
      final collectionsMap = <String, List<Book>>{};
      for (final b in all) {
        final name = (b.collection ?? '').trim();
        if (name.isEmpty) continue;
        (collectionsMap[name] ??= <Book>[]).add(b);
      }
      // keep only collections with >= 2 books
      collectionsMap.removeWhere((_, v) => v.length < 2);
      // sort each collection by sequence then title
      for (final e in collectionsMap.entries) {
        e.value.sort((a, b) {
          final sa = a.collectionSequence ?? double.nan;
          final sb = b.collectionSequence ?? double.nan;
          final aNum = !sa.isNaN;
          final bNum = !sb.isNaN;
          if (aNum && bNum) return sa.compareTo(sb);
          if (aNum && !bNum) return -1;
          if (!aNum && bNum) return 1;
          return a.title.toLowerCase().compareTo(b.title.toLowerCase());
        });
      }
      
      if (!mounted) return;
      setState(() { 
        _series = seriesMap; 
        _collections = collectionsMap;
        _loading = false; 
      });
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
              Text('Failed to load ${_viewType.name}', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: cs.error)),
              const SizedBox(height: 8),
              Text(_error!, textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
              const SizedBox(height: 12),
              FilledButton.icon(onPressed: _loadAll, icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final currentData = _viewType == SeriesViewType.series ? _series : _collections;
    final isEmpty = currentData.isEmpty;
    final keys = isEmpty ? <String>[] : currentData.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return RefreshIndicator(
      onRefresh: _loadAll,
      edgeOffset: 100,
      color: cs.primary,
      backgroundColor: cs.surface,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverAppBar.medium(
            title: const Text('Series'),
            pinned: true,
            backgroundColor: cs.surface,
            surfaceTintColor: cs.surfaceTint,
            elevation: 0,
            actions: [
              // Toggle between series and collections - always visible
              Container(
                margin: const EdgeInsets.only(right: 16),
                decoration: BoxDecoration(
                  color: cs.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildToggleButton(
                      context,
                      'Series',
                      SeriesViewType.series,
                      Icons.collections_bookmark_rounded,
                    ),
                    _buildToggleButton(
                      context,
                      'Collections',
                      SeriesViewType.collections,
                      Icons.folder_rounded,
                    ),
                  ],
                ),
              ),
            ],
          ),
          if (isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _viewType == SeriesViewType.series 
                          ? Icons.collections_bookmark_outlined 
                          : Icons.folder_outlined, 
                        size: 64, 
                        color: cs.onSurfaceVariant
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _viewType == SeriesViewType.series ? 'No series yet' : 'No collections yet',
                        style: Theme.of(context).textTheme.titleLarge
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${_viewType.name.capitalize()} appear when a group has 2 or more books',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant)
                      ),
                    ],
                  ),
                ),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              sliver: SliverList.builder(
                itemCount: keys.length,
                itemBuilder: (context, i) {
                  final name = keys[i];
                  final items = currentData[name]!;
                  return _viewType == SeriesViewType.series
                      ? _SeriesCard(
                          name: name,
                          books: items,
                          onTapBook: (b) {
                            Navigator.of(context).push(MaterialPageRoute(builder: (_) => BookDetailPage(bookId: b.id)));
                          },
                        )
                      : _CollectionCard(
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
  
  Widget _buildToggleButton(BuildContext context, String label, SeriesViewType type, IconData icon) {
    final cs = Theme.of(context).colorScheme;
    final isSelected = _viewType == type;
    
    return InkWell(
      onTap: () {
        setState(() {
          _viewType = type;
        });
        _saveViewTypePref();
      },
      borderRadius: BorderRadius.circular(24),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? cs.primary : Colors.transparent,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 16,
              color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: isSelected ? cs.onPrimary : cs.onSurfaceVariant,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
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

class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.name, required this.books, required this.onTapBook});
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
                Icon(Icons.folder_rounded, size: 20, color: cs.primary),
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


