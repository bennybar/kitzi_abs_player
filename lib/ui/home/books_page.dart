import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/books_repository.dart';
import '../../core/auth_repository.dart';
import '../../core/play_history_service.dart';
import '../../core/playback_repository.dart';
import '../../core/image_cache_manager.dart';
import '../../core/ui_prefs.dart';
import '../../models/book.dart';
import '../../widgets/skeleton_widgets.dart';
import '../../widgets/download_button.dart';
import '../../widgets/letter_scrollbar.dart';
import '../../widgets/author_card.dart';
import '../../widgets/glass_widget.dart';
import '../../utils/alphabet_utils.dart';
import '../book_detail/book_detail_page.dart';
import '../queue/queue_actions.dart';
import '../player/full_player_page.dart';
import '../profile/profile_page.dart';
import '../stats/stats_page.dart';
import '../home/series_page.dart';
import '../../models/series.dart';
import '../../main.dart';

// For unawaited background tasks
void _unawaited(Future<void> future) {
  unawaited(future);
}

enum LibraryView { grid, list }

enum SortMode { nameAsc, addedDesc }

enum LibraryFilter { all, notStarted, inProgress, finished }

class _ProgressEntry {
  const _ProgressEntry({required this.isFinished, required this.progress});
  final bool isFinished;
  final double progress; // 0..1
}

class BooksPage extends StatefulWidget {
  const BooksPage({super.key});

  @override
  State<BooksPage> createState() => _BooksPageState();
}

class _BooksPageState extends State<BooksPage> with WidgetsBindingObserver {
  late final Future<BooksRepository> _repoFut;
  List<Book> _books = [];
  bool _hasMore = true;
  bool _loadingMore = false;
  int _loadGen = 0;
  // Memoization for _visibleBooks(). _booksRev bumps on every mutation of
  // _books so the memo fires only when something actually changed.
  int _booksRev = 0;
  List<Book>? _memoVisible;
  int? _memoVisibleBooksRev;
  String? _memoVisibleQuery;
  LibraryFilter? _memoVisibleFilter;
  SortMode? _memoVisibleSort;
  bool? _memoVisibleForceAlpha;
  Map<String, _ProgressEntry>? _memoVisibleProgress;
  bool? _memoVisibleIsEbook;
  List<Book> _recentBooks = [];
  List<Book> _recentlyAdded = [];
  // Throttles the on-resume server refresh so rapid app-switching doesn't fire
  // a full refetch each time (the cache already paints the UI instantly).
  DateTime? _lastResumeRefreshAt;
  bool _loading = true;
  String? _error;
  bool _homeStatsLoading = false;
  int _todayListeningSeconds = 0;
  int _currentStreakDays = 0;
  int? _libraryTotalItems;
  Timer? _timer;
  final ScrollController _scrollCtrl = ScrollController();
  StreamSubscription<BookDbChange>? _dbChangeSub;
  Timer? _dbReloadDebounce;
  Future<void>? _activeSyncFuture;
  Map<String, int> _bookLetterIndex = <String, int>{};
  List<String> _bookLetterOrder = const <String>[];
  int _bookLetterDenominator = 1;
  VoidCallback? _letterScrollListener;
  VoidCallback? _letterScrollAlphaListener;
  VoidCallback? _hideSeriesListener;
  bool _hideSeriesWhenSameAsAuthor =
      UiPrefs.hideSeriesWhenSameAsAuthor.value;

  bool get _letterScrollEnabled => UiPrefs.letterScrollEnabled.value;
  bool get _booksLetterAlphaEnabled => UiPrefs.letterScrollBooksAlpha.value;
  bool get _forceAlphaSort => _letterScrollEnabled && _booksLetterAlphaEnabled;

  // Memory management
  final List<StreamSubscription> _subscriptions = [];
  final List<TextEditingController> _controllers = [];
  bool _completionListenerSetup = false;

  LibraryView _view = LibraryView.list;
  SortMode _sort = SortMode.addedDesc;
  LibraryFilter _filter = LibraryFilter.all;
  String _query = '';
  bool _isEbookLibrary = false;

  Map<String, _ProgressEntry> _progressByBookId = const {};

  static const _viewKey = 'library_view_pref';
  static const _sortKey = 'library_sort_pref';
  static const _filterKey = 'library_filter_pref';
  static const _searchKey = 'library_search_pref';

  final _searchCtrl = TextEditingController();
  Timer? _searchDebounce;
  final _searchFocusNode = FocusNode();
  bool _searchVisible = false;

  // Add controller to managed list
  void _addController(TextEditingController controller) {
    _controllers.add(controller);
  }

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _repoFut.then((repo) {
      if (!mounted) return;
      _dbChangeSub = repo.dbChanges.listen((_) => _scheduleDbCacheReload());
    });
    _addController(_searchCtrl); // Track search controller
    _scrollCtrl.addListener(
      _onScrollChanged,
    ); // Add scroll listener for image preloading
    WidgetsBinding.instance.addObserver(this); // Observe app lifecycle
    _restorePrefs().then((_) {
      // Load recent first so the section appears immediately
      _loadRecentBooks();
      _loadHomeStats();
      _loadProgressMap();
      _loadLibraryTotal();
      // Then refresh library: DB first, server in background
      _refresh(initial: true);
      _setupAutoRefresh();
    });
    _letterScrollListener = () {
      if (mounted) setState(() {});
    };
    _letterScrollAlphaListener = () {
      if (mounted) setState(() {});
    };
    UiPrefs.letterScrollEnabled.addListener(_letterScrollListener!);
    UiPrefs.letterScrollBooksAlpha.addListener(_letterScrollAlphaListener!);
    _hideSeriesListener = () {
      if (!mounted) return;
      final v = UiPrefs.hideSeriesWhenSameAsAuthor.value;
      if (v != _hideSeriesWhenSameAsAuthor) {
        setState(() => _hideSeriesWhenSameAsAuthor = v);
      }
    };
    UiPrefs.hideSeriesWhenSameAsAuthor.addListener(_hideSeriesListener!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Clear search when app is paused/detached
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (_searchVisible && _query.isNotEmpty) {
        setState(() {
          _searchCtrl.clear();
          _query = '';
        });
        _saveSearchPref('');
      }
    } else if (state == AppLifecycleState.resumed) {
      // Refresh books when app returns to foreground to check for new books,
      // but skip if we refreshed very recently — flipping away and back in
      // quick succession shouldn't trigger a full refetch each time.
      final now = DateTime.now();
      if (_lastResumeRefreshAt == null ||
          now.difference(_lastResumeRefreshAt!) > const Duration(seconds: 90)) {
        _lastResumeRefreshAt = now;
        _refresh();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Setup completion status listener after dependencies are available (only once)
    if (!_completionListenerSetup) {
      _setupCompletionStatusListener();
      _completionListenerSetup = true;
    }
  }

  Widget _buildLoadingSkeleton(BuildContext context) {
    return const BooksPageSkeleton();
  }

  @override
  void dispose() {
    // Remove lifecycle observer
    WidgetsBinding.instance.removeObserver(this);

    // Cancel all timers
    _timer?.cancel();
    _searchDebounce?.cancel();

    // Cancel all stream subscriptions
    if (_letterScrollListener != null) {
      UiPrefs.letterScrollEnabled.removeListener(_letterScrollListener!);
    }
    if (_letterScrollAlphaListener != null) {
      UiPrefs.letterScrollBooksAlpha.removeListener(
        _letterScrollAlphaListener!,
      );
    }
    if (_hideSeriesListener != null) {
      UiPrefs.hideSeriesWhenSameAsAuthor.removeListener(_hideSeriesListener!);
    }
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    _subscriptions.clear();

    // Dispose all controllers
    // Remove _searchCtrl from _controllers list first to avoid double-dispose
    _controllers.remove(_searchCtrl);
    _searchCtrl.dispose();
    _searchFocusNode.dispose();
    for (final controller in _controllers) {
      try {
        controller.dispose();
      } catch (_) {
        // Controller may already be disposed, ignore
      }
    }
    _controllers.clear();

    // Dispose scroll controller
    _scrollCtrl.dispose();
    _dbReloadDebounce?.cancel();
    _dbChangeSub?.cancel();
    _repoFut.then((repo) => repo.dispose());

    super.dispose();
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_viewKey);
    final s = prefs.getString(_sortKey);
    // Don't restore search query - always start fresh with no search filter
    final mt = prefs.getString('books_library_media_type')?.toLowerCase();
    String? activeLibId = prefs.getString('books_library_id');

    if (v == 'list') _view = LibraryView.list;
    if (s == 'nameAsc') _sort = SortMode.nameAsc;
    final fRaw = prefs.getString(_filterKey);
    switch (fRaw) {
      case 'notStarted': _filter = LibraryFilter.notStarted; break;
      case 'inProgress': _filter = LibraryFilter.inProgress; break;
      case 'finished':   _filter = LibraryFilter.finished;   break;
      default:           _filter = LibraryFilter.all;
    }
    // Search query is not restored - always starts empty
    bool isEbook = (mt != null && mt.contains('ebook'));
    if (!isEbook && (mt == null || mt.isEmpty)) {
      // Fallback: query server for library mediaType
      try {
        final auth = await AuthRepository.ensure();
        final api = auth.api;
        // auth:true attaches the Bearer header; no ?token query string is
        // needed (it would otherwise leak the access token into session logs).
        final resp = await api.request('GET', '/api/libraries', auth: true);
        if (resp.statusCode == 200) {
          final bodyStr = resp.body;
          final body = bodyStr.isNotEmpty ? jsonDecode(bodyStr) : null;
          final list =
              (body is Map && body['libraries'] is List)
                  ? (body['libraries'] as List)
                  : (body is List ? body : const []);
          for (final it in list) {
            if (it is Map) {
              final m = it.cast<String, dynamic>();
              final id = (m['id'] ?? m['_id'] ?? '').toString();
              if (activeLibId != null && id == activeLibId) {
                final mediaType =
                    (m['mediaType'] ?? m['type'] ?? '')
                        .toString()
                        .toLowerCase();
                await prefs.setString('books_library_media_type', mediaType);
                isEbook = mediaType.contains('ebook');
                break;
              }
            }
          }
        }
      } catch (_) {}
    }
    if (mounted)
      setState(() {
        _isEbookLibrary = isEbook;
      });
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

  void _setupCompletionStatusListener() {
    // Listen to completion status changes and refresh the UI
    final playback = ServicesScope.of(context).services.playback;
    final subscription = playback.completionStatusStream.listen((_) {
      if (mounted) {
        setState(() {
          // Trigger a rebuild to update completion status in the UI
        });
      }
    });
    _subscriptions.add(subscription);
  }

  /// Check if a book is completed by fetching from server
  Future<bool> _checkIfCompleted(String bookId) async {
    try {
      final playback = ServicesScope.of(context).services.playback;

      // Use cached completion status if available
      if (playback.completionCache.containsKey(bookId)) {
        return playback.completionCache[bookId]!;
      }

      // Otherwise fetch from server
      final auth = await AuthRepository.ensure();
      final api = auth.api;
      final resp = await api.request('GET', '/api/me/progress/$bookId');
      if (resp.statusCode != 200) return false;

      final data = jsonDecode(resp.body);
      if (data is Map<String, dynamic>) {
        // Check for isFinished field
        if (data['isFinished'] == true) {
          playback.completionCache[bookId] = true;
          return true;
        }
        // Check for progress being 100% or very close
        if (data['progress'] is num) {
          final progress = (data['progress'] as num).toDouble();
          final isCompleted = progress >= 0.99; // Consider 99%+ as completed
          playback.completionCache[bookId] = isCompleted;
          return isCompleted;
        }
        // Check if currentTime is very close to duration
        if (data['currentTime'] is num && data['duration'] is num) {
          final currentTime = (data['currentTime'] as num).toDouble();
          final duration = (data['duration'] as num).toDouble();
          if (duration > 0) {
            final progress = currentTime / duration;
            final isCompleted = progress >= 0.99; // Consider 99%+ as completed
            playback.completionCache[bookId] = isCompleted;
            return isCompleted;
          }
        }
      }
      playback.completionCache[bookId] = false;
      return false;
    } catch (e) {
      // Offline or error - return cached value if available, otherwise false
      final playback = ServicesScope.of(context).services.playback;
      return playback.completionCache[bookId] ?? false;
    }
  }

  Future<void> _saveViewPref(LibraryView v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_viewKey, v == LibraryView.grid ? 'grid' : 'list');
  }

