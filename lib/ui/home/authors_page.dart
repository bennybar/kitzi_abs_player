import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/books_repository.dart';
import '../../core/ui_prefs.dart';
import '../../utils/alphabet_utils.dart';
import '../../widgets/author_card.dart';
import '../../widgets/letter_scrollbar.dart';

class AuthorsPage extends StatefulWidget {
  const AuthorsPage({super.key});

  @override
  State<AuthorsPage> createState() => _AuthorsPageState();
}

class _AuthorsPageState extends State<AuthorsPage> {
  late final Future<BooksRepository> _repoFut;
  List<AuthorInfo> _authors = [];
  List<AuthorInfo> _filteredAuthors = [];
  bool _loading = true;
  String? _error;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();
  Map<String, int> _authorLetterIndex = <String, int>{};
  List<String> _authorLetterOrder = const <String>[];
  int _authorLetterDenominator = 1;
  StreamSubscription<BookDbChange>? _dbChangeSub;

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _repoFut.then((repo) {
      _dbChangeSub ??= repo.dbChanges.listen((change) {
        if (change.type == BookDbChangeType.upsert) {
          _loadAuthors(silent: true);
        }
      });
    });
    _loadAuthors();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _dbChangeSub?.cancel();
    _searchController.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    setState(() {
      _searchQuery = _searchController.text.toLowerCase();
      _filterAuthors();
    });
  }

  void _filterAuthors() {
    if (_searchQuery.isEmpty) {
      _filteredAuthors = List.from(_authors);
    } else {
      _filteredAuthors = _authors.where((author) {
        return author.name.toLowerCase().contains(_searchQuery);
      }).toList();
    }
    _prepareAuthorLetterAnchors(_filteredAuthors);
  }

  void _prepareAuthorLetterAnchors(List<AuthorInfo> list) {
    final indices = <String, int>{};
    for (var i = 0; i < list.length; i++) {
      final bucket = alphabetBucketFor(list[i].name);
      indices.putIfAbsent(bucket, () => i);
    }
    _authorLetterIndex = indices;
    _authorLetterOrder = sortAlphabetBuckets(indices.keys);
    _authorLetterDenominator = math.max(1, list.length - 1);
  }

  void _scrollAuthorsToLetter(String letter) {
    final index = _authorLetterIndex[letter];
    if (index == null || !_scrollCtrl.hasClients) return;
    final maxScroll = _scrollCtrl.position.maxScrollExtent;
    if (maxScroll <= 0) {
      _scrollCtrl.animateTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeOutCubic);
      return;
    }
    final ratio = (index / _authorLetterDenominator).clamp(0.0, 1.0);
    _scrollCtrl.animateTo(
      ratio * maxScroll,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  Future<void> _loadAuthors({bool silent = false}) async {
    if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final repo = await _repoFut;
      final authors = await repo.getAllAuthors();
      if (!mounted) return;
      setState(() {
        _authors = authors;
        _filteredAuthors = List.from(authors);
        if (!silent) {
          _loading = false;
        }
      });
      _prepareAuthorLetterAnchors(_filteredAuthors);
    } catch (e) {
      if (!mounted || silent) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }


  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    await _loadAuthors();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Authors'),
        actions: [
          IconButton(
            onPressed: _refresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(60),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: 'Search authors...',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        onPressed: () {
                          _searchController.clear();
                        },
                        icon: const Icon(Icons.clear_rounded),
                      )
                    : null,
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
              ),
            ),
          ),
        ),
      ),
      body: Stack(
        children: [
          _buildAuthorsBody(theme, cs),
          _buildAuthorLetterScrollbar(context),
        ],
      ),
    );
  }

  void _showAuthorBooks(BuildContext context, AuthorInfo author) {
    AuthorCard.show(
      context: context,
      authorName: author.name,
      books: author.books,
    );
  }

  Widget _buildAuthorsBody(ThemeData theme, ColorScheme cs) {
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
              Icon(
                Icons.error_outline_rounded,
                size: 64,
                color: cs.error,
              ),
              const SizedBox(height: 16),
              Text(
                'Failed to load authors',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      );
    }
    if (_filteredAuthors.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.person_outline_rounded,
                size: 64,
                color: cs.onSurfaceVariant.withOpacity(0.5),
              ),
              const SizedBox(height: 16),
              Text(
                _searchQuery.isNotEmpty
                    ? 'No authors found matching "$_searchQuery"'
                    : 'No authors found',
                style: theme.textTheme.titleLarge?.copyWith(
                  color: cs.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _searchQuery.isNotEmpty
                    ? 'Try adjusting your search terms'
                    : 'Authors will appear here once you have books in your library',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView.builder(
        controller: _scrollCtrl,
        padding: const EdgeInsets.all(16),
        itemCount: _filteredAuthors.length,
        itemBuilder: (context, index) {
          final author = _filteredAuthors[index];
          return _AuthorTile(
            author: author,
            onTap: () => _showAuthorBooks(context, author),
          );
        },
      ),
    );
  }

  Widget _buildAuthorLetterScrollbar(BuildContext context) {
    if (_loading || _error != null || _filteredAuthors.isEmpty) {
      return const SizedBox.shrink();
    }
    final media = MediaQuery.of(context);
    return Positioned(
      right: 4,
      top: media.padding.top + 96,
      bottom: 32,
      child: ValueListenableBuilder<bool>(
        valueListenable: UiPrefs.letterScrollEnabled,
        builder: (_, enabled, __) {
          final visible = enabled && _authorLetterOrder.length > 1;
          if (!visible) return const SizedBox.shrink();
          return SizedBox(
            width: 40,
            child: LetterScrollbar(
              letters: _authorLetterOrder,
              visible: visible,
              onLetterSelected: _scrollAuthorsToLetter,
            ),
          );
        },
      ),
    );
  }
}


class _AuthorTile extends StatelessWidget {
  const _AuthorTile({
    required this.author,
    required this.onTap,
  });

  final AuthorInfo author;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: cs.outline.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Author photo or icon
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: cs.primaryContainer.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Icon(
                  Icons.person_rounded,
                  color: cs.primary,
                  size: 24,
                ),
              ),
              const SizedBox(width: 16),
              // Author info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      author.name,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${author.bookCount} book${author.bookCount == 1 ? '' : 's'}',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
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
