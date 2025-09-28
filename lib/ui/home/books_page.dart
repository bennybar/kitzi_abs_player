import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';

import '../../core/books_repository.dart';
import '../../core/auth_repository.dart';
import '../../core/play_history_service.dart';
import '../../core/image_cache_manager.dart';
import '../../models/book.dart';
import '../../widgets/skeleton_widgets.dart';
import '../book_detail/book_detail_page.dart';
import '../../main.dart';

enum LibraryView { grid, list }
enum SortMode { nameAsc, addedDesc }

class BooksPage extends StatefulWidget {
  const BooksPage({super.key});

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> {
  late final Future<BooksRepository> _repoFut;
  List<Book> _books = [];
  int _currentPage = 1;
  bool _hasMore = true;
  bool _loadingMore = false;
  List<Book> _recentBooks = [];
  bool _loading = true;
  String? _error;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  bool _isOnline = true;
  final ScrollController _scrollCtrl = ScrollController();
  
  // Memory management
  final List<StreamSubscription> _subscriptions = [];
  final List<TextEditingController> _controllers = [];

  LibraryView _view = LibraryView.list;
  SortMode _sort = SortMode.addedDesc;
  String _query = '';
  bool _isEbookLibrary = false;

  static const _viewKey = 'library_view_pref';
  static const _sortKey = 'library_sort_pref';
  static const _searchKey = 'library_search_pref';

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  
  // Add controller to managed list
  void _addController(TextEditingController controller) {
    _controllers.add(controller);
  }

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _addController(_searchCtrl); // Track search controller
    _scrollCtrl.addListener(_onScrollChanged); // Add scroll listener for image preloading
    _startConnectivityWatch();
    _restorePrefs().then((_) {
      // Load recent first so the section appears immediately
      _loadRecentBooks();
      // Then refresh library: DB first, server in background
      _refresh(initial: true);
      _setupAutoRefresh();
    });
  }

  Widget _buildLoadingSkeleton(BuildContext context) {
    return const BooksPageSkeleton();
  }

  @override
  void dispose() {
    // Cancel all timers
    _timer?.cancel();
    _searchDebounce?.cancel();
    
    // Cancel all stream subscriptions
    _connSub?.cancel();
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();
    
    // Dispose all controllers
    _searchCtrl.dispose();
    for (final controller in _controllers) {
      controller.dispose();
    }
    _controllers.clear();
    
    // Dispose scroll controller
    _scrollCtrl.dispose();
    
    super.dispose();
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_viewKey);
    final s = prefs.getString(_sortKey);
    final q = prefs.getString(_searchKey);
    final mt = prefs.getString('books_library_media_type')?.toLowerCase();
    String? activeLibId = prefs.getString('books_library_id');

