import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
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
  
  // Search functionality
  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  final _searchFocusNode = FocusNode();
  bool _searchVisible = false;
  String _query = '';
  
  // Connectivity tracking
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _isOnline = true;
  
  static const String _viewTypeKey = 'series_view_type_pref';
  static const String _searchKey = 'series_search_pref';

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _startConnectivityWatch();
    _loadViewTypePref().then((_) => _loadSearchPref().then((_) => _refresh(initial: true)));
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _connSub?.cancel();
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    super.dispose();
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

  Future<void> _loadSearchPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final searchQuery = prefs.getString(_searchKey);
      if (searchQuery != null) {
        _query = searchQuery;
        _searchCtrl.text = searchQuery;
      }
    } catch (_) {}
  }

  Future<void> _saveSearchPref(String query) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_searchKey, query);
    } catch (_) {}
  }

  Future<void> _startConnectivityWatch() async {
    final current = await Connectivity().checkConnectivity();
    if (mounted) setState(() => _isOnline = _isConnectedList(current));
    _connSub = Connectivity().onConnectivityChanged.listen((conn) {
      if (!mounted) return;
      setState(() => _isOnline = _isConnectedList(conn));
    });
  }

  bool _isConnectedList(List<ConnectivityResult> results) {
    for (final r in results) {
      if (r == ConnectivityResult.mobile ||
          r == ConnectivityResult.wifi ||
          r == ConnectivityResult.ethernet ||
          r == ConnectivityResult.vpn) {
        return true;
      }
    }
    return false;
  }

  void _toggleSearch() {
    setState(() {
      _searchVisible = !_searchVisible;
      if (_searchVisible) {
        // Focus on the search bar when showing it
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _searchFocusNode.requestFocus();
        });
      } else {
        // Clear search when hiding
        _searchFocusNode.unfocus();
      }
    });
  }

  /// Normalize series name by removing sequence numbers and extra formatting
  String _normalizeSeriesName(String seriesName) {
    // Remove common sequence patterns like "#1", "#2", "Book 1", etc.
    String normalized = seriesName
        .replaceAll(RegExp(r'\s*#\d+'), '') // Remove "#1", "#2", etc.
        .replaceAll(RegExp(r'\s*Book\s+\d+'), '') // Remove "Book 1", "Book 2", etc.
        .replaceAll(RegExp(r'\s*Volume\s+\d+'), '') // Remove "Volume 1", etc.
        .replaceAll(RegExp(r'\s*Part\s+\d+'), '') // Remove "Part 1", etc.
        .replaceAll(RegExp(r'\s*Episode\s+\d+'), '') // Remove "Episode 1", etc.
        .replaceAll(RegExp(r'\s*Chapter\s+\d+'), '') // Remove "Chapter 1", etc.
        .replaceAll(RegExp(r'\s*Season\s+\d+'), '') // Remove "Season 1", etc.
        .replaceAll(RegExp(r'\s*Series\s+\d+'), '') // Remove "Series 1", etc.
        .replaceAll(RegExp(r'\s*Trilogy\s+\d+'), '') // Remove "Trilogy 1", etc.
        .replaceAll(RegExp(r'\s*Saga\s+\d+'), '') // Remove "Saga 1", etc.
        .replaceAll(RegExp(r'\s*Chronicles\s+\d+'), '') // Remove "Chronicles 1", etc.
        .replaceAll(RegExp(r'\s*Diaries\s+\d+'), '') // Remove "Diaries 1", etc.
        .replaceAll(RegExp(r'\s*Files\s+\d+'), '') // Remove "Files 1", etc.
        .replaceAll(RegExp(r'\s*Sequence\s+\d+'), '') // Remove "Sequence 1", etc.
        .replaceAll(RegExp(r'\s*Universe\s+\d+'), '') // Remove "Universe 1", etc.
        .replaceAll(RegExp(r'\s*Collection\s+\d+'), '') // Remove "Collection 1", etc.
        .replaceAll(RegExp(r'\s*Cycle\s+\d+'), '') // Remove "Cycle 1", etc.
        .replaceAll(RegExp(r'\s*Saga\s*$'), '') // Remove trailing "Saga"
        .replaceAll(RegExp(r'\s*Trilogy\s*$'), '') // Remove trailing "Trilogy"
        .replaceAll(RegExp(r'\s*Chronicles\s*$'), '') // Remove trailing "Chronicles"
        .replaceAll(RegExp(r'\s*Diaries\s*$'), '') // Remove trailing "Diaries"
        .replaceAll(RegExp(r'\s*Files\s*$'), '') // Remove trailing "Files"
        .replaceAll(RegExp(r'\s*Sequence\s*$'), '') // Remove trailing "Sequence"
        .replaceAll(RegExp(r'\s*Universe\s*$'), '') // Remove trailing "Universe"
        .replaceAll(RegExp(r'\s*Collection\s*$'), '') // Remove trailing "Collection"
        .replaceAll(RegExp(r'\s*Cycle\s*$'), '') // Remove trailing "Cycle"
        .trim();
    
    // If the normalized name is empty or too short, use the original
    if (normalized.isEmpty || normalized.length < 3) {
      return seriesName;
    }
    
    return normalized;
  }

  Map<String, List<Book>> _filterData(Map<String, List<Book>> data) {
    if (_query.trim().isEmpty) return data;
    
    final query = _query.trim().toLowerCase();
    final filtered = <String, List<Book>>{};
    
    for (final entry in data.entries) {
      final name = entry.key.toLowerCase();
      if (name.contains(query)) {
        filtered[entry.key] = entry.value;
      } else {
        // Check if any book in the series/collection matches
        final matchingBooks = entry.value.where((book) {
          final title = book.title.toLowerCase();
          final author = (book.author ?? '').toLowerCase();
          return title.contains(query) || author.contains(query);
        }).toList();
        
        if (matchingBooks.isNotEmpty) {
          filtered[entry.key] = matchingBooks;
        }
      }
    }
    
    return filtered;
  }

  Future<void> _refresh({bool initial = false}) async {
    setState(() {
      if (initial) _loading = true;
      _error = null;
    });
    
    try {
      final repo = await _repoFut;
      
      // Load from local DB first (fast start)
      final all = await _loadAllBooksFromDb(repo);
      
      // Background refresh from server only when online
      if (_isOnline) {
        // Kick off background full sync
        Future.microtask(() async {
          try {
            await repo.syncAllBooksToDb(
              pageSize: 200, 
              removeDeleted: true,
            );
            if (!mounted) return;
            // Reload from DB after sync to get fresh data
            final fresh = await _loadAllBooksFromDb(repo);
            if (!mounted) return;
            _processBooksData(fresh);
          } catch (_) {}
        });
      }
      
      if (!mounted) return;
      _processBooksData(all);
      setState(() => _loading = false);
      
    } catch (e) {
      if (!mounted) return;
      setState(() { _loading = false; _error = e.toString(); });
    }
  }

  Future<List<Book>> _loadAllBooksFromDb(BooksRepository repo) async {
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
    return all;
  }

  void _processBooksData(List<Book> all) {
    debugPrint('Total books loaded: ${all.length}');
    for (final book in all.take(5)) {
      debugPrint('Book: "${book.title}" - Series: "${book.series}" - Collection: "${book.collection}"');
    }
    
    // Load series with normalized names
    final seriesMap = <String, List<Book>>{};
    for (final b in all) {
      final originalName = (b.series ?? '').trim();
      if (originalName.isEmpty) continue;
      
      final normalizedName = _normalizeSeriesName(originalName);
      (seriesMap[normalizedName] ??= <Book>[]).add(b);
      debugPrint('Series: "$originalName" -> "$normalizedName" - Book: "${b.title}"');
    }
    debugPrint('Total series found: ${seriesMap.length}');
    for (final entry in seriesMap.entries) {
      debugPrint('Series "${entry.key}": ${entry.value.length} books');
    }
    
    // Sort each series by sequence then title
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
    
    // Load collections with normalized names
    final collectionsMap = <String, List<Book>>{};
    for (final b in all) {
      final originalName = (b.collection ?? '').trim();
      if (originalName.isEmpty) continue;
      
      final normalizedName = _normalizeSeriesName(originalName);
      (collectionsMap[normalizedName] ??= <Book>[]).add(b);
      debugPrint('Collection: "$originalName" -> "$normalizedName" - Book: "${b.title}"');
    }
    debugPrint('Total collections found: ${collectionsMap.length}');
    for (final entry in collectionsMap.entries) {
      debugPrint('Collection "${entry.key}": ${entry.value.length} books');
    }
    
    // Sort each collection by sequence then title
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
    });
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
              FilledButton.icon(onPressed: () => _refresh(), icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final currentData = _viewType == SeriesViewType.series ? _series : _collections;
    final filteredData = _filterData(currentData);
    final isEmpty = filteredData.isEmpty;
    final keys = isEmpty ? <String>[] : filteredData.keys.toList()..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    
    // Calculate total count for display
    final totalCount = currentData.length;
    final filteredCount = filteredData.length;

    return RefreshIndicator(
      onRefresh: () => _refresh(),
      edgeOffset: 100,
      color: cs.primary,
      backgroundColor: cs.surface,
      child: CustomScrollView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverAppBar.medium(
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Series'),
                if (totalCount > 0)
                  Text(
                    _query.isNotEmpty 
                        ? '$filteredCount of $totalCount ${_viewType.name}'
                        : '$totalCount ${_viewType.name}',
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            pinned: true,
            backgroundColor: cs.surface,
            surfaceTintColor: cs.surfaceTint,
            elevation: 0,
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(28),
              child: _isOnline
                  ? const SizedBox.shrink()
                  : Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                      color: cs.errorContainer,
                      child: Row(
                        children: [
                          Icon(Icons.wifi_off_rounded, size: 16, color: cs.onErrorContainer),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Offline – showing cached ${_viewType.name}',
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: cs.onErrorContainer,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            actions: [
              // Search button
              IconButton.filledTonal(
                tooltip: 'Search',
                onPressed: _toggleSearch,
                icon: Icon(_searchVisible ? Icons.search_off_rounded : Icons.search_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: 8),
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
          // Search Bar
          SliverToBoxAdapter(
            child: AnimatedSize(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeInOut,
              child: _searchVisible
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                      child: Column(
                        children: [
                          // Modern search bar
                          Container(
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: cs.outline.withOpacity(0.1),
                                width: 1,
                              ),
                            ),
                            child: SearchBar(
                              controller: _searchCtrl,
                              focusNode: _searchFocusNode,
                              leading: Icon(
                                Icons.search_rounded,
                                color: cs.onSurfaceVariant,
                              ),
                              hintText: 'Search ${_viewType.name} or books...',
                              hintStyle: WidgetStateProperty.all(
                                TextStyle(color: cs.onSurfaceVariant),
                              ),
                              backgroundColor: WidgetStateProperty.all(Colors.transparent),
                              elevation: WidgetStateProperty.all(0),
                              onChanged: (val) {
                                setState(() => _query = val);
                                _saveSearchPref(val);
                                _searchDebounce?.cancel();
                                _searchDebounce = Timer(const Duration(milliseconds: 300), () {
                                  if (!mounted) return;
                                  setState(() {});
                                });
                              },
                              trailing: [
                                if (_query.isNotEmpty)
                                  IconButton(
                                    tooltip: 'Clear',
                                    onPressed: () {
                                      // Hide keyboard
                                      FocusScope.of(context).unfocus();
                                      _searchCtrl.clear();
                                      setState(() => _query = '');
                                      _saveSearchPref('');
                                    },
                                    icon: Icon(
                                      Icons.clear_rounded,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
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
                        _query.isNotEmpty 
                            ? 'No ${_viewType.name} found'
                            : (_viewType == SeriesViewType.series ? 'No series yet' : 'No collections yet'),
                        style: Theme.of(context).textTheme.titleLarge
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _query.isNotEmpty
                            ? 'Try adjusting your search terms'
                            : '${_viewType.name.capitalize()} appear when books are grouped together',
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
                  final items = filteredData[name]!;
                  return _viewType == SeriesViewType.series
                      ? _SeriesCard(
                          name: name,
                          books: items,
                          onTapBook: (b) {
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
                                child: BookDetailPage(bookId: b.id),
                              ),
                            );
                          },
                        )
                      : _CollectionCard(
                          name: name,
                          books: items,
                          onTapBook: (b) {
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
                                child: BookDetailPage(bookId: b.id),
                              ),
                            );
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


