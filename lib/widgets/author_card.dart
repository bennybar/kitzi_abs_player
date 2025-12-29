import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/book.dart';
import '../core/books_repository.dart';
import '../core/image_cache_manager.dart';
import '../ui/book_detail/book_detail_page.dart';

class AuthorCard extends StatefulWidget {
  const AuthorCard({
    super.key,
    required this.author,
  });

  final AuthorInfo author;

  static Future<void> show({
    required BuildContext context,
    required AuthorInfo author,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AuthorCard(
        author: author,
      ),
    );
  }

  @override
  State<AuthorCard> createState() => _AuthorCardState();
}

class _AuthorCardState extends State<AuthorCard> {
  @override
  void initState() {
    super.initState();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    return Container(
      height: MediaQuery.of(context).size.height * 0.8,
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          // Handle bar
          Container(
            margin: const EdgeInsets.only(top: 12),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: cs.onSurfaceVariant.withOpacity(0.4),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Header
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    // Author image or icon
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: cs.primaryContainer.withOpacity(0.3),
                        borderRadius: BorderRadius.circular(32),
                      ),
                      child: widget.author.imageUrl != null && widget.author.imageUrl!.isNotEmpty
                          ? ClipRRect(
                              borderRadius: BorderRadius.circular(32),
                              child: CachedNetworkImage(
                                imageUrl: widget.author.imageUrl!,
                                cacheManager: ImageCacheManager.instance,
                                fit: BoxFit.cover,
                                placeholder: (context, url) => Icon(
                                  Icons.person_rounded,
                                  color: cs.primary,
                                  size: 32,
                                ),
                                errorWidget: (context, url, error) => Icon(
                                  Icons.person_rounded,
                                  color: cs.primary,
                                  size: 32,
                                ),
                              ),
                            )
                          : Icon(
                              Icons.person_rounded,
                              color: cs.primary,
                              size: 32,
                            ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.author.name,
                            style: theme.textTheme.headlineSmall?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${widget.author.books.length} book${widget.author.books.length == 1 ? '' : 's'}',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
                // Author description
                if (widget.author.description != null && widget.author.description!.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Text(
                    widget.author.description!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                    maxLines: 4,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // Books list
          Expanded(
            child: widget.author.books.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.book_outlined,
                          size: 64,
                          color: cs.onSurfaceVariant.withOpacity(0.5),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No books found',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    itemCount: widget.author.books.length,
                    itemBuilder: (context, index) {
                      final book = widget.author.books[index];
                      return _AuthorBookTile(
                        book: book,
                        onTap: () {
                          // Open book detail as modal on top of author books
                          // Don't close the author books modal - when book detail is dismissed,
                          // user returns to this author's books list
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

class _AuthorBookTile extends StatelessWidget {
  const _AuthorBookTile({
    required this.book,
    required this.onTap,
  });

  final Book book;
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
              // Book cover
              Container(
                width: 60,
                height: 90,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  boxShadow: [
                    BoxShadow(
                      color: cs.shadow.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: ColorFiltered(
                    colorFilter: !book.isAudioBook
                        ? ColorFilter.mode(cs.surface.withOpacity(0.12), BlendMode.saturation)
                        : const ColorFilter.mode(Colors.transparent, BlendMode.srcOver),
                    child: EnhancedCoverImage(url: book.coverUrl),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              // Book info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      book.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    if (book.series != null) ...[
                      Text(
                        book.series!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.primary,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                    ],
                    if (book.durationMs != null) ...[
                      Text(
                        _formatDuration(book.durationMs!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (!book.isAudioBook) ...[
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.block,
                            size: 14,
                            color: cs.onSurfaceVariant.withOpacity(0.6),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            'Not an audiobook',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
              // Play button or disabled indicator
              if (book.isAudioBook)
                IconButton(
                  onPressed: onTap,
                  icon: Icon(
                    Icons.play_circle_outline_rounded,
                    color: cs.primary,
                  ),
                )
              else
                Icon(
                  Icons.block_rounded,
                  color: cs.onSurfaceVariant.withOpacity(0.4),
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
