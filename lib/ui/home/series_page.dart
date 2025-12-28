import 'package:flutter/material.dart';
import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../../core/books_repository.dart';
import '../../core/ui_prefs.dart';
import '../../models/book.dart';
import '../../models/series.dart';
import '../../utils/alphabet_utils.dart';
import '../../widgets/letter_scrollbar.dart';
import '../book_detail/book_detail_page.dart';
import '../../main.dart';

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
  StreamSubscription<Map<String, bool>>? _completionSub;
  Map<String, int> _seriesLetterIndex = <String, int>{};
  List<String> _seriesLetterOrder = const <String>[];
  int _seriesLetterDenominator = 1;
  final ScrollController _scrollCtrl = ScrollController();
  
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
  void didChangeDependencies() {
    super.didChangeDependencies();
    _completionSub ??= ServicesScope.of(context).services.playback.completionStatusStream.listen((event) {
      if (event.isEmpty) return;
      _SeriesBookStatusResolver.invalidate(event.keys);
      if (mounted) {
        setState(() {});
      }
    });
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
    _completionSub?.cancel();
    _scrollCtrl.dispose();
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

  void _prepareSeriesLetterAnchors(List<Series> seriesList) {
    final indices = <String, int>{};
    for (var i = 0; i < seriesList.length; i++) {
      final bucket = alphabetBucketFor(seriesList[i].name);
      indices.putIfAbsent(bucket, () => i);
    }
    _seriesLetterIndex = indices;
    _seriesLetterOrder = sortAlphabetBuckets(indices.keys);
    _seriesLetterDenominator = math.max(1, seriesList.length - 1);
  }

  void _scrollSeriesToLetter(String letter) {
    final index = _seriesLetterIndex[letter];
    if (index == null || !_scrollCtrl.hasClients) return;
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    if (maxScroll <= 0) {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
      return;
    }
    final ratio = (index / _seriesLetterDenominator).clamp(0.0, 1.0);
    _scrollCtrl.animateTo(
      ratio * maxScroll,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
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
    
    if (_viewType == SeriesViewType.series) {
      _prepareSeriesLetterAnchors(filteredSeries);
    } else {
      _seriesLetterIndex = <String, int>{};
      _seriesLetterOrder = const <String>[];
      _seriesLetterDenominator = 1;
    }
    
    // Calculate total count for display
    final totalCount = _viewType == SeriesViewType.series ? _series.length : _collections.length;
    final filteredCount = _viewType == SeriesViewType.series ? filteredSeries.length : filteredCollections.length;

    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () => _refresh(),
          edgeOffset: 100,
          color: cs.primary,
          backgroundColor: cs.surface,
          child: CustomScrollView(
            controller: _scrollCtrl,
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
                          // Material search bar
                          SearchBar(
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
                            backgroundColor: WidgetStateProperty.all(cs.surfaceContainerHighest),
                            elevation: WidgetStateProperty.all(0),
                            shape: WidgetStateProperty.all(
                              RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                            ),
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
                  ? ValueListenableBuilder<int>(
                      valueListenable: UiPrefs.seriesItemsPerRow,
                      builder: (context, itemsPerRow, _) {
                        // Use SliverList for single column (old layout), SliverGrid for multiple columns
                        if (itemsPerRow == 1) {
                          return SliverList.separated(
                            itemCount: filteredSeries.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 12),
                            itemBuilder: (context, i) {
                              final series = filteredSeries[i];
                              return _NewSeriesCard(
                                key: ValueKey('series-${series.id}'),
                                series: series,
                                itemsPerRow: itemsPerRow,
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) => SeriesBooksPage(
                                        series: series,
                                        getBooksForSeries: _getBooksForSeries,
                                      ),
                                    ),
                                  );
                                },
                                getBooksForSeries: _getBooksForSeries,
                              );
                            },
                          );
                        }
                        return SliverGrid(
                          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: itemsPerRow,
                            mainAxisSpacing: 12,
                            crossAxisSpacing: 12,
                            childAspectRatio: 0.75,
                          ),
                          delegate: SliverChildBuilderDelegate(
                            (context, i) {
                              final series = filteredSeries[i];
                              return _NewSeriesCard(
                                key: ValueKey('series-${series.id}'),
                                series: series,
                                itemsPerRow: itemsPerRow,
                                onTap: () {
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (context) => SeriesBooksPage(
                                        series: series,
                                        getBooksForSeries: _getBooksForSeries,
                                      ),
                                    ),
                                  );
                                },
                                getBooksForSeries: _getBooksForSeries,
                              );
                            },
                            childCount: filteredSeries.length,
                          ),
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
                                  borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                                ),
                                clipBehavior: Clip.antiAlias,
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
        ),
        _buildSeriesLetterScrollbar(context),
      ],
    );
  }
  
  Widget _buildSeriesLetterScrollbar(BuildContext context) {
    if (_viewType != SeriesViewType.series) return const SizedBox.shrink();
    final media = MediaQuery.of(context);
    return Positioned(
      right: 4,
      top: media.padding.top + 96,
      bottom: 32,
      child: ValueListenableBuilder<bool>(
        valueListenable: UiPrefs.letterScrollEnabled,
        builder: (_, enabled, __) {
          final visible = enabled && _seriesLetterOrder.length > 1 && !_loading;
          if (!visible) return const SizedBox.shrink();
          return SizedBox(
            width: 40,
            child: LetterScrollbar(
              letters: _seriesLetterOrder,
              visible: visible,
              onLetterSelected: _scrollSeriesToLetter,
            ),
          );
        },
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
    super.key,
    required this.series,
    required this.onTap,
    required this.getBooksForSeries,
    this.itemsPerRow = 2,
  });
  
  final Series series;
  final VoidCallback onTap;
  final Future<List<Book>> Function(Series) getBooksForSeries;
  final int itemsPerRow;

  @override
  State<_NewSeriesCard> createState() => _NewSeriesCardState();
}

