import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../models/series.dart';
import '../book_detail/book_detail_page.dart';
import '../../widgets/glass_widget.dart';

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

class _SeriesPageState extends State<SeriesPage> with WidgetsBindingObserver {
  late final Future<BooksRepository> _repoFut;
  bool _loading = true;
  String? _error;
  List<Series> _series = const <Series>[];
  Map<String, List<Book>> _collections = const {};
  SeriesViewType _viewType = SeriesViewType.series;
  
  // Cache for series books to avoid repeated fetches
  final Map<String, List<Book>> _seriesBooksCache = <String, List<Book>>{};
  
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
    WidgetsBinding.instance.addObserver(this); // Observe app lifecycle
    _startConnectivityWatch();
    _loadViewTypePref().then((_) => _loadSearchPref().then((_) => _refresh(initial: true)));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Clear search when app is paused/detached
    if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
      if (_searchVisible && _query.isNotEmpty) {
        setState(() {
          _searchCtrl.clear();
          _query = '';
        });
        _saveSearchPref('');
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this); // Remove lifecycle observer
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
      // Don't restore search query - always start fresh with no search filter
      // Search is ephemeral and should not persist across page loads
    } catch (_) {}
  }

  Future<void> _saveSearchPref(String query) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (query.isEmpty) {
        // Remove the key entirely when clearing search
        await prefs.remove(_searchKey);
      } else {
        await prefs.setString(_searchKey, query);
      }
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
    // Cancel any pending search debounce when hiding
    if (_searchVisible) {
      _searchDebounce?.cancel();
    }
    
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
        _searchCtrl.clear();
        _query = '';
      }
    });
    
    // Refresh data when hiding search to clear filter
    if (!_searchVisible) {
      _saveSearchPref('');
      _refresh();
    }
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

  List<Series> _filterSeriesData(List<Series> data) {
    if (_query.trim().isEmpty) return data;
    
    final query = _query.trim().toLowerCase();
    return data.where((series) {
      final name = series.name.toLowerCase();
      final description = (series.description ?? '').toLowerCase();
      return name.contains(query) || description.contains(query);
    }).toList();
  }

  Map<String, List<Book>> _filterCollectionsData(Map<String, List<Book>> data) {
    if (_query.trim().isEmpty) return data;
    
    final query = _query.trim().toLowerCase();
    final filtered = <String, List<Book>>{};
    
    for (final entry in data.entries) {
      final name = entry.key.toLowerCase();
      if (name.contains(query)) {
        filtered[entry.key] = entry.value;
      } else {
        // Check if any book in the collection matches
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
      
      // For series, use the direct series API
      if (_isOnline) {
        // Fetch series directly from server
        // Fetching series from server
        final series = await repo.getAllSeries(sort: 'name', desc: false);
        // Fetched series from server
        
        if (!mounted) return;
        setState(() {
          _series = series;
          _loading = false;
        });
        
        // Also fetch collections in the background for the collections view
        Future.microtask(() async {
          try {
            final all = await _loadAllBooksFromDb(repo);
            if (!mounted) return;
            _processCollectionsData(all);
          } catch (_) {}
        });
      } else {
        // When offline, fall back to book grouping
        // Offline mode - falling back to book grouping
        final all = await _loadAllBooksFromDb(repo);
        if (!mounted) return;
        _processBooksDataFallback(all);
        setState(() => _loading = false);
      }
      
    } catch (e) {
      // Error fetching series
      if (!mounted) return;
      
      // Fallback to book grouping on error
      try {
        final repo = await _repoFut;
        final all = await _loadAllBooksFromDb(repo);
        if (!mounted) return;
        _processBooksDataFallback(all);
        setState(() => _loading = false);
      } catch (fallbackError) {
        setState(() { 
          _loading = false; 
          _error = 'Failed to load series: $e. Fallback also failed: $fallbackError'; 
        });
      }
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

  void _processCollectionsData(List<Book> all) {
    // Processing books for collections
    
    // Load collections with normalized names
    final collectionsMap = <String, List<Book>>{};
    for (final b in all) {
      final originalName = (b.collection ?? '').trim();
      if (originalName.isEmpty) continue;
      
      final normalizedName = _normalizeSeriesName(originalName);
      (collectionsMap[normalizedName] ??= <Book>[]).add(b);
    }
    // Total collections found
    
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
      _collections = collectionsMap;
    });
  }

  void _processBooksDataFallback(List<Book> all) {
    // Processing books (fallback mode)
    
    // Create fake Series objects from grouped books as fallback
    final seriesMap = <String, List<Book>>{};
    for (final b in all) {
      final originalName = (b.series ?? '').trim();
      if (originalName.isEmpty) continue;
      
      final normalizedName = _normalizeSeriesName(originalName);
      (seriesMap[normalizedName] ??= <Book>[]).add(b);
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

    // Convert to Series objects
    final seriesList = seriesMap.entries.map((entry) {
      final books = entry.value;
      final firstBook = books.first;
      return Series(
        id: 'fallback_${entry.key}',
        name: entry.key,
        numBooks: books.length,
        bookIds: books.map((b) => b.id).toList(),
        coverUrl: firstBook.coverUrl,
      );
    }).toList();

    // Created series from grouped books
    
    // Also process collections
    _processCollectionsData(all);
    
    if (!mounted) return;
    setState(() { 
      _series = seriesList;
    });
  }

  /// Get books for a series, using cache to avoid repeated fetches
  Future<List<Book>> _getBooksForSeries(Series series) async {
    // Check cache first
    if (_seriesBooksCache.containsKey(series.id)) {
      return _seriesBooksCache[series.id]!;
    }
    
    try {
      final repo = await _repoFut;
      final books = await repo.getBooksForSeries(series);
      
      // Cache the result
      _seriesBooksCache[series.id] = books;
      return books;
    } catch (e) {
      // Error fetching books for series
      return <Book>[];
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
              FilledButton.icon(onPressed: () => _refresh(), icon: const Icon(Icons.refresh_rounded), label: const Text('Retry')),
            ],
          ),
        ),
      );
    }

    final isEmpty = _viewType == SeriesViewType.series ? _series.isEmpty : _collections.isEmpty;
    
    // Filter data based on view type
    final filteredSeries = _viewType == SeriesViewType.series ? _filterSeriesData(_series) : <Series>[];
    final filteredCollections = _viewType == SeriesViewType.collections ? _filterCollectionsData(_collections) : <String, List<Book>>{};
    
    // Calculate total count for display
    final totalCount = _viewType == SeriesViewType.series ? _series.length : _collections.length;
    final filteredCount = _viewType == SeriesViewType.series ? filteredSeries.length : filteredCollections.length;

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
                          // Glass search bar
                          GlassContainer(
                            blur: 30,
                            opacity: 0.85,
                            borderRadius: 16,
                            borderWidth: 0.5,
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
              sliver: _viewType == SeriesViewType.series
                  ? SliverList.builder(
                      itemCount: filteredSeries.length,
                      itemBuilder: (context, i) {
                        final series = filteredSeries[i];
                        return _NewSeriesCard(
                          series: series,
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
                          getBooksForSeries: _getBooksForSeries,
                        );
                      },
                    )
                  : SliverList.builder(
                      itemCount: filteredCollections.length,
                      itemBuilder: (context, i) {
                        final entry = filteredCollections.entries.elementAt(i);
                        final name = entry.key;
                        final items = entry.value;
                        return _CollectionCard(
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

class _NewSeriesCard extends StatefulWidget {
  const _NewSeriesCard({
    required this.series,
    required this.onTapBook,
    required this.getBooksForSeries,
  });
  
  final Series series;
  final void Function(Book) onTapBook;
  final Future<List<Book>> Function(Series) getBooksForSeries;

  @override
  State<_NewSeriesCard> createState() => _NewSeriesCardState();
}

class _NewSeriesCardState extends State<_NewSeriesCard> {
  List<Book>? _books;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadBooks();
  }

  Future<void> _loadBooks() async {
    setState(() => _loading = true);
    try {
      final books = await widget.getBooksForSeries(widget.series);
      if (mounted) {
        setState(() {
          _books = books;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _books = <Book>[];
          _loading = false;
        });
      }
    }
  }

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
                  child: Text(
                    widget.series.name, 
                    maxLines: 1, 
                    overflow: TextOverflow.ellipsis, 
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
                  child: Text(
                    '${widget.series.numBooks}', 
                    style: Theme.of(context).textTheme.labelMedium?.copyWith(color: cs.onSurfaceVariant)
                  ),
                )
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: 140,
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _books == null || _books!.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.book_outlined, color: cs.onSurfaceVariant),
                              const SizedBox(height: 4),
                              Text(
                                'No books loaded',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                              ),
                            ],
                          ),
                        )
                      : ListView.separated(
                          scrollDirection: Axis.horizontal,
                          itemCount: _books!.length,
                          separatorBuilder: (_, __) => const SizedBox(width: 8),
                          itemBuilder: (context, i) {
                            final b = _books![i];
                            return AspectRatio(
                              aspectRatio: 2/3,
                              child: InkWell(
                                onTap: () => widget.onTapBook(b),
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