    if (v == 'list') _view = LibraryView.list;
    if (s == 'nameAsc') _sort = SortMode.nameAsc;
    if (q != null) {
      _query = q;
      _searchCtrl.text = q;
    }
    bool isEbook = (mt != null && mt.contains('ebook'));
    if (!isEbook && (mt == null || mt.isEmpty)) {
      // Fallback: query server for library mediaType
      try {
        final auth = await AuthRepository.ensure();
        final api = auth.api;
        final token = await api.accessToken();
        final tokenQS = (token != null && token.isNotEmpty) ? '?token=$token' : '';
        final resp = await api.request('GET', '/api/libraries$tokenQS');
        if (resp.statusCode == 200) {
          final bodyStr = resp.body;
          final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
          final list = (body is Map && body['libraries'] is List)
              ? (body['libraries'] as List)
              : (body is List ? body : const []);
          for (final it in list) {
            if (it is Map) {
              final m = it.cast<String, dynamic>();
              final id = (m['id'] ?? m['_id'] ?? '').toString();
              if (activeLibId != null && id == activeLibId) {
                final mediaType = (m['mediaType'] ?? m['type'] ?? '').toString().toLowerCase();
                await prefs.setString('books_library_media_type', mediaType);
                isEbook = mediaType.contains('ebook');
                break;
              }
            }
          }
        }
      } catch (_) {}
    }
    if (mounted) setState(() { _isEbookLibrary = isEbook; });
  }

  void _scrollToTop() {
    if (!_scrollCtrl.hasClients) return;
    _scrollCtrl.animateTo(
      0,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
    );
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

  Future<void> _saveViewPref(LibraryView v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewKey, v == LibraryView.grid ? 'grid' : 'list');
  }

  Future<void> _saveSortPref(SortMode s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        _sortKey, s == SortMode.nameAsc ? 'nameAsc' : 'addedDesc');
  }

  Future<void> _saveSearchPref(String q) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_searchKey, q);
  }

  

  void _setupAutoRefresh() {
    // Disabled: manual pull-to-refresh or toolbar refresh triggers updates.
  }

  Future<void> _refresh({bool initial = false}) async {
    setState(() {
      if (initial) _loading = true;
      _error = null;
    });
    try {
      final repo = await _repoFut;
      // Always read first page from local DB (fast start), then optionally refresh in background
      final q = _query.trim();
      final items = await repo.listBooksFromDbPaged(page: 1, limit: 50, query: q.isEmpty ? null : q);
      // Background refresh from server only when online
      final conn = await Connectivity().checkConnectivity();
      final online = conn.contains(ConnectivityResult.mobile) || conn.contains(ConnectivityResult.wifi) || conn.contains(ConnectivityResult.ethernet);
      if (online) {
        // Ensure first page is fresh from server
        await repo.fetchBooksPage(page: 1, limit: 50, query: q.isEmpty ? null : q);
        // Kick off background full sync for current mode (all or search)
        Future.microtask(() async {
          try {
            await repo.syncAllBooksToDb(
              pageSize: 100, 
              query: q.isEmpty ? null : q,
              removeDeleted: true, // Enable deletion of books removed from server
            );
            if (!mounted) return;
            // Reload first page from DB after sync to update counts
            final fresh = await repo.listBooksFromDbPaged(page: 1, limit: 50, query: q.isEmpty ? null : q);
            if (!mounted) return;
            setState(() {
              _books = fresh;
              _hasMore = fresh.length >= 50;
            });
          } catch (_) {}
        });
      } else if (initial && mounted) {
        _showNoInternetSnack();
      }
      if (!mounted) return;
      setState(() {
        _books = items;
        _loading = false;
        _currentPage = 1;
        _hasMore = items.length >= 50;
      });
      
      // Load recent books after main library
      if (!initial) {
        _loadRecentBooks();
      }
    } catch (e) {
      // Fallback to local DB if network fails (offline)
      try {
        final repo = await _repoFut;
        final local = await repo.listBooks();
        if (!mounted) return;
        setState(() {
          _books = local;
          _loading = false;
          _error = null;
        });
        if (mounted) _showNoInternetSnack();
        
        // Load recent books from local data
        _loadRecentBooks();
        return;
      } catch (_) {
      }
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _showNoInternetSnack() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No internet connection')),
    );
  }
  
  Future<void> _loadRecentBooks() async {
    try {
      final recent = await PlayHistoryService.getLastPlayedBooks(4);
      if (mounted) {
        setState(() {
          _recentBooks = recent;
        });
      }
    } catch (e) {
      // Don't fail the main UI if recent books fail to load
      // Set empty list to prevent UI errors
      if (mounted) {
        setState(() {
          _recentBooks = [];
        });
      }
    }
  }

  /// Pre-cache first N covers to disk/memory for snappy grid/list.
  void _warmCacheCovers(List<Book> items, {int count = 30}) {
    if (!mounted || items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final urls = items.take(count).map((b) => b.coverUrl).toList();
      await ImageCacheManager.preloadImages(urls, context);
    });
  }
  
  /// Smart image preloading based on scroll position
  void _onScrollChanged() {
    if (!_scrollCtrl.hasClients || _books.isEmpty) return;
    
    final position = _scrollCtrl.position;
    final itemHeight = 104.0; // Approximate item height
    final visibleStart = (position.pixels / itemHeight).floor();
    final visibleEnd = ((position.pixels + position.viewportDimension) / itemHeight).ceil();
    
    final currentIndex = (visibleStart + visibleEnd) ~/ 2;
    if (currentIndex >= 0 && currentIndex < _books.length) {
      final urls = _books.map((b) => b.coverUrl).toList();
      
      // Determine scroll direction
      String? direction;
      if (position.pixels > (position.maxScrollExtent * 0.8)) {
        direction = 'forward';
      } else if (position.pixels < (position.maxScrollExtent * 0.2)) {
        direction = 'reverse';
      }
      
      // Preload images around current position
      ImageCacheManager.preloadAroundIndex(urls, currentIndex, context, scrollDirection: direction);
    }
  }

  void _openDetails(Book b) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookDetailPage(bookId: b.id)),
    );
  }

  List<Book> _visibleBooks() {
    if (_isEbookLibrary) return const <Book>[];
    final q = _query.trim().toLowerCase();
    List<Book> list = q.isEmpty
        ? List<Book>.from(_books)
        : _books.where((b) {
      final t = b.title.toLowerCase();
      final a = (b.author ?? '').toLowerCase();
      return t.contains(q) || a.contains(q);
    }).toList();

    // Show only audiobooks
    list = list.where((b) => b.isAudioBook && (b.libraryId == null || !_isEbookLibrary)).toList();
    switch (_sort) {
      case SortMode.nameAsc:
        list.sort(
                (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()));
        break;
      case SortMode.addedDesc:
        list.sort((a, b) {
          final da = a.updatedAt;
          final db = b.updatedAt;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = _visibleBooks();

    return Scaffold(
      backgroundColor: cs.surface,
      body: RefreshIndicator(
        onRefresh: () => _refresh(),
        edgeOffset: 120,
        color: cs.primary,
        backgroundColor: cs.surface,
        child: CustomScrollView(
          controller: _scrollCtrl,
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          cacheExtent: 800,
          slivers: [
          // Material 3 large app bar style
          SliverAppBar.large(
            floating: false,
            pinned: true,
            backgroundColor: cs.surface,
            surfaceTintColor: cs.surfaceTint,
            elevation: 0,
            title: const Text('Library'),
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
                              'Offline – showing cached library',
                              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                                    color: cs.onErrorContainer,
                                  ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
            actions: [
              IconButton.filledTonal(
                tooltip: 'Scroll to top',
                onPressed: _loading ? null : _scrollToTop,
                icon: const Icon(Icons.vertical_align_top_rounded),
                style: IconButton.styleFrom(
                  backgroundColor: cs.surfaceContainerHighest,
                ),
              ),
              PopupMenuButton<SortMode>(
                tooltip: 'Sort',
                initialValue: _sort,
                onSelected: (mode) {
                  setState(() => _sort = mode);
                  _saveSortPref(mode);
                },
                icon: Icon(
                  Icons.sort_rounded,
                  color: cs.onSurfaceVariant,
                ),
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: SortMode.addedDesc,
                    child: ListTile(
                      leading: Icon(
                        Icons.schedule_rounded,
                        color: cs.primary,
                      ),
                      title: const Text('Added date (newest)'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  PopupMenuItem(
                    value: SortMode.nameAsc,
                    child: ListTile(
                      leading: Icon(
                        Icons.sort_by_alpha_rounded,
                        color: cs.primary,
                      ),
                      title: const Text('Name (A–Z)'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),

          // Enhanced Search Bar
          SliverToBoxAdapter(
            child: Padding(
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
                      leading: Icon(
                        Icons.search_rounded,
                        color: cs.onSurfaceVariant,
                      ),
                      hintText: 'Search books or authors...',
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
                          _restartSearchPagination();
                        });
                      },
                      trailing: [
                        if (_query.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear',
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                              _saveSearchPref('');
                              // Force re-fetch first page from server and restart pagination
                              _restartSearchPagination();
                            },
                            icon: Icon(
                              Icons.clear_rounded,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // View toggle removed – list only
                ],
              ),
            ),
          ),

          // Content
          if (_loading)
            SliverFillRemaining(child: _buildLoadingSkeleton(context))
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.error_outline_rounded,
                        size: 64,
                        color: cs.error,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Error loading library',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: cs.error,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: () => _refresh(),
                        icon: const Icon(Icons.refresh_rounded),
                        label: const Text('Try Again'),
                      ),
                      const SizedBox(height: 8),
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          // Force offline view from DB only
                          setState(() => _loading = true);
                          final repo = await _repoFut;
                          final local = await repo.listBooks();
                          if (!mounted) return;
                          setState(() {
                            _books = local;
                            _loading = false;
                            _error = null;
                          });
                        },
                        icon: const Icon(Icons.offline_pin_rounded),
                        label: const Text('Show Offline Library'),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else if (visible.isEmpty)
            SliverFillRemaining(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _query.isNotEmpty ? Icons.search_off_rounded : Icons.library_books_outlined,
                        size: 64,
                        color: cs.onSurfaceVariant,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        _query.isNotEmpty ? 'No books found' : 'Your library is empty',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: cs.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _query.isNotEmpty
                            ? 'Try adjusting your search terms'
                            : 'Add some books to get started',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          else ...[
            // Resume Playing Section
            if (_recentBooks.isNotEmpty) _buildResumePlayingSection(),
            // Audiobooks section title
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: Row(
                  children: [
                    Icon(
                      Icons.library_music_rounded,
                      color: Theme.of(context).colorScheme.primary,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Audiobooks',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 0.95,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Add small space from the Audiobooks title to the list
            SliverToBoxAdapter(child: SizedBox(height: 4)),
            _buildList(visible),
            _buildLoadMore(),
          ],
        ],
        ),
      ),
    );
  }

  Widget _buildGrid(List<Book> list) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final b = list[i];
          return _BookCard(
            key: ValueKey(b.id),
            book: b,
            onTap: b.isAudioBook ? () => _openDetails(b) : null,
          );
          },
          childCount: list.length,
        ),
      ),
    );
  }

  Widget _buildResumePlayingSection() {
    if (_isEbookLibrary) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.play_circle_outline_rounded,
                  color: Theme.of(context).colorScheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(
                  'Resume Playing',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 0.8, // further tighten spacing under the title
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // One-row, horizontally scrollable list (up to 6 books)
            Builder(
              builder: (context) {
                final visible = _recentBooks
                    .where((b) => b.isAudioBook)
                    .take(6)
                    .toList(growable: false);
                if (visible.isEmpty) return const SizedBox.shrink();
                return SizedBox(
                  height: 260,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.only(right: 4),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final book = visible[index];
                      return SizedBox(
                        width: 168,
                        child: _ResumeBookCard(
                          key: ValueKey(book.id),
                          book: book,
                          onTap: () => _openDetails(book),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildList(List<Book> list) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      sliver: SliverList.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final b = list[i];
          
          // Trigger load more when approaching end
          if (!_loadingMore && _hasMore && i >= list.length - 8) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && !_loadingMore && _hasMore) {
                _loadMore();
              }
            });
          }
          
          return _BookListTile(
            key: ValueKey(b.id), // Add key for better widget recycling
            book: b,
            onTap: b.isAudioBook ? () => _openDetails(b) : null,
          );
        },
      ),
    );
  }

  

  Widget _buildLoadMore() {
    if (!_hasMore) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: _loadingMore
              ? const CircularProgressIndicator()
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final repo = await _repoFut;
      final nextPage = _currentPage + 1;
      final q = _query.trim();
      debugPrint('[BOOKS_UI] loadMore: nextPage=$nextPage queryEmpty=${q.isEmpty}');
      // Try offset-first via full sync helper by requesting exactly one chunk
      await repo.syncAllBooksToDb(pageSize: 50, query: q.isEmpty ? null : q, onProgress: (p, _) {});
      // Then read the next page from DB
      final page = await repo.listBooksFromDbPaged(page: nextPage, limit: 50, query: q.isEmpty ? null : q);
      debugPrint('[BOOKS_UI] loadMore: dbPageLen=${page.length}');
      if (!mounted) return;
      setState(() {
        // Use DB-mapped rows to keep sorting consistent
        _books.addAll(page);
        _currentPage = nextPage;
        _hasMore = page.length >= 50;
      });
    } catch (_) {
      // ignore
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _restartSearchPagination() async {
    // Reset and fetch page 1 for current query
    setState(() {
      _loading = true;
      _currentPage = 1;
      _hasMore = true;
    });
    try {
      final repo = await _repoFut;
      final q = _query.trim();
      await repo.ensureServerPageIntoDb(page: 1, limit: 50, query: q.isEmpty ? null : q);
      final first = await repo.listBooksFromDbPaged(page: 1, limit: 50, query: q.isEmpty ? null : q);
      if (!mounted) return;
      setState(() {
        _books = first;
        _loading = false;
        _hasMore = first.length >= 50;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({super.key, required this.book, required this.onTap});
  final Book book;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = !book.isAudioBook;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: cs.outline.withOpacity(disabled ? 0.05 : 0.1),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Uniform cover size 2:3
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: cs.shadow.withOpacity(disabled ? 0.04 : 0.1),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Hero(
                  tag: 'home-cover-${book.id}',
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: AspectRatio(
                      aspectRatio: 2 / 3,
                      child: ColorFiltered(
                        colorFilter: disabled
                            ? ColorFilter.mode(cs.surface.withOpacity(0.12), BlendMode.saturation)
                            : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
                        child: EnhancedCoverImage(url: book.coverUrl),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 6),
              // Fixed text heights for consistency
              SizedBox(
                height: 34,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: Text(
                    book.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      height: 1.1,
                      color: disabled ? cs.onSurface.withOpacity(0.4) : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 2),
              SizedBox(
                height: 14,
                child: (book.author != null && book.author!.isNotEmpty)
                    ? Text(
                        book.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: disabled ? cs.onSurfaceVariant.withOpacity(0.4) : cs.onSurfaceVariant,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              if (disabled) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(Icons.block, size: 14, color: cs.onSurfaceVariant.withOpacity(0.6)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'Not an audiobook',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant.withOpacity(0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ResumeBookCard extends StatelessWidget {
  const _ResumeBookCard({super.key, required this.book, required this.onTap});
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: cs.outline.withOpacity(0.1),
          width: 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Square cover on top
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                  aspectRatio: 1.0,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: EnhancedCoverImage(url: book.coverUrl),
                      ),
                      // Top-right percentage indicator
                      Positioned(
                        top: 8,
                        right: 8,
                        child: FutureBuilder<Map<String, dynamic>>(
                          future: _getBookProgress(context, book.id),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return const SizedBox.shrink();
                            final progressInfo = snapshot.data!;
                            final raw = progressInfo['progress'] as double?;
                            final isCompleted = progressInfo['isCompleted'] as bool? ?? false;
                            if (raw == null && !isCompleted) return const SizedBox.shrink();
                            final pct = (isCompleted ? 1.0 : (raw ?? 0.0)).clamp(0.0, 1.0);
                            return Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.7),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                '${(pct * 100).round()}%',
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 10,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                      // Bottom progress bar overlay
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: FutureBuilder<Map<String, dynamic>>(
                          future: _getBookProgress(context, book.id),
                          builder: (context, snapshot) {
                            final progress = snapshot.hasData
                                ? (snapshot.data!['progress'] as double?)
                                : null;
                            final isCompleted = snapshot.hasData
                                ? (snapshot.data!['isCompleted'] as bool)
                                : false;
                            if (!isCompleted && (progress == null || progress <= 0)) {
                              return const SizedBox.shrink();
                            }
                            return Container(
                              height: 6,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.25),
                              ),
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final effective = isCompleted ? 1.0 : (progress ?? 0.0);
                                  final width = constraints.maxWidth * effective.clamp(0.0, 1.0);
                                  return Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      width: width,
                                      height: 6,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context).colorScheme.primary,
                                      ),
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 10),
              // Title and author below the cover
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (book.author != null && book.author!.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  book.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Get book progress using the same logic as book details (PlaybackRepository)
  Future<Map<String, dynamic>> _getBookProgress(BuildContext context, String bookId) async {
    try {
      final playback = ServicesScope.of(context).services.playback;
      final seconds = await playback.fetchServerProgress(bookId); // nullable seconds
      final isCompleted = await playback.isBookCompleted(bookId);
      double? progress;
      double? totalSeconds;
      try {
        final repo = await BooksRepository.create();
        final b = await repo.getBookFromDb(bookId);
        final ms = b?.durationMs;
        if (ms != null && ms > 0) totalSeconds = ms / 1000.0;
      } catch (_) {}
      if (seconds != null && totalSeconds != null && totalSeconds > 0) {
        progress = (seconds / totalSeconds).clamp(0.0, 1.0);
      } else {
        // Fallback: if server also returns absolute progress via legacy, reuse Auth API quickly
        try {
          final auth = await AuthRepository.ensure();
          final api = auth.api;
          final resp = await api.request('GET', '/api/me/progress/$bookId');
          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            if (data is Map<String, dynamic>) {
              if (data['progress'] is num) {
                progress = (data['progress'] as num).toDouble();
              } else if (data['currentTime'] is num && data['duration'] is num) {
                final currentTime = (data['currentTime'] as num).toDouble();
                final duration = (data['duration'] as num).toDouble();
                if (duration > 0) progress = currentTime / duration;
              }
            }
          }
        } catch (_) {}
      }
      return {
        'progress': progress,
        'isCompleted': isCompleted || (progress != null && progress >= 0.99),
      };
    } catch (_) {
      return {'progress': null, 'isCompleted': false};
    }
  }
}

class _BookListTile extends StatelessWidget {
  const _BookListTile({super.key, required this.book, required this.onTap});
  final Book book;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = !book.isAudioBook;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: cs.outline.withOpacity(disabled ? 0.05 : 0.1),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              // Enhanced cover with completion indicator
              Stack(
                children: [
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withOpacity(0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Hero(
                      tag: 'home-cover-${book.id}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: EnhancedCoverImage(url: book.coverUrl, width: 72, height: 72),
                      ),
                    ),
                  ),
                  // Completion checkmark overlay
                  if (book.isAudioBook)
                    FutureBuilder<bool>(
                      future: _checkIfCompleted(book.id),
                      builder: (context, snapshot) {
                        if (snapshot.data == true) {
                          return Positioned(
                            top: 4,
                            right: 4,
                            child: Container(
                              padding: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                color: Colors.green,
                                borderRadius: BorderRadius.circular(12),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withOpacity(0.3),
                                    blurRadius: 4,
                                    offset: const Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.check,
                                color: Colors.white,
                                size: 16,
                              ),
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                ],
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: disabled ? cs.onSurface.withOpacity(0.4) : null,
                      ),
                    ),
                    if (book.author != null && book.author!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        book.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: disabled ? cs.onSurfaceVariant.withOpacity(0.4) : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (disabled) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(Icons.block, size: 16, color: cs.onSurfaceVariant.withOpacity(0.6)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Not an audiobook (e.g., ebook/podcast)',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant.withOpacity(0.7),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              
              // Arrow indicator
              Icon(
                Icons.chevron_right_rounded,
                color: disabled ? cs.onSurfaceVariant.withOpacity(0.3) : cs.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Check if a book is completed by fetching from server
  Future<bool> _checkIfCompleted(String bookId) async {
    try {
      final auth = await AuthRepository.ensure();
      final api = auth.api;
      final resp = await api.request('GET', '/api/me/progress/$bookId');
      if (resp.statusCode != 200) return false;
      
      final data = jsonDecode(resp.body);
      if (data is Map<String, dynamic>) {
        // Check for isFinished field
        if (data['isFinished'] == true) return true;
        // Check for progress being 100% or very close
        if (data['progress'] is num) {
          final progress = (data['progress'] as num).toDouble();
          return progress >= 0.99; // Consider 99%+ as completed
        }
        // Check if currentTime is very close to duration
        if (data['currentTime'] is num && data['duration'] is num) {
          final currentTime = (data['currentTime'] as num).toDouble();
          final duration = (data['duration'] as num).toDouble();
          if (duration > 0) {
            final progress = currentTime / duration;
            return progress >= 0.99; // Consider 99%+ as completed
          }
        }
      }
      return false;
    } catch (e) {
      // Offline or error - return false to be conservative
      return false;
    }
  }
}

 