class _NewSeriesCardState extends State<_NewSeriesCard> {
  List<Book>? _books;
  bool _loading = false;
  String? _lastSeriesId;

  @override
  void initState() {
    super.initState();
    _lastSeriesId = widget.series.id;
    _loadBooks();
  }

  @override
  void didUpdateWidget(_NewSeriesCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload books if series changed
    if (oldWidget.series.id != widget.series.id) {
      _lastSeriesId = widget.series.id;
      _loadBooks();
    }
  }

  Future<void> _loadBooks() async {
    setState(() => _loading = true);
    try {
      final books = await widget.getBooksForSeries(widget.series);
      if (mounted && widget.series.id == _lastSeriesId) {
        setState(() {
          _books = books;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted && widget.series.id == _lastSeriesId) {
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
    
    // Use old full-width layout when itemsPerRow is 1
    if (widget.itemsPerRow == 1) {
      return Card(
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: cs.outline.withOpacity(0.1), width: 1),
        ),
        margin: const EdgeInsets.symmetric(vertical: 6),
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(16),
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
                      child: Row(
                        children: [
                          Flexible(
                            child: Text(
                              widget.series.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '(${widget.series.numBooks})',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w400,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Show first 4 covers in a horizontal scrollable row
                _loading
                    ? const SizedBox(
                        height: 120,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    : _books == null || _books!.isEmpty
                        ? SizedBox(
                            height: 120,
                            child: Center(
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
                            ),
                          )
                        : _buildCoverGridOld(_books!.take(4).toList()),
              ],
            ),
          ),
        ),
      );
    }
    
    // New compact grid layout for itemsPerRow > 1
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outline.withOpacity(0.1), width: 1),
      ),
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Series name and count
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.collections_bookmark_rounded, size: 18, color: cs.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          widget.series.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '${widget.series.numBooks} ${widget.series.numBooks == 1 ? 'book' : 'books'}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              // Book covers - show up to 3 covers, smaller size
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : _books == null || _books!.isEmpty
                        ? Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.book_outlined, size: 32, color: cs.onSurfaceVariant.withOpacity(0.6)),
                                const SizedBox(height: 4),
                                Text(
                                  'No books',
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: cs.onSurfaceVariant.withOpacity(0.6),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : _buildCoverGrid(_books!.take(3).toList()),
              ),
            ],
          ),
        ),
      ),
    );
  }
  
  Widget _buildCoverGrid(List<Book> books) {
    if (books.isEmpty) return const SizedBox.shrink();
    
    // Show up to 3 covers in a row, evenly spaced
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: books.map((book) {
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(
              right: book == books.last ? 0 : 6,
            ),
            child: AspectRatio(
              aspectRatio: 0.7, // Taller aspect ratio for book covers
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CoverThumb(url: book.coverUrl),
                    Positioned(
                      top: 4,
                      left: 4,
                      child: _BookStatusIndicator(
                        book: book,
                        compact: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
  
  Widget _buildCoverGridOld(List<Book> books) {
    if (books.isEmpty) return const SizedBox.shrink();
    
    // Old layout: horizontal scrollable list of covers
    return SizedBox(
      height: 120,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: books.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final book = books[i];
          return SizedBox(
            width: 120,
            child: AspectRatio(
              aspectRatio: 1.0,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _CoverThumb(url: book.coverUrl),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _BookStatusIndicator(
                        book: book,
                        compact: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
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
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: books.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final b = books[i];
                  return SizedBox(
                    width: 120,
                    child: AspectRatio(
                    aspectRatio: 1.0,
                    child: InkWell(
                      onTap: () => onTapBook(b),
                      borderRadius: BorderRadius.circular(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _CoverThumb(url: b.coverUrl),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: _BookStatusIndicator(book: b, compact: true),
                            ),
                          ],
                        ),
                      ),
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
              height: 120,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: books.length,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (context, i) {
                  final b = books[i];
                  return SizedBox(
                    width: 120,
                    child: AspectRatio(
                    aspectRatio: 1.0,
                    child: InkWell(
                      onTap: () => onTapBook(b),
                      borderRadius: BorderRadius.circular(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _CoverThumb(url: b.coverUrl),
                            Positioned(
                              top: 8,
                              left: 8,
                              child: _BookStatusIndicator(book: b, compact: true),
                            ),
                          ],
                        ),
                      ),
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
        return Transform.scale(scale: 1.024, child: Image.file(f, fit: BoxFit.cover));
      }
    }
    return Transform.scale(scale: 1.024, child: Image.network(url, fit: BoxFit.cover));
  }
}

/// Page that displays all books in a series, similar to the books list page
class SeriesBooksPage extends StatefulWidget {
  const SeriesBooksPage({
    super.key,
    required this.series,
    required this.getBooksForSeries,
  });
  
  final Series series;
  final Future<List<Book>> Function(Series) getBooksForSeries;

  @override
  State<SeriesBooksPage> createState() => _SeriesBooksPageState();
}

class _SeriesBooksPageState extends State<SeriesBooksPage> {
  List<Book> _books = [];
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  int _currentPage = 1;
  bool _hasMore = true;
  final ScrollController _scrollCtrl = ScrollController();
  static const int _pageSize = 50;
  StreamSubscription<Map<String, bool>>? _completionSub;

  @override
  void initState() {
    super.initState();
    _scrollCtrl.addListener(_onScrollChanged);
    _loadBooks();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _completionSub ??= ServicesScope.of(context).services.playback.completionStatusStream.listen((event) {
      if (event.isEmpty) return;
      _SeriesBookStatusResolver.invalidate(event.keys);
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScrollChanged);
    _scrollCtrl.dispose();
    _completionSub?.cancel();
    super.dispose();
  }

  void _onScrollChanged() {
    if (!_scrollCtrl.hasClients) return;
    final position = _scrollCtrl.position;
    // Trigger load more when user scrolls to 80% of the content
    if (position.pixels >= position.maxScrollExtent * 0.8) {
      _loadMore();
    }
  }

  Future<void> _loadBooks() async {
    setState(() {
      _loading = true;
      _error = null;
      _books = [];
      _currentPage = 1;
      _hasMore = true;
    });
    
    try {
      final allBooks = await widget.getBooksForSeries(widget.series);
      if (mounted) {
        // Load first page
        final firstPage = allBooks.take(_pageSize).toList();
        setState(() {
          _books = firstPage;
          _loading = false;
          _currentPage = 1;
          _hasMore = allBooks.length > _pageSize;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    
    setState(() => _loadingMore = true);
    
    try {
      // Get all books (they're already cached from initial load)
      final allBooks = await widget.getBooksForSeries(widget.series);
      final nextPage = _currentPage + 1;
      final startIndex = (nextPage - 1) * _pageSize;
      final endIndex = startIndex + _pageSize;
      
      if (startIndex < allBooks.length) {
        final page = allBooks.sublist(
          startIndex,
          endIndex > allBooks.length ? allBooks.length : endIndex,
        );
        
        if (mounted) {
          setState(() {
            _books.addAll(page);
            _currentPage = nextPage;
            _hasMore = endIndex < allBooks.length;
          });
        }
      } else {
        if (mounted) {
          setState(() {
            _hasMore = false;
          });
        }
      }
    } catch (e) {
      // Error loading more - just stop trying
      if (mounted) {
        setState(() {
          _hasMore = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loadingMore = false);
      }
    }
  }

  void _openDetails(Book book) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        height: MediaQuery.of(context).size.height * 0.95,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        clipBehavior: Clip.antiAlias,
        child: BookDetailPage(bookId: book.id),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: CustomScrollView(
        controller: _scrollCtrl,
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        slivers: [
          SliverAppBar.large(
            floating: false,
            pinned: true,
            backgroundColor: cs.surface,
            surfaceTintColor: cs.surfaceTint,
            elevation: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.series.name,
                  style: textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${widget.series.numBooks} ${widget.series.numBooks == 1 ? 'book' : 'books'}',
                  style: textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_rounded),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          if (_loading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline_rounded, size: 48, color: cs.error),
                      const SizedBox(height: 12),
                      Text(
                        'Failed to load books',
                        style: textTheme.titleMedium?.copyWith(color: cs.error),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: textTheme.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed: _loadBooks,
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (_books.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.book_outlined, size: 64, color: cs.onSurfaceVariant),
                      const SizedBox(height: 16),
                      Text(
                        'No books in this series',
                        style: textTheme.titleLarge,
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              sliver: SliverList.separated(
                itemCount: _books.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, i) {
                  final book = _books[i];
                  return _SeriesBookCard(
                    book: book,
                    onTap: () => _openDetails(book),
                  );
                },
              ),
            ),
            _buildLoadMore(),
          ],
        ],
      ),
    );
  }

  Widget _buildLoadMore() {
    if (!_hasMore) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: _loadingMore
              ? const CircularProgressIndicator()
              : const SizedBox.shrink(),
        ),
      ),
    );
  }
}

class _SeriesBookCard extends StatelessWidget {
  const _SeriesBookCard({
    required this.book,
    required this.onTap,
  });
  
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: cs.outline.withOpacity(0.1), width: 1),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Cover
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: SizedBox(
                  width: 80,
                  height: 120,
                  child: _CoverThumb(url: book.coverUrl),
                ),
              ),
              const SizedBox(width: 12),
              // Title and author
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (book.author != null && book.author!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        book.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    _BookStatusIndicator(book: book),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _SeriesBookStatus { notStarted, inProgress, completed }

class _BookStatusIndicator extends StatelessWidget {
  const _BookStatusIndicator({
    required this.book,
    this.compact = false,
  });

  final Book book;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    return FutureBuilder<_SeriesBookStatus>(
      future: _SeriesBookStatusResolver.resolve(services, book),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return compact ? const SizedBox.shrink() : const SizedBox.shrink();
        }
        return _BookStatusBadge(
          status: snapshot.data!,
          compact: compact,
        );
      },
    );
  }
}

class _BookStatusBadge extends StatelessWidget {
  const _BookStatusBadge({
    required this.status,
    required this.compact,
  });

  final _SeriesBookStatus status;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    late final Color bg;
    late final Color fg;
    late final IconData icon;
    late final String label;

    switch (status) {
      case _SeriesBookStatus.completed:
        bg = cs.primaryContainer.withOpacity(0.95);
        fg = cs.onPrimaryContainer;
        icon = Icons.check_rounded;
        label = 'Completed';
        break;
      case _SeriesBookStatus.inProgress:
        bg = cs.tertiaryContainer.withOpacity(0.95);
        fg = cs.onTertiaryContainer;
        icon = Icons.play_arrow_rounded;
        label = 'In progress';
        break;
      case _SeriesBookStatus.notStarted:
        bg = cs.surfaceContainerHighest.withOpacity(0.9);
        fg = cs.onSurface;
        icon = Icons.circle_outlined;
        label = 'Not started';
        break;
    }

    if (compact) {
      return Tooltip(
        message: label,
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.18),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(icon, size: 14, color: fg),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _SeriesBookStatusResolver {
  static final Map<String, _CachedBookStatus> _cache = <String, _CachedBookStatus>{};
  static final Map<String, Future<_SeriesBookStatus>> _inFlight = <String, Future<_SeriesBookStatus>>{};
  static const Duration _ttl = Duration(minutes: 5);

  static Future<_SeriesBookStatus> resolve(AppServices services, Book book) {
    final id = book.id;
    final now = DateTime.now();
    final cached = _cache[id];
    if (cached != null) {
      if (now.difference(cached.timestamp) < _ttl) {
        return cached.future;
      }
      _cache.remove(id);
    }

    final pending = _inFlight[id];
    if (pending != null) return pending;

    final future = _fetchStatus(services, book).then((status) {
      final resolved = Future<_SeriesBookStatus>.value(status);
      _cache[id] = _CachedBookStatus(
        status: status,
        timestamp: DateTime.now(),
        future: resolved,
      );
      _inFlight.remove(id);
      return status;
    }).catchError((error) {
      _inFlight.remove(id);
      throw error;
    });

    _inFlight[id] = future;
    return future;
  }

  static void invalidate(Iterable<String> ids) {
    for (final id in ids) {
      _cache.remove(id);
      _inFlight.remove(id);
    }
  }

  static Future<_SeriesBookStatus> _fetchStatus(AppServices services, Book book) async {
    final snapshot = await _fetchProgressSnapshot(services, book.id);
    final playback = services.playback;

    if (snapshot.isFinished) {
      playback.completionCache[book.id] = true;
      return _SeriesBookStatus.completed;
    }

    double? durationSeconds = snapshot.duration;
    if ((durationSeconds == null || durationSeconds <= 0) && book.durationMs != null && book.durationMs! > 0) {
      durationSeconds = book.durationMs! / 1000;
    }

    double? ratio = snapshot.progress;
    if (ratio == null && snapshot.currentTime != null && durationSeconds != null && durationSeconds > 0) {
      ratio = (snapshot.currentTime! / durationSeconds).clamp(0.0, 1.0);
    }

    if (ratio != null) {
      if (ratio >= 0.99) {
        playback.completionCache[book.id] = true;
        return _SeriesBookStatus.completed;
      }
      if (ratio >= 0.01) {
        return _SeriesBookStatus.inProgress;
      }
      return _SeriesBookStatus.notStarted;
    }

    final seconds = snapshot.currentTime;
    if (seconds != null) {
      if (durationSeconds != null && durationSeconds > 0) {
        final approx = (seconds / durationSeconds).clamp(0.0, 1.0);
        if (approx >= 0.99) {
          playback.completionCache[book.id] = true;
          return _SeriesBookStatus.completed;
        }
        if (approx >= 0.01) {
          return _SeriesBookStatus.inProgress;
        }
        return _SeriesBookStatus.notStarted;
      }
      if (seconds >= 60) return _SeriesBookStatus.inProgress;
      if (seconds <= 5) return _SeriesBookStatus.notStarted;
      return _SeriesBookStatus.inProgress;
    }

    if (playback.completionCache[book.id] == true) {
      return _SeriesBookStatus.completed;
    }

    return _SeriesBookStatus.notStarted;
  }

  static Future<_ProgressSnapshot> _fetchProgressSnapshot(AppServices services, String bookId) async {
    try {
      final resp = await services.auth.api.request('GET', '/api/me/progress/$bookId');
      if (resp.statusCode != 200) return const _ProgressSnapshot();
      if (resp.body.isEmpty) return const _ProgressSnapshot();
      final decoded = jsonDecode(resp.body);
      final payload = _extractProgressMap(decoded);
      if (payload == null) return const _ProgressSnapshot();

      final currentTime = _asDouble(payload['currentTime']);
      final duration = _asDouble(payload['duration']);
      var progress = _asDouble(payload['progress']);
      final isFinished = payload['isFinished'] == true;

      if (progress == null && currentTime != null && duration != null && duration > 0) {
        progress = (currentTime / duration).clamp(0.0, 1.0);
      }

      return _ProgressSnapshot(
        currentTime: currentTime,
        duration: duration,
        progress: progress,
        isFinished: isFinished,
      );
    } catch (_) {
      return const _ProgressSnapshot();
    }
  }
}

class _CachedBookStatus {
  final _SeriesBookStatus status;
  final DateTime timestamp;
  final Future<_SeriesBookStatus> future;

  const _CachedBookStatus({
    required this.status,
    required this.timestamp,
    required this.future,
  });
}

class _ProgressSnapshot {
  final double? currentTime;
  final double? duration;
  final double? progress;
  final bool isFinished;

  const _ProgressSnapshot({
    this.currentTime,
    this.duration,
    this.progress,
    this.isFinished = false,
  });
}

Map<String, dynamic>? _extractProgressMap(dynamic raw) {
  if (raw is Map<String, dynamic>) {
    if (raw.containsKey('currentTime') ||
        raw.containsKey('progress') ||
        raw.containsKey('isFinished')) {
      return raw;
    }
    for (final value in raw.values) {
      final nested = _extractProgressMap(value);
      if (nested != null) return nested;
    }
  } else if (raw is Iterable) {
    for (final item in raw) {
      final nested = _extractProgressMap(item);
      if (nested != null) return nested;
    }
  }
  return null;
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}