  Future<void> _saveSortPref(SortMode s) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _sortKey,
      s == SortMode.nameAsc ? 'nameAsc' : 'addedDesc',
    );
  }

  Future<void> _saveFilterPref(LibraryFilter f) async {
    final prefs = await SharedPreferences.getInstance();
    String s;
    switch (f) {
      case LibraryFilter.notStarted: s = 'notStarted'; break;
      case LibraryFilter.inProgress: s = 'inProgress'; break;
      case LibraryFilter.finished:   s = 'finished';   break;
      case LibraryFilter.all:        s = 'all';        break;
    }
    await prefs.setString(_filterKey, s);
  }

  Future<void> _loadProgressMap() async {
    try {
      final auth = await AuthRepository.ensure();
      final api = auth.api;
      final resp = await api.request('GET', '/api/me', auth: true);
      if (resp.statusCode != 200) return;
      final data = jsonDecode(resp.body);
      if (data is! Map) return;
      final list = data['mediaProgress'];
      if (list is! List) return;
      final map = <String, _ProgressEntry>{};
      for (final e in list) {
        if (e is! Map) continue;
        final m = e.cast<String, dynamic>();
        final id = (m['libraryItemId'] ?? m['id'] ?? '').toString();
        if (id.isEmpty) continue;
        final isFinished = m['isFinished'] == true;
        double ratio = 0.0;
        final pr = m['progress'];
        if (pr is num) ratio = pr.toDouble();
        if (ratio <= 0) {
          final ct = m['currentTime'];
          final du = m['duration'];
          if (ct is num && du is num && du > 0) {
            ratio = (ct.toDouble() / du.toDouble());
          }
        }
        if (ratio.isNaN || ratio.isInfinite) ratio = 0.0;
        ratio = ratio.clamp(0.0, 1.0).toDouble();
        map[id] = _ProgressEntry(isFinished: isFinished, progress: ratio);
      }
      if (!mounted) return;
      setState(() => _progressByBookId = map);
      // A progress filter is driven by these ids, so the list it produced
      // before the map landed is stale.
      if (_filter != LibraryFilter.all) _loadBooksFromCache();
    } catch (_) {
      // offline: keep existing map
    }
  }

  Future<void> _saveSearchPref(String q) async {
    final prefs = await SharedPreferences.getInstance();
    if (q.isEmpty) {
      // Remove the key entirely when clearing search
      await prefs.remove(_searchKey);
    } else {
      await prefs.setString(_searchKey, q);
    }
  }

  void _setupAutoRefresh() {
    // Disabled: manual pull-to-refresh or toolbar refresh triggers updates.
  }

  /// [force] bypasses the ETag so a pull-to-refresh always hits the server.
  Future<void> _refresh({bool initial = false, bool force = false}) async {
    debugPrint('[REFRESH] Starting refresh (initial=$initial, force=$force)');
    // Always start from current cache for snappy UI
    await _loadBooksFromCache(showSpinner: initial && _books.isEmpty);
    debugPrint('[REFRESH] Loaded ${_books.length} books from cache');
    try {
      final conn = await Connectivity().checkConnectivity();
      final online =
          conn.contains(ConnectivityResult.mobile) ||
          conn.contains(ConnectivityResult.wifi) ||
          conn.contains(ConnectivityResult.ethernet) ||
          conn.contains(ConnectivityResult.vpn);
      if (!online) {
        debugPrint('[REFRESH] No internet connection');
        if (initial && mounted) _showNoInternetSnack();
        return;
      }
      debugPrint('[REFRESH] Online, proceeding with server sync');

      _unawaited(_loadProgressMap());

      final repo = await _repoFut;
      final q = _query.trim();

      // Always pull fresh data from server (ETag-aware; falls back to full fetch)
      debugPrint('[REFRESH] Calling refreshFromServer()...');
      final refreshedBooks = await repo.refreshFromServer(force: force);
      debugPrint(
        '[REFRESH] refreshFromServer returned ${refreshedBooks.length} books',
      );
      if (refreshedBooks.isNotEmpty) {
        debugPrint(
          '[REFRESH] First book: ${refreshedBooks.first.title} (id: ${refreshedBooks.first.id}, updatedAt: ${refreshedBooks.first.updatedAt})',
        );
      }

      // If searching, hydrate first page of the query too
      if (q.isNotEmpty) {
        debugPrint('[REFRESH] Query active: "$q", fetching first page...');
        final queryBooks = await repo.fetchBooksPage(
          page: 1,
          limit: 50,
          query: q,
        );
        debugPrint('[REFRESH] Query page returned ${queryBooks.length} books');
      }

      // Force incremental sync to ignore lastSync and traverse a few pages
      debugPrint('[REFRESH] Starting incremental sync with forceCheck=true...');
      await _startBackgroundSync(awaitCompletion: true, forceCheck: true);
      debugPrint('[REFRESH] Incremental sync completed');

      // Check for book updates (changed titles, album art, etc.)
      debugPrint('[REFRESH] Starting incremental update sync...');
      await repo.incrementalUpdateSync();
      debugPrint('[REFRESH] Incremental update sync completed');

      // Sync author metadata (images, descriptions)
      debugPrint('[REFRESH] Syncing author metadata...');
      await repo.syncAuthorMetadata();
      debugPrint('[REFRESH] Author metadata sync completed');

      // Reload from DB/cache to reflect any new books
      debugPrint('[REFRESH] Clearing cache and reloading from DB...');
      // Force clear the query cache to get fresh data
      // Clear cache by ensuring DB changes are processed
      await Future.delayed(const Duration(milliseconds: 100));
      await _loadBooksFromCache(showSpinner: false);
      debugPrint('[REFRESH] After reload, have ${_books.length} books in list');
      if (!initial) _loadRecentBooks();
      _loadHomeStats();
      _loadLibraryTotal();
      debugPrint('[REFRESH] Refresh complete');
    } catch (e, stackTrace) {
      debugPrint('[REFRESH] Error during refresh: $e');
      debugPrint('[REFRESH] Stack trace: $stackTrace');
      if (!mounted) return;
      if (_isTransientNetworkError(e)) {
        // Offline-first: a dropped/blip connection mid-refresh shouldn't alarm
        // the user — the cached library is still on screen. Only mention it if
        // the device is genuinely offline now (sanity check), and only on the
        // initial load so we don't nag on every auto/pull refresh.
        try {
          final conn = await Connectivity().checkConnectivity();
          final online = conn.contains(ConnectivityResult.mobile) ||
              conn.contains(ConnectivityResult.wifi) ||
              conn.contains(ConnectivityResult.ethernet) ||
              conn.contains(ConnectivityResult.vpn);
          if (!online && mounted && initial) _showNoInternetSnack();
        } catch (_) {}
      } else if (mounted) {
        // Genuine, non-network failure — friendly message, never the raw error.
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text("Couldn't refresh your library. Pull down to try again."),
          ),
        );
      }
    }
  }

  /// True for transient connectivity issues (dropped/blip connection, DNS,
  /// timeouts) that shouldn't surface a scary error in an offline-first app.
  bool _isTransientNetworkError(Object e) {
    final s = e.toString().toLowerCase();
    return s.contains('clientexception') ||
        s.contains('socketexception') ||
        s.contains('timeoutexception') ||
        s.contains('httpexception') ||
        s.contains('connection closed') ||
        s.contains('connection reset') ||
        s.contains('connection refused') ||
        s.contains('connection terminated') ||
        s.contains('connection attempt') ||
        s.contains('software caused connection abort') ||
        s.contains('failed host lookup') ||
        s.contains('network is unreachable') ||
        s.contains('handshake') ||
        s.contains('timed out') ||
        s.contains('timeout') ||
        s.contains('broken pipe');
  }

  void _showNoInternetSnack() {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('No internet connection')));
  }

  void _scheduleDbCacheReload() {
    _dbReloadDebounce?.cancel();
    _dbReloadDebounce = Timer(const Duration(milliseconds: 250), () {
      _dbReloadDebounce = null;
      if (!mounted) return;
      _reloadBooksFromCacheIfChanged();
    });
  }

  Future<void> _reloadBooksFromCacheIfChanged() async {
    try {
      final repo = await _repoFut;
      final q = _query.trim();
      // Preserve current scroll depth: reload at least as many items as the
      // user has already loaded (floor of 20 for the initial state).
      final reloadCount = _books.length < 20 ? 20 : _books.length;
      final fresh = await repo.listBooksFromDbPaged(
        page: 1,
        limit: reloadCount,
        query: q.isEmpty ? null : q,
      );
      if (!mounted) return;
      if (_bookListsMatch(_books, fresh)) return;
      setState(() {
        _books = fresh;
        _booksRev++;
        // Invalidate any in-flight _loadMore: the list was replaced wholesale,
        // so a page fetched against the old offset must not be appended.
        _loadGen++;
        // Assume more exists as long as we received a full reload.
        _hasMore = fresh.length >= reloadCount;
      });
    } catch (_) {}
  }

  /// The sort/filter the DB query must apply. Doing this in SQL rather than on
  /// the loaded page window is what makes sort and filter cover the whole
  /// library instead of just the books paged in so far.
  String get _dbSort =>
      (_forceAlphaSort || _sort == SortMode.nameAsc) ? 'nameAsc' : 'addedDesc';

  /// Book ids the current progress filter restricts to (`onlyIds`), or that it
  /// excludes (`excludeIds`). `_progressByBookId` comes from `/api/me`, so it
  /// covers every book the user has touched — not just the loaded ones.
  Set<String>? get _filterOnlyIds {
    switch (_filter) {
      case LibraryFilter.finished:
        return _progressByBookId.entries
            .where((e) => e.value.isFinished)
            .map((e) => e.key)
            .toSet();
      case LibraryFilter.inProgress:
        return _progressByBookId.entries
            .where((e) => !e.value.isFinished && e.value.progress > 0.0)
            .map((e) => e.key)
            .toSet();
      case LibraryFilter.notStarted:
      case LibraryFilter.all:
        return null;
    }
  }

  Set<String>? get _filterExcludeIds {
    if (_filter != LibraryFilter.notStarted) return null;
    return _progressByBookId.entries
        .where((e) => e.value.isFinished || e.value.progress > 0.0)
        .map((e) => e.key)
        .toSet();
  }

  Future<void> _loadBooksFromCache({bool showSpinner = false}) async {
    debugPrint('[LOAD_FROM_CACHE] Starting (query: "${_query.trim()}")');
    if (showSpinner) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final repo = await _repoFut;
      final q = _query.trim();
      final items = await repo.listBooksFromDbPaged(
        page: 1,
        limit: 20,
        sort: _dbSort,
        query: q.isEmpty ? null : q,
        onlyIds: _filterOnlyIds,
        excludeIds: _filterExcludeIds,
      );
      unawaited(_loadRecentlyAdded());
      debugPrint('[LOAD_FROM_CACHE] Loaded ${items.length} books from DB');
      if (items.isNotEmpty) {
        debugPrint(
          '[LOAD_FROM_CACHE] First book: "${items.first.title}" (id: ${items.first.id}, updatedAt: ${items.first.updatedAt?.toIso8601String() ?? "null"})',
        );
        debugPrint(
          '[LOAD_FROM_CACHE] Last book: "${items.last.title}" (id: ${items.last.id}, updatedAt: ${items.last.updatedAt?.toIso8601String() ?? "null"})',
        );
      }
      if (!mounted) {
        debugPrint('[LOAD_FROM_CACHE] Widget not mounted, skipping setState');
        return;
      }
      setState(() {
        _books = items;
        _booksRev++;
        // Invalidate any in-flight _loadMore: the list was replaced wholesale,
        // so a page fetched against the old offset must not be appended.
        _loadGen++;
        _loading = false;
        _hasMore = items.length >= 20;
        _error = null;
      });
      debugPrint(
        '[LOAD_FROM_CACHE] setState completed, _books.length=${_books.length}',
      );
    } catch (e, stackTrace) {
      debugPrint('[LOAD_FROM_CACHE] Error: $e');
      debugPrint('[LOAD_FROM_CACHE] Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  bool _bookListsMatch(List<Book> a, List<Book> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (_bookSignature(a[i]) != _bookSignature(b[i])) {
        return false;
      }
    }
    return true;
  }

  String _bookSignature(Book book) {
    final updated = book.updatedAt?.millisecondsSinceEpoch ?? 0;
    final duration = book.durationMs ?? 0;
    final size = book.sizeBytes ?? 0;
    return '${book.id}|$updated|${book.title}|${book.author ?? ''}|$duration|$size|${book.isAudioBook ? 1 : 0}';
  }

  Future<void> _loadRecentBooks() async {
    List<Book> fallback = const [];
    try {
      fallback = await PlayHistoryService.getLastPlayedBooksLocal(6);
    } catch (_) {}

    if (mounted &&
        fallback.isNotEmpty &&
        !_bookListsMatch(_recentBooks, fallback)) {
      setState(() => _recentBooks = fallback);
    }

    bool online = true;
    try {
      final conn = await Connectivity().checkConnectivity();
      online =
          conn.contains(ConnectivityResult.mobile) ||
          conn.contains(ConnectivityResult.wifi) ||
          conn.contains(ConnectivityResult.ethernet) ||
          conn.contains(ConnectivityResult.vpn);
    } catch (_) {}

    if (!online) return;

    try {
      final serverRecent = await PlayHistoryService.getLastPlayedBooks(6);
      if (!mounted) return;
      final next = serverRecent.isNotEmpty ? serverRecent : fallback;
      if (_bookListsMatch(_recentBooks, next)) return;
      setState(() {
        _recentBooks = next;
      });
    } catch (_) {
      // ignore; fallback already shown
    }
  }

  Future<void> _loadLibraryTotal() async {
    try {
      final repo = await _repoFut;
      final stats = await repo.getLibraryStats();
      final total = stats['totalItems'];
      if (!mounted) return;
      if (total is num) {
        setState(() => _libraryTotalItems = total.toInt());
      }
    } catch (_) {
      // Keep previous value; count falls back to loaded list size.
    }
  }

  Future<void> _loadHomeStats() async {
    if (_homeStatsLoading || !mounted) return;
    _homeStatsLoading = true;
    try {
      final auth = await AuthRepository.ensure();
      final api = auth.api;
      final response = await api.request(
        'GET',
        '/api/me/listening-stats',
        auth: true,
      );
      if (response.statusCode != 200) return;
      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return;
      final daysMap =
          (data['days'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
      final todayKey = _dayKey(DateTime.now());
      if (!mounted) return;
      setState(() {
        _todayListeningSeconds = _normalizeDaySeconds(daysMap)[todayKey] ?? 0;
        _currentStreakDays = _computeCurrentStreakDays(daysMap);
      });
    } catch (_) {
      // Keep home usable without stats when offline or unauthenticated.
    } finally {
      _homeStatsLoading = false;
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

  /// Smart image preloading based on scroll position.
  /// Throttled to avoid running on every scroll frame; also skips work when
  /// the center index hasn't changed. Also fires lazy-load near the bottom.
  int _lastPreloadIndex = -1;
  int _lastPreloadStampMs = 0;
  void _onScrollChanged() {
    if (!_scrollCtrl.hasClients || _books.isEmpty) return;

    final position = _scrollCtrl.position;

    // Lazy-load trigger — absorb-style: fire when within ~800px of the bottom.
    if (!_loadingMore &&
        _hasMore &&
        position.pixels >= position.maxScrollExtent - 800) {
      _loadMore();
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastPreloadStampMs < 120) return; // ~8 Hz
    const itemHeight = 104.0; // Approximate item height
    final visibleStart = (position.pixels / itemHeight).floor();
    final visibleEnd =
        ((position.pixels + position.viewportDimension) / itemHeight).ceil();

    final currentIndex = (visibleStart + visibleEnd) ~/ 2;
    if (currentIndex < 0 || currentIndex >= _books.length) return;
    if (currentIndex == _lastPreloadIndex) return;
    _lastPreloadIndex = currentIndex;
    _lastPreloadStampMs = nowMs;

    // Only build the small window of URLs needed for preload (±a few items),
    // avoiding an O(N) allocation per scroll tick.
    const behind = 1;
    const ahead = 3;
    final start = (currentIndex - behind).clamp(0, _books.length - 1);
    final end = (currentIndex + ahead).clamp(0, _books.length - 1);
    final windowUrls = <String>[
      for (int i = start; i <= end; i++) _books[i].coverUrl,
    ];

    String? direction;
    if (position.pixels > (position.maxScrollExtent * 0.8)) {
      direction = 'forward';
    } else if (position.pixels < (position.maxScrollExtent * 0.2)) {
      direction = 'reverse';
    }

    ImageCacheManager.preloadAroundIndex(
      windowUrls,
      currentIndex - start,
      context,
      scrollDirection: direction,
    );
  }

  void _openDetails(Book b) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder:
          (context) => Container(
            height: MediaQuery.of(context).size.height * 0.95,
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(24),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: BookDetailPage(bookId: b.id),
          ),
    );
  }

  Future<void> _showAuthorBooks(BuildContext context, String authorName) async {
    try {
      final repo = await _repoFut;
      final allAuthors = await repo.getAllAuthors();
      final authorInfo = allAuthors.firstWhere(
        (a) => a.name == authorName,
        orElse: () => AuthorInfo(name: authorName, books: []),
      );
      if (authorInfo.books.isEmpty) {
        // Try to get books by filtering current list
        final booksByAuthor =
            _books.where((b) => b.author == authorName).toList();
        if (booksByAuthor.isNotEmpty) {
          AuthorCard.show(
            context: context,
            author: AuthorInfo(name: authorName, books: booksByAuthor),
          );
          return;
        }
      } else {
        AuthorCard.show(context: context, author: authorInfo);
        return;
      }
    } catch (e) {
      // Fallback: try to get books from current list
      final booksByAuthor =
          _books.where((b) => b.author == authorName).toList();
      if (booksByAuthor.isNotEmpty) {
        AuthorCard.show(
          context: context,
          author: AuthorInfo(name: authorName, books: booksByAuthor),
        );
      }
    }
  }

  Future<void> _showSeriesBooks(BuildContext context, String seriesName) async {
    try {
      final repo = await _repoFut;
      // Create a minimal Series object - getBooksForSeries will load books by name if bookIds is empty
      final series = Series(
        id: seriesName, // Use series name as ID for lookup
        name: seriesName,
        numBooks: 0, // Will be updated when books are loaded
        bookIds: const [], // Empty - will trigger loading by series name
      );
      final books = await repo.getBooksForSeries(series);
      if (books.isEmpty) return;

      // Create a proper Series object with the loaded books
      final seriesWithBooks = Series(
        id: seriesName,
        name: seriesName,
        numBooks: books.length,
        bookIds: books.map((b) => b.id).toList(),
      );

      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        isDismissible: true,
        enableDrag: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder:
            (context) => DraggableScrollableSheet(
              initialChildSize: 0.95,
              minChildSize: 0.3,
              maxChildSize: 0.95,
              builder:
                  (context, scrollController) => Container(
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(24),
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        // Drag handle indicator
                        Container(
                          margin: const EdgeInsets.only(top: 8, bottom: 4),
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant.withOpacity(0.4),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        Expanded(
                          child: SeriesBooksPage(
                            series: seriesWithBooks,
                            getBooksForSeries: (s) => repo.getBooksForSeries(s),
                          ),
                        ),
                      ],
                    ),
                  ),
            ),
      );
    } catch (e) {
      // Silently fail if series can't be loaded
    }
  }

  List<Book> _visibleBooks() {
    final q = _query.trim();
    // Memo: return the prior result when nothing relevant changed.
    if (_memoVisible != null &&
        _memoVisibleBooksRev == _booksRev &&
        _memoVisibleQuery == q &&
        _memoVisibleFilter == _filter &&
        _memoVisibleSort == _sort &&
        _memoVisibleForceAlpha == _forceAlphaSort &&
        identical(_memoVisibleProgress, _progressByBookId) &&
        _memoVisibleIsEbook == _isEbookLibrary) {
      return _memoVisible!;
    }

    final result = _computeVisibleBooks(q);

    _memoVisible = result;
    _memoVisibleBooksRev = _booksRev;
    _memoVisibleQuery = q;
    _memoVisibleFilter = _filter;
    _memoVisibleSort = _sort;
    _memoVisibleForceAlpha = _forceAlphaSort;
    _memoVisibleProgress = _progressByBookId;
    _memoVisibleIsEbook = _isEbookLibrary;
    return result;
  }

  List<Book> _computeVisibleBooks(String rawQuery) {
    if (_isEbookLibrary) return const <Book>[];
    final q = rawQuery.toLowerCase();
    List<Book> list =
        q.isEmpty
            ? List<Book>.from(_books)
            : _books.where((b) {
              final t = b.title.toLowerCase();
              final a = (b.author ?? '').toLowerCase();
              return t.contains(q) || a.contains(q);
            }).toList();

    // Show only audiobooks
    list =
        list
            .where(
              (b) => b.isAudioBook && (b.libraryId == null || !_isEbookLibrary),
            )
            .toList();

    // Progress filter
    if (_filter != LibraryFilter.all) {
      list = list.where((b) {
        final e = _progressByBookId[b.id];
        final isFinished = e?.isFinished ?? false;
        final progress = e?.progress ?? 0.0;
        switch (_filter) {
          case LibraryFilter.finished:
            return isFinished;
          case LibraryFilter.notStarted:
            return !isFinished && progress <= 0.0;
          case LibraryFilter.inProgress:
            return !isFinished && progress > 0.0;
          case LibraryFilter.all:
            return true;
        }
      }).toList();
    }

    final sortMode = _forceAlphaSort ? SortMode.nameAsc : _sort;
    switch (sortMode) {
      case SortMode.nameAsc:
        list.sort(
          (a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase()),
        );
        break;
      case SortMode.addedDesc:
        list.sort((a, b) {
          // Use addedAt if available, fallback to updatedAt for backward compatibility
          final da = a.addedAt ?? a.updatedAt;
          final db = b.addedAt ?? b.updatedAt;
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });
        break;
    }
    return list;
  }

  Future<double> _fetchProgress(String bookId) async {
    try {
      final playback = ServicesScope.of(context).services.playback;
      final progress = await playback.fetchServerProgress(bookId);
      if (progress != null && progress > 0) {
        // Fetch duration to calculate percentage
        final repo = await _repoFut;
        final book = await repo.getBookFromDb(bookId);
        if (book != null && book.durationMs != null && book.durationMs! > 0) {
          final durationSec = book.durationMs! / 1000;
          return (progress / durationSec).clamp(0.0, 1.0);
        }
      }
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  void _prepareBookLetterAnchors(List<Book> books) {
    final indices = <String, int>{};
    for (var i = 0; i < books.length; i++) {
      final bucket = alphabetBucketFor(books[i].title);
      indices.putIfAbsent(bucket, () => i);
    }
    _bookLetterIndex = indices;
    _bookLetterOrder = sortAlphabetBuckets(indices.keys);
    _bookLetterDenominator = math.max(1, books.length - 1);
  }

  void _scrollToBookLetter(String letter) {
    final index = _bookLetterIndex[letter];
    if (index == null) return;
    if (!_scrollCtrl.hasClients) return;
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    if (maxScroll <= 0) {
      _scrollCtrl.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final ratio = (index / _bookLetterDenominator).clamp(0.0, 1.0);
    final target = ratio * maxScroll;
    _scrollCtrl.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  int _computeCurrentStreakDays(Map<String, dynamic> days) {
    if (days.isEmpty) return 0;
    final daySeconds = _normalizeDaySeconds(days);
    var today = DateTime.now();
    today = DateTime(today.year, today.month, today.day);
    var streak = 0;
    for (var i = 0; i < 3650; i++) {
      final d = today.subtract(Duration(days: i));
      final sec = daySeconds[_dayKey(d)] ?? 0;
      if (sec > 0) {
        streak += 1;
      } else {
        break;
      }
    }
    return streak;
  }

  String _dayKey(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)}';
  }

  Map<String, int> _normalizeDaySeconds(Map<String, dynamic> days) {
    final out = <String, int>{};
    days.forEach((k, v) {
      out[k.toString()] = _extractSeconds(v);
    });
    return out;
  }

  int _extractSeconds(dynamic value) {
    if (value == null) return 0;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value) ?? 0;
    if (value is Map) {
      final m = value.cast<String, dynamic>();
      final candidates = [
        m['timeListening'],
        m['totalTime'],
        m['seconds'],
        m['time'],
        m['duration'],
      ];
      for (final c in candidates) {
        if (c is num) return c.toInt();
        if (c is String) {
          final parsed = int.tryParse(c);
          if (parsed != null) return parsed;
        }
      }
    }
    return 0;
  }

  String _formatListeningTime(int seconds) {
    if (seconds <= 0) return '0m';
    final duration = Duration(seconds: seconds);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    if (hours > 0) {
      return minutes > 0 ? '${hours}h ${minutes}m' : '${hours}h';
    }
    return '${duration.inMinutes}m';
  }

  String _estimatePages(int seconds) {
    if (seconds <= 0) return 'No pages yet';
    final pages = math.max(1, (seconds / 105).round());
    return 'about $pages pages';
  }

  /// Pill used in the header. [expand] makes it fill its slot (so the
  /// Audiobooks / Series buttons render at the same size side by side).
  Widget _headerPill(
    BuildContext context, {
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    bool expand = false,
  }) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: Color.alphaBlend(cs.primary.withOpacity(0.12), cs.surface),
      borderRadius: BorderRadius.circular(999),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: cs.primary, size: 16),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: cs.onSurface,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSeriesDrawer(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const SeriesSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final visible = _visibleBooks();
    _prepareBookLetterAnchors(visible);

    return Scaffold(
      backgroundColor: cs.surface,
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => _refresh(force: true),
            edgeOffset: 120,
            color: cs.primary,
            backgroundColor: cs.surface,
            child: CustomScrollView(
              controller: _scrollCtrl,
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              cacheExtent: 800,
              slivers: [
                SliverAppBar(
                  floating: false,
                  pinned: true,
                  backgroundColor: cs.surface,
                  surfaceTintColor: cs.surfaceTint,
                  elevation: 0,
                  toolbarHeight: 72,
                  titleSpacing: 20,
                  title: ValueListenableBuilder<bool>(
                    valueListenable: UiPrefs.seriesTabVisible,
                    builder: (context, seriesVisible, __) {
                      // Series has its own tab — just show the section label.
                      if (seriesVisible) {
                        return Row(
                          children: [
                            _headerPill(
                              context,
                              icon: LucideIcons.activity,
                              label: 'Audiobooks',
                            ),
                          ],
                        );
                      }
                      // No Series tab — show two equal-size buttons; "Series"
                      // opens a bottom drawer.
                      return Row(
                        children: [
                          Expanded(
                            child: _headerPill(
                              context,
                              icon: LucideIcons.activity,
                              label: 'Audiobooks',
                              expand: true,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _headerPill(
                              context,
                              icon: LucideIcons.library,
                              label: 'Series',
                              expand: true,
                              onTap: () => _openSeriesDrawer(context),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 10, 10, 18),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: cs.surfaceContainerLow.withOpacity(0.88),
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(
                            color: cs.outlineVariant.withOpacity(0.16),
                          ),
                        ),
                        child: Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          alignment: WrapAlignment.center,
                          children: [
                            _ToolbarSurfaceButton(
                              tooltip: 'Search',
                              icon:
                                  _searchVisible
                                      ? LucideIcons.searchX
                                      : LucideIcons.search,
                              onTap: _toggleSearch,
                              emphasized: _searchVisible,
                            ),
                            // Stats were three taps deep behind the profile
                            // icon; give listening stats their own entry point.
                            _ToolbarSurfaceButton(
                              tooltip: 'Listening stats',
                              icon: LucideIcons.chartColumn,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) => const StatsPage(),
                                  ),
                                );
                              },
                            ),
                            _ToolbarSurfaceButton(
                              tooltip: 'Profile',
                              icon: LucideIcons.user,
                              onTap: () {
                                Navigator.of(context).push(
                                  MaterialPageRoute(
                                    builder: (context) => const ProfilePage(),
                                  ),
                                );
                              },
                            ),
                            _ToolbarSurfaceButton(
                              tooltip: 'Support',
                              icon: LucideIcons.helpCircle,
                              onTap: () async {
                                final url = Uri.parse(
                                  'https://github.com/bennybar/kitzi_abs_player/issues',
                                );
                                if (await canLaunchUrl(url)) {
                                  await launchUrl(
                                    url,
                                    mode: LaunchMode.externalApplication,
                                  );
                                }
                              },
                            ),
                            PopupMenuButton<LibraryFilter>(
                              tooltip: 'Filter',
                              initialValue: _filter,
                              onSelected: (f) {
                                setState(() => _filter = f);
                                _saveFilterPref(f);
                                // Re-query: the filter is applied in SQL over
                                // the whole library, not over the loaded page.
                                _loadBooksFromCache();
                              },
                              itemBuilder: (context) => [
                                PopupMenuItem(
                                  value: LibraryFilter.all,
                                  child: ListTile(
                                    leading: Icon(LucideIcons.inbox, color: cs.primary),
                                    title: const Text('All'),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: LibraryFilter.inProgress,
                                  child: ListTile(
                                    leading: Icon(LucideIcons.play, color: cs.primary),
                                    title: const Text('In progress'),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: LibraryFilter.notStarted,
                                  child: ListTile(
                                    leading: Icon(LucideIcons.circle, color: cs.primary),
                                    title: const Text('Not started'),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                                PopupMenuItem(
                                  value: LibraryFilter.finished,
                                  child: ListTile(
                                    leading: Icon(LucideIcons.checkCircle, color: cs.primary),
                                    title: const Text('Finished'),
                                    contentPadding: EdgeInsets.zero,
                                  ),
                                ),
                              ],
                              child: _ToolbarSurfaceButton(
                                tooltip: 'Filter',
                                icon: LucideIcons.listFilter,
                                onTap: null,
                                emphasized: _filter != LibraryFilter.all,
                              ),
                            ),
                            PopupMenuButton<SortMode>(
                              tooltip: 'Sort',
                              enabled: !_forceAlphaSort,
                              initialValue:
                                  _forceAlphaSort ? SortMode.nameAsc : _sort,
                              onSelected:
                                  !_forceAlphaSort
                                      ? (mode) {
                                        setState(() => _sort = mode);
                                        _saveSortPref(mode);
                                        _loadBooksFromCache();
                                      }
                                      : null,
                              itemBuilder:
                                  (context) => [
                                    PopupMenuItem(
                                      value: SortMode.addedDesc,
                                      child: ListTile(
                                        leading: Icon(
                                          LucideIcons.clock,
                                          color: cs.primary,
                                        ),
                                        title: const Text(
                                          'Added date (newest)',
                                        ),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                    PopupMenuItem(
                                      value: SortMode.nameAsc,
                                      child: ListTile(
                                        leading: Icon(
                                          LucideIcons.arrowDownAZ,
                                          color: cs.primary,
                                        ),
                                        title: const Text('Name (A–Z)'),
                                        contentPadding: EdgeInsets.zero,
                                      ),
                                    ),
                                  ],
                              child: _ToolbarSurfaceButton(
                                tooltip: 'Sort',
                                icon: LucideIcons.arrowUpDown,
                                onTap: null,
                                enabled: !_forceAlphaSort,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                // Enhanced Search Bar
                SliverToBoxAdapter(
                  child: AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child:
                        _searchVisible
                            ? Padding(
                              padding: const EdgeInsets.fromLTRB(10, 0, 10, 24),
                              child: Column(
                                children: [
                                  // Material search bar
                                  SearchBar(
                                    controller: _searchCtrl,
                                    focusNode: _searchFocusNode,
                                    leading: Icon(
                                      LucideIcons.search,
                                      color: cs.onSurfaceVariant,
                                    ),
                                    hintText: 'Search books or authors...',
                                    hintStyle: WidgetStateProperty.all(
                                      TextStyle(color: cs.onSurfaceVariant),
                                    ),
                                    backgroundColor: WidgetStateProperty.all(
                                      cs.surfaceContainerHighest,
                                    ),
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
                                      _searchDebounce = Timer(
                                        const Duration(milliseconds: 300),
                                        () {
                                          if (!mounted) return;
                                          _restartSearchPagination();
                                        },
                                      );
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
                                            // Force re-fetch first page from server and restart pagination
                                            _restartSearchPagination();
                                          },
                                          icon: Icon(
                                            LucideIcons.x,
                                            color: cs.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                  // View toggle removed – list only
                                ],
                              ),
                            )
                            : const SizedBox.shrink(),
                  ),
                ),

                if (_query.trim().isEmpty)
                  SliverToBoxAdapter(
                    child: _buildHomeHero(visible),
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
                              LucideIcons.alertCircle,
                              size: 64,
                              color: cs.error,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Error loading library',
                              style: Theme.of(
                                context,
                              ).textTheme.titleLarge?.copyWith(color: cs.error),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: () => _refresh(),
                              icon: const Icon(LucideIcons.refreshCw),
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
                              icon: const Icon(LucideIcons.checkCircle),
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
                              _query.isNotEmpty
                                  ? LucideIcons.searchX
                                  : LucideIcons.library,
                              size: 64,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(height: 16),
                            Text(
                              _query.isNotEmpty
                                  ? 'No books found'
                                  : 'Your library is empty',
                              style: Theme.of(context).textTheme.titleLarge
                                  ?.copyWith(color: cs.onSurface),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _query.isNotEmpty
                                  ? 'Try adjusting your search terms'
                                  : 'Add some books to get started',
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: cs.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else ...[
                  if (_recentBooks.isNotEmpty && _query.trim().isEmpty)
                    _buildContinueListeningSection(),
                  if (_query.trim().isEmpty)
                    _buildRecentlyAddedShelf(_recentlyAdded),
                  if (_query.trim().isEmpty)
                    SliverToBoxAdapter(
                      child: _SectionHeader(
                        icon: LucideIcons.library,
                        title: 'All Audiobooks',
                        padding: const EdgeInsets.fromLTRB(10, 6, 10, 14),
                      ),
                    ),
                  _buildList(visible),
                  _buildLoadMore(),
                ],
              ],
            ),
          ),
          _buildLetterScrollbarOverlay(context),
        ],
      ),
    );
  }

  Widget _buildGrid(List<Book> list) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      sliver: SliverGrid(
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 3,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.62,
        ),
        delegate: SliverChildBuilderDelegate((context, i) {
          final b = list[i];
          return _BookCard(
            key: ValueKey(b.id),
            book: b,
            onTap: b.isAudioBook ? () => _openDetails(b) : null,
            onLongPress: b.isAudioBook ? () => showQueueSheet(context, b) : null,
            onAuthorTap:
                b.author != null && b.author!.isNotEmpty
                    ? () => _showAuthorBooks(context, b.author!)
                    : null,
            onSeriesTap:
                b.series != null && b.series!.isNotEmpty
                    ? () => _showSeriesBooks(context, b.series!)
                    : null,
          );
        }, childCount: list.length),
      ),
    );
  }

  Widget _buildHomeHero(List<Book> visible) {
    final cs = Theme.of(context).colorScheme;
    final continueCount = _recentBooks.where((b) => b.isAudioBook).length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 2, 10, 16),
      child: AppLiquidGlass(
        blur: 42,
        opacity: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.09,
        borderRadius: BorderRadius.circular(24),
        tint: Color.alphaBlend(
          cs.primary.withOpacity(
            Theme.of(context).brightness == Brightness.dark ? 0.06 : 0.03,
          ),
          cs.surfaceContainerLow,
        ),
        lightenAmount:
            Theme.of(context).brightness == Brightness.dark ? null : 0.08,
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _HomeStatCard(
                    title: 'Listening Time',
                    value: _formatListeningTime(_todayListeningSeconds),
                    subtitle: _estimatePages(_todayListeningSeconds),
                    icon: LucideIcons.clock,
                    chipLabel:
                        _homeStatsLoading && _todayListeningSeconds == 0
                            ? 'Syncing'
                            : 'Today',
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _HomeStatCard(
                    title: 'Streak',
                    value:
                        _currentStreakDays > 0
                            ? '$_currentStreakDays days'
                            : 'Start today',
                    subtitle:
                        _currentStreakDays > 0
                            ? 'Keep momentum'
                            : 'No active streak',
                    icon: LucideIcons.flame,
                    accent: const Color(0xFFF59E0B), // warm amber for the streak
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: _HomeStatCard(
                    title: 'Continue Listening',
                    value: '$continueCount books',
                    subtitle:
                        continueCount > 0
                            ? 'Jump back in quickly'
                            : 'Recent books will appear here',
                    icon: LucideIcons.play,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _HomeStatCard(
                    title: 'Library',
                    value: '${_libraryTotalItems ?? visible.length} titles',
                    subtitle: 'Freshest shelf on top',
                    icon: LucideIcons.library,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContinueListeningSection() {
    if (_isEbookLibrary)
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: LucideIcons.play,
              title: 'Continue Listening',
              padding: EdgeInsets.symmetric(horizontal: 10),
            ),
            const SizedBox(height: 18),
            Builder(
              builder: (context) {
                final visible = _recentBooks
                    .where((b) => b.isAudioBook)
                    .take(6)
                    .toList(growable: false);
                if (visible.isEmpty) return const SizedBox.shrink();
                // Same card size/appearance as the Recently Added shelf.
                return SizedBox(
                  height: 190,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    itemCount: visible.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 12),
                    itemBuilder: (context, index) {
                      final book = visible[index];
                      return SizedBox(
                        width: 132,
                        height: 190,
                        child: _ShelfBookCard(
                          key: ValueKey('continue-${book.id}'),
                          book: book,
                          onTap: () => _openDetails(book),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  /// Sourced from its own query so it stays "recently added" regardless of the
  /// sort/filter the user has applied to the main list.
  Future<void> _loadRecentlyAdded() async {
    try {
      final repo = await _repoFut;
      final items = await repo.listBooksFromDbPaged(
        page: 1,
        limit: 10,
        sort: 'addedDesc',
      );
      if (!mounted || _bookListsMatch(_recentlyAdded, items)) return;
      setState(() => _recentlyAdded = items);
    } catch (_) {
      // Leave the previous shelf contents in place.
    }
  }

  Widget _buildRecentlyAddedShelf(List<Book> list) {
    final shelf = list.take(10).toList(growable: false);
    if (shelf.isEmpty) return const SliverToBoxAdapter(child: SizedBox.shrink());
    return SliverToBoxAdapter(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(0, 0, 0, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(
              icon: LucideIcons.sparkles,
              title: 'Recently Added',
              padding: EdgeInsets.symmetric(horizontal: 10),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 190,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 10),
                itemCount: shelf.length,
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final book = shelf[index];
                  return SizedBox(
                    width: 132,
                    height: 190,
                    child: _ShelfBookCard(
                      key: ValueKey('recent-${book.id}'),
                      book: book,
                      onTap: () => _openDetails(book),
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

  Widget _buildList(List<Book> list) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
      sliver: SliverList.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: true,
        itemBuilder: (context, i) {
          final b = list[i];
          return Dismissible(
            key: ValueKey(b.id),
            direction:
                DismissDirection
                    .startToEnd, // Only allow swipe right (download)
            dismissThresholds: const {DismissDirection.startToEnd: 0.4},
            confirmDismiss: (direction) async {
              // Execute actions in background and bounce back immediately
              if (direction == DismissDirection.startToEnd) {
                // Swipe right → Download/Delete (with confirmation)
                if (b.isAudioBook) {
                  final downloads =
                      ServicesScope.of(context).services.downloads;
                  final ctx = context;

                  // Check status and show confirmation
                  unawaited(
                    downloads.hasLocalDownloads(b.id).then((hasLocal) async {
                      if (!ctx.mounted) return;

                      final action = hasLocal ? 'delete' : 'download';
                      final confirmed = await showDialog<bool>(
                        context: ctx,
                        builder:
                            (context) => AlertDialog(
                              title: Text(
                                hasLocal
                                    ? 'Delete Download?'
                                    : 'Download Book?',
                              ),
                              content: Text(
                                hasLocal
                                    ? 'Delete downloaded files for "${b.title}"? You can re-download it later.'
                                    : 'Download "${b.title}" for offline listening?',
                              ),
                              actions: [
                                TextButton(
                                  onPressed:
                                      () => Navigator.of(context).pop(false),
                                  child: const Text('Cancel'),
                                ),
                                FilledButton(
                                  onPressed:
                                      () => Navigator.of(context).pop(true),
                                  style:
                                      hasLocal
                                          ? FilledButton.styleFrom(
                                            backgroundColor:
                                                Theme.of(
                                                  context,
                                                ).colorScheme.error,
                                          )
                                          : null,
                                  child: Text(hasLocal ? 'Delete' : 'Download'),
                                ),
                              ],
                            ),
                      );

                      if (confirmed == true) {
                        if (hasLocal) {
                          await downloads.deleteLocal(b.id);
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text('Deleted: ${b.title}'),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        } else {
                          if (!ctx.mounted) return;
                          // Same Wi‑Fi-only gate the download button enforces.
                          if (!await ensureDownloadAllowed(ctx)) return;
                          final othersActive =
                              await downloads.hasActiveOrQueued();
                          await downloads.enqueueItemDownloads(
                            b.id,
                            displayTitle: b.title,
                          );
                          if (ctx.mounted) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(
                                content: Text(
                                  othersActive
                                      ? 'Queued: ${b.title}'
                                      : 'Downloading: ${b.title}',
                                ),
                                duration: const Duration(seconds: 2),
                              ),
                            );
                          }
                        }
                      }
                    }),
                  );
                }
              }
              return false; // Return immediately - action runs in background
            },
            background: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.only(left: 20),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                LucideIcons.download,
                color: Colors.white,
                size: 28,
              ),
            ),
            child: _BookListTile(
              key: ValueKey('tile-${b.id}'),
              book: b,
              onTap: b.isAudioBook ? () => _openDetails(b) : null,
              // Add to queue: this lived only on the removed grid view, which
              // left queueing unreachable from the library list.
              onLongPress:
                  b.isAudioBook ? () => showQueueSheet(context, b) : null,
              checkIfCompleted: _checkIfCompleted,
              hideSeriesWhenSameAsAuthor: _hideSeriesWhenSameAsAuthor,
              onAuthorTap:
                  b.author != null && b.author!.isNotEmpty
                      ? () => _showAuthorBooks(context, b.author!)
                      : null,
              onSeriesTap:
                  b.series != null && b.series!.isNotEmpty
                      ? () => _showSeriesBooks(context, b.series!)
                      : null,
            ),
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
          child:
              _loadingMore
                  ? const CircularProgressIndicator()
                  : const SizedBox.shrink(),
        ),
      ),
    );
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    final gen = ++_loadGen;
    final offsetAtStart = _books.length;
    final queryAtStart = _query.trim();
    setState(() => _loadingMore = true);
    try {
      final repo = await _repoFut;
      // Ensure the server page covering the next offset is in DB.
      final serverPage = (offsetAtStart ~/ 50) + 1;
      await repo.ensureServerPageIntoDb(
        page: serverPage,
        limit: 50,
        query: queryAtStart.isEmpty ? null : queryAtStart,
      );
      if (!mounted || gen != _loadGen) return;
      final page = await repo.listBooksFromDbPaged(
        page: 1,
        limit: 50,
        offset: offsetAtStart,
        sort: _dbSort,
        query: queryAtStart.isEmpty ? null : queryAtStart,
        onlyIds: _filterOnlyIds,
        excludeIds: _filterExcludeIds,
      );
      if (!mounted || gen != _loadGen) return;
      // Guard against the list having been replaced while we were fetching.
      if (_books.length != offsetAtStart || _query.trim() != queryAtStart) {
        return;
      }
      setState(() {
        _books.addAll(page);
        _booksRev++;
        _hasMore = page.length >= 50;
      });
    } catch (_) {
      // ignore
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loadingMore = false);
    }
  }

  Future<void> _startBackgroundSync({
    bool awaitCompletion = false,
    bool forceCheck = false,
  }) async {
    final query = _query.trim();
    final effectiveQuery = query.isEmpty ? null : query;

    Future<void> run() async {
      try {
        final repo = await _repoFut;
        await repo.incrementalSync(
          query: effectiveQuery,
          pageSize: 50,
          maxPages: effectiveQuery == null ? 4 : 2,
          forceCheck: forceCheck,
        );
      } catch (_) {
      } finally {
        _activeSyncFuture = null;
      }
    }

    if (_activeSyncFuture != null) {
      if (awaitCompletion) {
        await _activeSyncFuture;
      }
      return;
    }

    final future = run();
    _activeSyncFuture = future;
    if (awaitCompletion) {
      await future;
    } else {
      unawaited(future);
    }
  }

  Widget _buildLetterScrollbarOverlay(BuildContext context) {
    final media = MediaQuery.of(context);
    final bottomChromeReserve = media.padding.bottom + 132.0;
    return Positioned(
      right: 4,
      top: media.padding.top + 96,
      bottom: bottomChromeReserve,
      child: ValueListenableBuilder<bool>(
        valueListenable: UiPrefs.letterScrollEnabled,
        builder: (_, enabled, __) {
          final visible =
              _forceAlphaSort &&
              enabled &&
              _bookLetterOrder.length > 1 &&
              !_loading;
          if (!visible) return const SizedBox.shrink();
          return SizedBox(
            width: 40,
            child: LetterScrollbar(
              letters: _bookLetterOrder,
              visible: visible,
              onLetterSelected: _scrollToBookLetter,
            ),
          );
        },
      ),
    );
  }

  Future<void> _restartSearchPagination() async {
    await _loadBooksFromCache(showSpinner: true);
    try {
      final repo = await _repoFut;
      final q = _query.trim();
      await repo.ensureServerPageIntoDb(
        page: 1,
        limit: 50,
        query: q.isEmpty ? null : q,
      );
      _reloadBooksFromCacheIfChanged();
      _startBackgroundSync();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }
}

class _ToolbarSurfaceButton extends StatelessWidget {
  const _ToolbarSurfaceButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.emphasized = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;
  final bool enabled;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bg =
        emphasized
            ? Color.alphaBlend(cs.primary.withOpacity(0.16), cs.surface)
            : cs.surface.withOpacity(0.78);

    return Tooltip(
      message: tooltip,
      child: Material(
        color: enabled ? bg : bg.withOpacity(0.5),
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onTap : null,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 22,
              color:
                  enabled
                      ? (emphasized ? cs.primary : cs.onSurfaceVariant)
                      : cs.onSurfaceVariant.withOpacity(0.4),
            ),
          ),
        ),
      ),
    );
  }
}

class _HomeStatCard extends StatelessWidget {
  const _HomeStatCard({
    required this.title,
    required this.value,
    required this.subtitle,
    required this.icon,
    this.chipLabel,
    this.accent,
  });

  final String title;
  final String value;
  final String subtitle;
  final IconData icon;
  final String? chipLabel;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return AppLiquidGlass(
      blur: 30,
      opacity: Theme.of(context).brightness == Brightness.dark ? 0.18 : 0.08,
      borderRadius: BorderRadius.circular(22),
      tint: Color.alphaBlend(
        Colors.black.withValues(
          alpha:
              Theme.of(context).brightness == Brightness.dark ? 0.0 : 0.04,
        ),
        cs.surface,
      ),
      elevation: 10,
      lightenAmount:
          Theme.of(context).brightness == Brightness.dark ? null : 0.07,
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    fontSize: 13,
                  ),
                ),
              ),
              if (chipLabel != null)
                AppLiquidGlassPill(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 3,
                  ),
                  blur: 20,
                  opacity:
                      Theme.of(context).brightness == Brightness.dark
                          ? 0.2
                          : 0.08,
                  tint: Color.alphaBlend(
                    Colors.black.withValues(
                      alpha:
                          Theme.of(context).brightness == Brightness.dark
                              ? 0.0
                              : 0.05,
                    ),
                    cs.surfaceContainerHighest,
                  ),
                  elevation: 4,
                  lightenAmount:
                      Theme.of(context).brightness == Brightness.dark
                          ? null
                          : 0.06,
                  child: Text(
                    chipLabel!,
                    style: text.labelSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: cs.onSurfaceVariant,
                      fontSize: 10,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Builder(builder: (_) {
                final accent = this.accent ?? cs.primary;
                return Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(icon, size: 16, color: accent),
                );
              }),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  value,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.4,
                    fontSize: 20,
                    height: 1.15,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.icon,
    required this.title,
    this.padding = const EdgeInsets.fromLTRB(10, 0, 10, 12),
  });

  final IconData icon;
  final String title;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: padding,
      child: Row(
        children: [
          AppLiquidGlass(
            blur: 24,
            opacity:
                Theme.of(context).brightness == Brightness.dark ? 0.2 : 0.08,
            borderRadius: BorderRadius.circular(10),
            tint: Color.alphaBlend(
              Colors.black.withValues(
                alpha:
                    Theme.of(context).brightness == Brightness.dark
                        ? 0.0
                        : 0.04,
              ),
              cs.surface,
            ),
            elevation: 6,
            lightenAmount:
                Theme.of(context).brightness == Brightness.dark ? null : 0.06,
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: 28,
              height: 28,
              child: Icon(icon, size: 18, color: cs.primary),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: text.titleLarge?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
        ],
      ),
    );
  }
}

class _ShelfBookCard extends StatelessWidget {
  const _ShelfBookCard({
    super.key,
    required this.book,
    required this.onTap,
  });

  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: cs.outline.withOpacity(0.08)),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AspectRatio(
                aspectRatio: 1.0,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: SizedBox(
                    width: double.infinity,
                    child: EnhancedCoverImage(
                        url: book.coverUrl, cacheVersion: book.updatedAt),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  height: 1.12,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                book.author?.isNotEmpty == true ? book.author! : 'Unknown author',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onLongPress,
    this.onAuthorTap,
    this.onSeriesTap,
  });
  final Book book;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onSeriesTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = !book.isAudioBook;
    final playback = ServicesScope.of(context).services.playback;

    // Static checks — update when widget rebuilds
    final isFinished = playback.completionCache[book.id] == true;
    final isNew =
        book.updatedAt != null &&
        DateTime.now().difference(book.updatedAt!).inDays <= 7;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: cs.outline.withOpacity(disabled ? 0.05 : 0.1),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Uniform cover size 2:3 — reactive to now-playing state
              StreamBuilder<NowPlaying?>(
                stream: playback.nowPlayingStream,
                initialData: playback.nowPlaying,
                builder: (ctx, npSnap) {
                  final isNowPlaying =
                      npSnap.data?.libraryItemId == book.id;
                  return Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: cs.shadow.withOpacity(disabled ? 0.04 : 0.1),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                        if (isNowPlaying)
                          BoxShadow(
                            color: cs.primary.withOpacity(0.35),
                            blurRadius: 18,
                            spreadRadius: 2,
                          ),
                      ],
                      border:
                          isNowPlaying
                              ? Border.all(
                                color: cs.primary.withOpacity(0.7),
                                width: 2,
                              )
                              : null,
                    ),
                    child: Hero(
                      tag: 'home-cover-${book.id}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: AspectRatio(
                          aspectRatio: 2 / 3,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              ColorFiltered(
                                colorFilter:
                                    disabled
                                        ? ColorFilter.mode(
                                          cs.surface.withOpacity(0.12),
                                          BlendMode.saturation,
                                        )
                                        : const ColorFilter.mode(
                                          Colors.transparent,
                                          BlendMode.srcOver,
                                        ),
                                child: Transform.scale(
                                  scale: 1.024,
                                  child: EnhancedCoverImage(
                                    url: book.coverUrl,
                                    cacheVersion: book.updatedAt,
                                  ),
                                ),
                              ),
                              // Live progress bar for now-playing book
                              if (isNowPlaying)
                                Positioned(
                                  left: 0,
                                  right: 0,
                                  bottom: 0,
                                  child: ValueListenableBuilder<Duration>(
                                    valueListenable: playback.currentPosition,
                                    builder: (_, currentPos, __) {
                                      final pos =
                                          playback.globalBookPosition ??
                                          currentPos;
                                      final dur = playback.totalBookDuration;
                                      final fraction =
                                          dur != null && dur != Duration.zero
                                              ? (pos.inMilliseconds /
                                                      dur.inMilliseconds)
                                                  .clamp(0.0, 1.0)
                                              : 0.0;
                                      return SizedBox(
                                        height: 4,
                                        child: LinearProgressIndicator(
                                          value: fraction,
                                          backgroundColor: Colors.black45,
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                                cs.primary,
                                              ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              // Finished check badge
                              if (isFinished && !isNowPlaying)
                                Positioned(
                                  top: 6,
                                  right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(3),
                                    decoration: BoxDecoration(
                                      color: Colors.green.shade700
                                          .withOpacity(0.88),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      LucideIcons.check,
                                      color: Colors.white,
                                      size: 11,
                                    ),
                                  ),
                                ),
                              // "NEW" badge for recently added books
                              if (isNew && !isFinished && !isNowPlaying)
                                Positioned(
                                  top: 6,
                                  left: 6,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.deepOrange.withOpacity(
                                        0.88,
                                      ),
                                      borderRadius: BorderRadius.circular(5),
                                    ),
                                    child: const Text(
                                      'NEW',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 0.3,
                                      ),
                                    ),
                                  ),
                                ),
                              // Now-playing indicator
                              if (isNowPlaying)
                                Positioned(
                                  top: 6,
                                  left: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: cs.primary.withOpacity(0.88),
                                      shape: BoxShape.circle,
                                    ),
                                    child: const Icon(
                                      LucideIcons.play,
                                      color: Colors.white,
                                      size: 11,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                },
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
              // Series (if available) - between title and author
              // Hide series if it's the same as author name (when preference is enabled)
              ValueListenableBuilder<bool>(
                valueListenable: UiPrefs.hideSeriesWhenSameAsAuthor,
                builder: (context, hideWhenSame, _) {
                  final shouldShowSeries =
                      book.series != null &&
                      book.series!.isNotEmpty &&
                      (!hideWhenSame || book.series != book.author);
                  if (!shouldShowSeries) return const SizedBox.shrink();

                  return SizedBox(
                    height: 14,
                    child: GestureDetector(
                      onTap: onSeriesTap,
                      child: Text(
                        book.series!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              disabled
                                  ? cs.onSurfaceVariant.withOpacity(0.4)
                                  : cs.primary.withOpacity(0.8),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: 2),
              // Author
              SizedBox(
                height: 14,
                child:
                    (book.author != null && book.author!.isNotEmpty)
                        ? GestureDetector(
                          onTap: onAuthorTap,
                          child: Text(
                            book.author!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color:
                                  disabled
                                      ? cs.onSurfaceVariant.withOpacity(0.4)
                                      : cs.onSurfaceVariant,
                            ),
                          ),
                        )
                        : const SizedBox.shrink(),
              ),
              if (disabled) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    Icon(
                      LucideIcons.ban,
                      size: 14,
                      color: cs.onSurfaceVariant.withOpacity(0.6),
                    ),
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

class _ResumeBookCard extends StatefulWidget {
  const _ResumeBookCard({
    super.key,
    required this.book,
    required this.onTap,
    this.onAuthorTap,
    this.onSeriesTap,
  });
  final Book book;
  final VoidCallback onTap;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onSeriesTap;

  @override
  State<_ResumeBookCard> createState() => _ResumeBookCardState();
}

class _ResumeBookCardState extends State<_ResumeBookCard> {
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final playback = ServicesScope.of(context).services.playback;

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(22),
        side: BorderSide(color: cs.outline.withOpacity(0.08), width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(22),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 14),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // Square cover on top
                Container(
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(18),
                    boxShadow: [
                      BoxShadow(
                        color: cs.shadow.withOpacity(0.08),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(18),
                    child: AspectRatio(
                      aspectRatio: 1.0,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Transform.scale(
                              scale: 1.024,
                              child: EnhancedCoverImage(
                                url: widget.book.coverUrl,
                                cacheVersion: widget.book.updatedAt,
                              ),
                            ),
                          ),
                          // Play/Pause button overlay - top left
                          Positioned(
                            top: 8,
                            left: 8,
                            child: StreamBuilder(
                              stream: playback.nowPlayingStream,
                              initialData: playback.nowPlaying,
                              builder: (context, nowPlayingSnapshot) {
                                return StreamBuilder<bool>(
                                  stream: playback.playingStream,
                                  initialData: playback.player.playing,
                                  builder: (context, playingSnapshot) {
                                    final nowPlaying = nowPlayingSnapshot.data;
                                    final isPlaying =
                                        playingSnapshot.data ?? false;
                                    final isThisBook =
                                        nowPlaying?.libraryItemId ==
                                        widget.book.id;
                                    final showPause = isThisBook && isPlaying;

                                    return Material(
                                      color: Colors.transparent,
                                      child: InkWell(
                                        onTap: () async {
                                          if (showPause) {
                                            await playback.pause();
                                          } else {
                                            await playback.playItem(
                                              widget.book.id,
                                              context: context,
                                            );
                                          }
                                        },
                                        borderRadius: BorderRadius.circular(20),
                                        child: Container(
                                          width: 36,
                                          height: 36,
                                          decoration: BoxDecoration(
                                            color: Colors.black.withOpacity(
                                              0.34,
                                            ),
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white.withOpacity(
                                                0.14,
                                              ),
                                            ),
                                          ),
                                          child: Icon(
                                            showPause
                                                ? LucideIcons.pause
                                                : LucideIcons.play,
                                            color: Colors.white,
                                            size: 20,
                                          ),
                                        ),
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                          // Material 3 progress indicator overlay
                          Positioned(
                            left: 8,
                            right: 8,
                            bottom: 8,
                            child: FutureBuilder<Map<String, dynamic>>(
                              future: _getBookProgress(context, widget.book.id),
                              builder: (context, snapshot) {
                                if (!snapshot.hasData)
                                  return const SizedBox.shrink();
                                final progressInfo = snapshot.data!;
                                final raw = progressInfo['progress'] as double?;
                                final isCompleted =
                                    progressInfo['isCompleted'] as bool? ??
                                    false;

                                // Don't show progress for completed books
                                if (isCompleted) return const SizedBox.shrink();

                                if (raw == null || raw <= 0)
                                  return const SizedBox.shrink();
                                final progress = raw.clamp(0.0, 0.99);

                                return Container(
                                  height: 5,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.18),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: progress,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color:
                                            Theme.of(
                                              context,
                                            ).colorScheme.primary,
                                        borderRadius: BorderRadius.circular(
                                          999,
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
                  ),
                ),
                const SizedBox(height: 14),
                // Title and author below the cover
                Text(
                  widget.book.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
                // Series (if available) - between title and author
                // Hide series if it's the same as author name (when preference is enabled)
                ValueListenableBuilder<bool>(
                  valueListenable: UiPrefs.hideSeriesWhenSameAsAuthor,
                  builder: (context, hideWhenSame, _) {
                    final shouldShowSeries =
                        widget.book.series != null &&
                        widget.book.series!.isNotEmpty &&
                        (!hideWhenSame ||
                            widget.book.series != widget.book.author);
                    if (!shouldShowSeries) return const SizedBox.shrink();

                    return Column(
                      children: [
                        const SizedBox(height: 4),
                        GestureDetector(
                          onTap: widget.onSeriesTap,
                          child: Text(
                            widget.book.series!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color: Theme.of(
                                context,
                              ).colorScheme.primary.withOpacity(0.8),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    );
                  },
                ),
                if (widget.book.author != null &&
                    widget.book.author!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  GestureDetector(
                    onTap: widget.onAuthorTap,
                    child: Text(
                      widget.book.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurfaceVariant.withOpacity(0.88),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Get book progress using the same logic as book details (PlaybackRepository)
  Future<Map<String, dynamic>> _getBookProgress(
    BuildContext context,
    String bookId,
  ) async {
    try {
      final playback = ServicesScope.of(context).services.playback;
      final seconds = await playback.fetchServerProgress(
        bookId,
      ); // nullable seconds

      // Use cached completion status first, fallback to server if not cached
      bool isCompleted = playback.completionCache[bookId] ?? false;
      if (!playback.completionCache.containsKey(bookId)) {
        // Only fetch from server if not in cache
        isCompleted = await playback.isBookCompleted(bookId);
        playback.completionCache[bookId] = isCompleted;
      }
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
              } else if (data['currentTime'] is num &&
                  data['duration'] is num) {
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

class _BookListTile extends StatefulWidget {
  const _BookListTile({
    super.key,
    required this.book,
    required this.onTap,
    required this.checkIfCompleted,
    required this.hideSeriesWhenSameAsAuthor,
    this.onAuthorTap,
    this.onSeriesTap,
    this.onLongPress,
  });
  final Book book;
  final VoidCallback? onTap;
  final Future<bool> Function(String) checkIfCompleted;
  final bool hideSeriesWhenSameAsAuthor;
  final VoidCallback? onAuthorTap;
  final VoidCallback? onSeriesTap;
  final VoidCallback? onLongPress;

  @override
  State<_BookListTile> createState() => _BookListTileState();
}

class _BookListTileState extends State<_BookListTile> {
  Future<double>? _progressFuture;
  Future<bool>? _completedFuture;

  @override
  void initState() {
    super.initState();
    // Fetch progress/completion once when tile is created; reuse across rebuilds
    // so scrolling doesn't re-issue network calls.
    _progressFuture = _fetchProgress();
    _completedFuture = widget.checkIfCompleted(widget.book.id);
  }

  @override
  void didUpdateWidget(covariant _BookListTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.book.id != widget.book.id) {
      _progressFuture = _fetchProgress();
      _completedFuture = widget.checkIfCompleted(widget.book.id);
    }
  }

  Future<double> _fetchProgress() async {
    try {
      final services = ServicesScope.of(context).services;
      final playback = services.playback;
      final progress = await playback.fetchServerProgress(widget.book.id);
      if (progress != null && progress > 0) {
        final durationMs = widget.book.durationMs;
        if (durationMs != null && durationMs > 0) {
          final durationSec = durationMs / 1000;
          return (progress / durationSec).clamp(0.0, 1.0);
        }
      }
      return 0.0;
    } catch (_) {
      return 0.0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final disabled = !widget.book.isAudioBook;
    final services = ServicesScope.of(context).services;

    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(
          color: cs.outline.withOpacity(disabled ? 0.05 : 0.08),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: widget.onTap,
        onLongPress: widget.onLongPress,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Enhanced cover with only progress indicator (no badges)
              Stack(
                children: [
                  Hero(
                    tag: 'home-cover-${widget.book.id}',
                    child: EnhancedCoverImage(
                      url: widget.book.coverUrl,
                      width: 76,
                      height: 76,
                      cacheVersion: widget.book.updatedAt,
                    ),
                  ),
                  // Material 3 progress indicator overlay
                  if (widget.book.isAudioBook)
                    Positioned(
                      left: 6,
                      right: 6,
                      bottom: 6,
                      child: FutureBuilder<bool>(
                        future: _completedFuture,
                        builder: (context, completionSnapshot) {
                          // Don't show progress for completed books
                          if (completionSnapshot.data == true) {
                            return const SizedBox.shrink();
                          }

                          return FutureBuilder<double>(
                            future: _progressFuture,
                            builder: (context, progressSnapshot) {
                              final progress = progressSnapshot.data ?? 0.0;
                              if (progress > 0 && progress < 0.99) {
                                return Container(
                                  height: 4,
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.3),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: progress,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        color: cs.primary,
                                        borderRadius: BorderRadius.circular(
                                          999,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              }
                              return const SizedBox.shrink();
                            },
                          );
                        },
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 12),

              // Title, author, and narrator
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.book.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        height: 1.2,
                        color: disabled ? cs.onSurface.withOpacity(0.4) : null,
                      ),
                    ),
                    // Series (if available) - between title and author.
                    // Hide series when it matches the author name, if the
                    // user preference is enabled (plumbed in from page level).
                    if (widget.book.series != null &&
                        widget.book.series!.isNotEmpty &&
                        (!widget.hideSeriesWhenSameAsAuthor ||
                            widget.book.series != widget.book.author))
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: GestureDetector(
                          onTap: widget.onSeriesTap,
                          child: Text(
                            widget.book.series!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(
                              color: disabled
                                  ? cs.onSurfaceVariant.withOpacity(0.4)
                                  : cs.primary.withOpacity(0.8),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    if (widget.book.author != null &&
                        widget.book.author!.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: widget.onAuthorTap,
                        child: Text(
                          widget.book.author!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(
                            context,
                          ).textTheme.bodyMedium?.copyWith(
                            color:
                                disabled
                                    ? cs.onSurfaceVariant.withOpacity(0.4)
                                    : cs.onSurfaceVariant.withOpacity(0.9),
                          ),
                        ),
                      ),
                    ],
                    if (widget.book.narrators != null &&
                        widget.book.narrators!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Narrated by ${widget.book.narrators!.join(', ')}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              disabled
                                  ? cs.onSurfaceVariant.withOpacity(0.3)
                                  : cs.onSurfaceVariant.withOpacity(0.8),
                        ),
                      ),
                    ],
                    // Duration
                    if (widget.book.durationMs != null &&
                        widget.book.durationMs! > 0) ...[
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Icon(
                            LucideIcons.clock,
                            size: 14,
                            color: cs.onSurfaceVariant.withOpacity(0.7),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(widget.book.durationMs!),
                            style: Theme.of(
                              context,
                            ).textTheme.bodySmall?.copyWith(
                              color:
                                  disabled
                                      ? cs.onSurfaceVariant.withOpacity(0.3)
                                      : cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (disabled) ...[
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          Icon(
                            LucideIcons.ban,
                            size: 16,
                            color: cs.onSurfaceVariant.withOpacity(0.6),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              'Not an audiobook (e.g., ebook/podcast)',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(
                                context,
                              ).textTheme.bodySmall?.copyWith(
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

              // Status indicators and arrow
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Download badge
                  if (widget.book.isAudioBook)
                    StreamBuilder<bool>(
                      stream: services.downloads
                          .watchItemProgress(widget.book.id)
                          .map((p) => p.status == 'complete'),
                      initialData: false,
                      builder: (context, snapshot) {
                        if (snapshot.data == true) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              LucideIcons.checkCircle,
                              color: cs.primary,
                              size: 18,
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  // Completion checkmark
                  if (widget.book.isAudioBook)
                    FutureBuilder<bool>(
                      future: widget.checkIfCompleted(widget.book.id),
                      builder: (context, snapshot) {
                        if (snapshot.data == true) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              LucideIcons.checkCircle,
                              color: Colors.green,
                              size: 18,
                            ),
                          );
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                  // Arrow indicator
                  Icon(
                    LucideIcons.chevronRight,
                    color:
                        disabled
                            ? cs.onSurfaceVariant.withOpacity(0.3)
                            : cs.onSurfaceVariant.withOpacity(0.9),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatDuration(int durationMs) {
    final duration = Duration(milliseconds: durationMs);
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m';
    } else {
      return '${minutes}m';
    }
  }
}
