import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
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
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  Future<void> _refresh({bool initial = false}) async {
    setState(() {
      if (initial) _loading = true;
      _error = null;
    });
    try {
      final repo = await _repoFut;
      final items = await repo.listBooks();
      if (!mounted) return;
      setState(() {
        _books = items;
        _loading = false;
      });
      _warmCacheCovers(items);
    } catch (e) {
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
      appBar: AppBar(
        title: const Text('Books'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => _refresh(),
            icon: const Icon(Icons.refresh),
          ),
          PopupMenuButton<SortMode>(
            tooltip: 'Sort',
            initialValue: _sort,
            onSelected: (mode) {
              setState(() => _sort = mode);
              _saveSortPref(mode);
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: SortMode.addedDesc,
                child: ListTile(
                  leading: Icon(Icons.schedule),
                  title: Text('Added date (newest)'),
                ),
              ),
              PopupMenuItem(
                value: SortMode.nameAsc,
                child: ListTile(
                  leading: Icon(Icons.sort_by_alpha),
                  title: Text('Name (A–Z)'),
                ),
              ),
            ],
            icon: const Icon(Icons.sort),
          ),
          const SizedBox(width: 8),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: SearchBar(
              controller: _searchCtrl,
              leading: const Icon(Icons.search),
              hintText: 'Search title or author',
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
                    icon: const Icon(Icons.clear),
                  ),
                SegmentedButton<LibraryView>(
                  segments: const [
                    ButtonSegment(
                        value: LibraryView.grid, icon: Icon(Icons.grid_view)),
                    ButtonSegment(
                        value: LibraryView.list, icon: Icon(Icons.view_list)),
                  ],
                  selected: {_view},
                  onSelectionChanged: (sel) {
                    final v = sel.first;
                    setState(() => _view = v);
                    _saveViewPref(v);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? ListView(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('Error: $_error',
                  style: TextStyle(color: cs.error)),
            ),
          ],
        )
            : (_view == LibraryView.grid
            ? _buildGrid(visible)
            : _buildList(visible)),
      ),
    );
  }

  Widget _buildGrid(List<Book> list) {
    return GridView.builder(
      padding: const EdgeInsets.all(12),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.66,
      ),
      itemCount: list.length,
      itemBuilder: (context, i) {
        final b = list[i];
        return _BookTile(
          book: b,
          onTap: () => _openDetails(b),
        );
      },
    );
  }

  Widget _buildList(List<Book> list) {
    return ListView.separated(
      padding: const EdgeInsets.all(8),
      itemCount: list.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final b = list[i];
        return ListTile(
          leading: _CoverThumb(url: b.coverUrl, size: 56),
          title: Text(b.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          subtitle: Text(b.author ?? 'Unknown'),
          onTap: () => _openDetails(b),
        );
      },
    );
  }
}

class _BookTile extends StatelessWidget {
  const _BookTile({required this.book, required this.onTap});
  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: _CoverThumb(url: book.coverUrl)),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          Text(
            book.author ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
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
    final radius = BorderRadius.circular(12);
    final placeholder = DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: radius,
      ),
      child: const Center(child: Icon(Icons.menu_book_outlined)),
    );

    final img = CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );

    return ClipRRect(
      borderRadius: radius,
      child: size != null
          ? SizedBox(width: size, height: size, child: img)
          : img,
    );
  }
}
