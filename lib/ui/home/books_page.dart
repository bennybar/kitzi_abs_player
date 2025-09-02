import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../book_detail/book_detail_page.dart';

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
  bool _loading = true;
  String? _error;
  Timer? _timer;

  LibraryView _view = LibraryView.grid;
  SortMode _sort = SortMode.addedDesc;
  String _query = '';

  static const _viewKey = 'library_view_pref';
  static const _sortKey = 'library_sort_pref';
  static const _searchKey = 'library_search_pref';

  final _searchCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _restorePrefs().then((_) {
      _refresh(initial: true);
      _setupAutoRefresh();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _restorePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final v = prefs.getString(_viewKey);
    final s = prefs.getString(_sortKey);
    final q = prefs.getString(_searchKey);

    if (v == 'list') _view = LibraryView.list;
    if (s == 'nameAsc') _sort = SortMode.nameAsc;
    if (q != null) {
      _query = q;
      _searchCtrl.text = q;
    }
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
      // Offline-first: on initial open load from DB only; on pull fetch network
      final items = initial ? await repo.listBooks() : await repo.refreshFromServer();
      if (!mounted) return;
      setState(() {
        _books = items;
        _loading = false;
      });
      if (!initial) {
        _warmCacheCovers(items);
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
        return;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Pre-cache first N covers to disk/memory for snappy grid/list.
  void _warmCacheCovers(List<Book> items, {int count = 30}) {
    if (!mounted || items.isEmpty) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      for (final b in items.take(count)) {
        // Fire-and-forget; CachedNetworkImage handles disk cache
        precacheImage(CachedNetworkImageProvider(b.coverUrl), context)
            .catchError((_) {});
      }
    });
  }

  void _openDetails(Book b) {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => BookDetailPage(bookId: b.id)),
    );
  }

  List<Book> _visibleBooks() {
    final q = _query.trim().toLowerCase();
    List<Book> list = q.isEmpty
        ? List<Book>.from(_books)
        : _books.where((b) {
      final t = b.title.toLowerCase();
      final a = (b.author ?? '').toLowerCase();
      return t.contains(q) || a.contains(q);
    }).toList();

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
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
          // Enhanced App Bar with modern design
          SliverAppBar(
            expandedHeight: 120,
            floating: false,
            pinned: true,
            backgroundColor: cs.surface,
            surfaceTintColor: cs.surfaceTint,
            elevation: 0,
            flexibleSpace: FlexibleSpaceBar(
              title: Text(
                'Library',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
            ),
            actions: [
              IconButton.filledTonal(
                tooltip: 'Refresh',
                onPressed: _loading ? null : () => _refresh(),
                icon: const Icon(Icons.refresh_rounded),
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
                      hintStyle: MaterialStateProperty.all(
                        TextStyle(color: cs.onSurfaceVariant),
                      ),
                      backgroundColor: MaterialStateProperty.all(Colors.transparent),
                      elevation: MaterialStateProperty.all(0),
                      onChanged: (val) {
                        setState(() => _query = val);
                        _saveSearchPref(val);
                      },
                      trailing: [
                        if (_query.isNotEmpty)
                          IconButton(
                            tooltip: 'Clear',
                            onPressed: () {
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
                  const SizedBox(height: 16),

                  // View toggle with enhanced design
                  Container(
                    decoration: BoxDecoration(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: SegmentedButton<LibraryView>(
                      segments: const [
                        ButtonSegment(
                          value: LibraryView.grid,
                          icon: Icon(Icons.grid_view_rounded),
                          label: Text('Grid'),
                        ),
                        ButtonSegment(
                          value: LibraryView.list,
                          icon: Icon(Icons.view_list_rounded),
                          label: Text('List'),
                        ),
                      ],
                      selected: {_view},
                      onSelectionChanged: (sel) {
                        final v = sel.first;
                        setState(() => _view = v);
                        _saveViewPref(v);
                      },
                      style: ButtonStyle(
                        backgroundColor: MaterialStateProperty.resolveWith((states) {
                          if (states.contains(MaterialState.selected)) {
                            return cs.primaryContainer;
                          }
                          return Colors.transparent;
                        }),
                        foregroundColor: MaterialStateProperty.resolveWith((states) {
                          if (states.contains(MaterialState.selected)) {
                            return cs.onPrimaryContainer;
                          }
                          return cs.onSurfaceVariant;
                        }),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Content
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 16),
                    Text('Loading your library...'),
                  ],
                ),
              ),
            )
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
          else
            (_view == LibraryView.grid
                ? _buildGrid(visible)
                : _buildList(visible)),
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
          crossAxisCount: 2,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 0.7,
        ),
        delegate: SliverChildBuilderDelegate(
          (context, i) {
            final b = list[i];
            return _BookCard(
              book: b,
              onTap: () => _openDetails(b),
            );
          },
          childCount: list.length,
        ),
      ),
    );
  }

  Widget _buildList(List<Book> list) {
    return SliverPadding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
      sliver: SliverList.separated(
        itemCount: list.length,
        separatorBuilder: (_, __) => const SizedBox(height: 12),
        itemBuilder: (context, i) {
          final b = list[i];
          return _BookListTile(
            book: b,
            onTap: () => _openDetails(b),
          );
        },
      ),
    );
  }
}

class _BookCard extends StatelessWidget {
  const _BookCard({required this.book, required this.onTap});
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Enhanced cover with shadow
              Expanded(
                child: Container(
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
                      child: _CoverThumb(url: book.coverUrl),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              
              // Title and author with better typography
              Text(
                book.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  height: 1.2,
                ),
              ),
              if (book.author != null && book.author!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  book.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _BookListTile extends StatelessWidget {
  const _BookListTile({required this.book, required this.onTap});
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
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Enhanced cover
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
                    child: _CoverThumb(url: book.coverUrl, size: 72),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              
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
                      ),
                    ),
                    if (book.author != null && book.author!.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        book.author!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              
              // Arrow indicator
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

class _CoverThumb extends StatelessWidget {
  const _CoverThumb({required this.url, this.size});
  final String url;
  final double? size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final radius = BorderRadius.circular(12);
    final placeholder = Container(
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: Center(
        child: Icon(
          Icons.menu_book_outlined,
          color: cs.onSurfaceVariant,
          size: size != null ? size! * 0.4 : 32,
        ),
      ),
    );

    // Support offline file:// covers produced by DB
    final uri = Uri.tryParse(url);
    Widget child;
    if (uri != null && uri.scheme == 'file') {
      final filePath = uri.toFilePath();
      final file = File(filePath);
      child = file.existsSync()
          ? Image.file(file, fit: BoxFit.cover)
          : placeholder;
    } else {
      child = CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        placeholder: (_, __) => placeholder,
        errorWidget: (_, __, ___) => placeholder,
      );
    }

    return ClipRRect(
      borderRadius: radius,
      child: size != null
          ? SizedBox(width: size, height: size, child: child)
          : child,
    );
  }
}
