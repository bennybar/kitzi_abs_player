import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/playback_repository.dart';
import '../../widgets/mini_player.dart';
import '../../widgets/download_button.dart';
import '../../main.dart'; // ServicesScope
import '../../ui/player/full_player_page.dart'; // Added import for FullPlayerPage
import 'dart:io';
import '../../core/books_repository.dart' as repo_helpers;
import 'package:just_audio/just_audio.dart';

class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.bookId});
  final String bookId;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late final Future<BooksRepository> _repoFut;
  Future<Book>? _bookFut;
  Future<double?>? _serverProgressFut;
  int? _resolvedDurationMs;
  int? _resolvedSizeBytes;
  bool _kickedResolve = false;

  Future<void> _resolveDurationIfNeeded(Book b, PlaybackRepository playbackRepo) async {
    final current = _resolvedDurationMs ?? b.durationMs ?? 0;
    if (current > 0) return;
    try {
      final open = await playbackRepo.openSessionAndGetTracks(b.id);
      final totalSec = open.tracks.fold<double>(0.0, (a, t) => a + (t.duration > 0 ? t.duration : 0.0));
      if (mounted && totalSec > 0) {
        final ms = (totalSec * 1000).round();
        setState(() { _resolvedDurationMs = ms; });
        // Persist duration so next open is instant
        try {
          final repo = await _repoFut;
          await repo.upsertBook(Book(
            id: b.id,
            title: b.title,
            author: b.author,
            coverUrl: b.coverUrl,
            description: b.description,
            durationMs: ms,
            sizeBytes: b.sizeBytes,
            updatedAt: b.updatedAt,
            authors: b.authors,
            narrators: b.narrators,
            publisher: b.publisher,
            publishYear: b.publishYear,
            genres: b.genres,
          ));
        } catch (_) {}
      }
      if (open.sessionId != null && open.sessionId!.isNotEmpty) {
        unawaited(playbackRepo.closeSessionById(open.sessionId!));
      }
    } catch (_) {}
  }

  Future<void> _resolveSizeIfNeeded(BuildContext context, Book b) async {
    final current = _resolvedSizeBytes ?? b.sizeBytes ?? 0;
    if (current > 0) return;
    try {
      final downloads = ServicesScope.of(context).services.downloads;
      final est = await downloads.estimateTotalBytes(b.id);
      if (mounted && est != null && est > 0) {
        setState(() { _resolvedSizeBytes = est; });
        // Persist estimated size so next open is instant
        try {
          final repo = await _repoFut;
          await repo.upsertBook(Book(
            id: b.id,
            title: b.title,
            author: b.author,
            coverUrl: b.coverUrl,
            description: b.description,
            durationMs: b.durationMs,
            sizeBytes: est,
            updatedAt: b.updatedAt,
            authors: b.authors,
            narrators: b.narrators,
            publisher: b.publisher,
            publishYear: b.publishYear,
            genres: b.genres,
          ));
        } catch (_) {}
        return;
      }

      // Fallback to 0 quietly; UI will keep showing '—'
    } catch (_) {}
  }

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _bookFut = _loadBook();
  }

  Future<Book> _tryLoadFromDb(BooksRepository r) async {
    final cached = await r.getBookFromDb(widget.bookId);
    if (cached != null) return cached;
    throw Exception('Not cached');
  }

  Future<Book> _loadBook() async {
    final repo = await _repoFut;
    try {
      // Try network first; on success, repo persists it
      return await repo.getBook(widget.bookId);
    } catch (_) {
      // On failure (e.g., offline), try local DB
      final cached = await repo.getBookFromDb(widget.bookId);
      if (cached != null) return cached;
      // still failing: surface a meaningful error
      throw Exception('offline_not_cached');
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final pb = ServicesScope.of(context).services.playback;
    _serverProgressFut ??= pb.fetchServerProgress(widget.bookId);
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final playbackRepo = services.playback;
    final downloadsRepo = services.downloads;

    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Book details')),
      body: Stack(
        children: [
          FutureBuilder<Book>(
            future: _bookFut,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snap.hasError || !snap.hasData) {
                return Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      snap.error.toString().contains('offline_not_cached')
                          ? 'This book has not been opened before. Connect to the internet once to cache details for offline access.'
                          : 'Failed to load book.',
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                );
              }

              final b = snap.data!;
              // No verbose logging in production

              String fmtDuration() {
                final ms = _resolvedDurationMs ?? b.durationMs;
                if (ms == null || ms == 0) return 'Unknown';
                final d = Duration(milliseconds: ms);
                final h = d.inHours;
                final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                return h > 0 ? '$h h $m m' : '$m m';
              }

              String fmtSize() {
                final sz = _resolvedSizeBytes ?? b.sizeBytes;
                if (sz == null || sz == 0) return '—';
                final mb = (sz / (1024 * 1024));
                return '${mb.toStringAsFixed(1)} MB';
              }

              // Layout: header and actions stay static; description area scrolls independently.
              return Padding(
                padding: const EdgeInsets.only(bottom: 112), // room for mini player
                child: Column(
                  children: [
                    if (!_kickedResolve) ...[
                      // Kick best-effort resolves once when page builds with data
                      FutureBuilder<void>(
                        future: () async {
                          _kickedResolve = true;
                          await _resolveDurationIfNeeded(b, playbackRepo);
                          await _resolveSizeIfNeeded(context, b);
                        }(),
                        builder: (_, __) => const SizedBox.shrink(),
                      ),
                    ],
                    // Cover, title, and author/narrator in one row
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Builder(
                            builder: (_) {
                              final uri = Uri.tryParse(b.coverUrl);
                              final radius = BorderRadius.circular(12);
                              final coverHeight = b.isAudioBook ? 160.0 : 240.0;
                              
                              Widget coverImage;
                              if (uri != null && uri.scheme == 'file') {
                                coverImage = ClipRRect(
                                  borderRadius: radius,
                                  child: Image.file(
                                    File(uri.toFilePath()),
                                    width: 160,
                                    height: coverHeight,
                                    fit: BoxFit.cover,
                                  ),
                                );
                              } else {
                                coverImage = ClipRRect(
                                  borderRadius: radius,
                                  child: CachedNetworkImage(
                                    imageUrl: b.coverUrl,
                                    width: 160,
                                    height: coverHeight,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) => Container(
                                      width: 160,
                                      height: coverHeight,
                                      alignment: Alignment.center,
                                      color: cs.surfaceContainerHighest,
                                      child: const Icon(Icons.menu_book_outlined, size: 48),
                                    ),
                                  ),
                                );
                              }
                              
                              return Container(
                                decoration: BoxDecoration(
                                  borderRadius: radius,
                                  border: Border.all(
                                    color: cs.outline.withOpacity(0.2),
                                    width: 1,
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: cs.shadow.withOpacity(0.1),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: coverImage,
                              );
                            },
                          ),
                          const SizedBox(width: 20),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Text(b.title, style: text.titleLarge, maxLines: 3, overflow: TextOverflow.ellipsis),
                                const SizedBox(height: 8),
                                Text(b.author ?? 'Unknown author', style: text.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
                                if ((b.narrators ?? const []).isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    'Narrated by ${b.narrators!.join(', ')}',
                                    style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Metadata below in a separate section
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Column(
                        children: [
                          // Publish Year (full width)
                          if (b.publishYear != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _MetaChip(
                                icon: Icons.calendar_today_rounded,
                                label: 'Publish Year',
                                value: b.publishYear.toString(),
                              ),
                            ),
                          // Publisher and Genres in one row
                          if ((b.publisher ?? '').isNotEmpty || (b.genres ?? const []).isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 16),
                              child: Row(
                                children: [
                                  if ((b.publisher ?? '').isNotEmpty)
                                    Expanded(
                                      child: _MetaChip(
                                        icon: Icons.business_rounded,
                                        label: 'Publisher',
                                        value: b.publisher!,
                                      ),
                                    ),
                                  if ((b.publisher ?? '').isNotEmpty && (b.genres ?? const []).isNotEmpty)
                                    const SizedBox(width: 8),
                                  if ((b.genres ?? const []).isNotEmpty)
                                    Expanded(
                                      child: _MetaChip(
                                        icon: Icons.category_rounded,
                                        label: 'Genres',
                                        value: b.genres!.join(' / '),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          // Time/Size chips centered
                          Center(
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 8,
                              children: [
                                _InfoChip(
                                  icon: Icons.schedule,
                                  label: fmtDuration(),
                                  tooltip: 'Total length',
                                  onTap: () async {
                                    // If unknown, try resolving via streaming tracks (then close session)
                                    if ((_resolvedDurationMs ?? b.durationMs ?? 0) == 0) {
                                      try {
                                        final open = await playbackRepo.openSessionAndGetTracks(b.id);
                                        final totalSec = open.tracks.fold<double>(0.0, (a, t) => a + (t.duration > 0 ? t.duration : 0.0));
                                        if (mounted) setState(() { _resolvedDurationMs = (totalSec * 1000).round(); });
                                        if (open.sessionId != null && open.sessionId!.isNotEmpty) {
                                          unawaited(playbackRepo.closeSessionById(open.sessionId!));
                                        }
                                      } catch (_) {}
                                    }
                                    final txt = fmtDuration();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Total length: $txt')),
                                    );
                                  },
                                ),
                                _InfoChip(
                                  icon: Icons.save_alt,
                                  label: fmtSize(),
                                  tooltip: 'Estimated download size',
                                  onTap: () async {
                                    // If unknown, try resolving via /api/items/{id}/files sum of sizes
                                    if ((_resolvedSizeBytes ?? b.sizeBytes ?? 0) == 0) {
                                      try {
                                        final api = ServicesScope.of(context).services.auth.api;
                                        final resp = await api.request('GET', '/api/items/${b.id}/files');
                                        if (resp.statusCode == 200) {
                                          final data = jsonDecode(resp.body);
                                          List list;
                                          if (data is Map && data['files'] is List) {
                                            list = data['files'] as List;
                                          } else if (data is List) list = data;
                                          else list = const [];
                                          int sum = 0;
                                          for (final it in list) {
                                            if (it is Map) {
                                              final m = it.cast<String, dynamic>();
                                              final v = m['size'] ?? m['bytes'] ?? m['fileSize'];
                                              if (v is num) sum += v.toInt();
                                              if (v is String) {
                                                final n = int.tryParse(v);
                                                if (n != null) sum += n;
                                              }
                                            }
                                          }
                                          if (mounted && sum > 0) setState(() { _resolvedSizeBytes = sum; });
                                        }
                                      } catch (_) {}
                                    }
                                    final txt = fmtSize();
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Estimated download size: $txt')),
                                    );
                                  },
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _ProgressSummary(
                          playback: playbackRepo,
                          book: b,
                          serverProgressFuture: _serverProgressFut!,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _PlayPrimaryButton(book: b, playback: playbackRepo),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DownloadButton(
                              libraryItemId: b.id,
                              titleForNotification: b.title,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Scrollable description area
                    if (b.description != null && b.description!.isNotEmpty)
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                          child: SingleChildScrollView(
                            child: _MetaOrDescription(book: b),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),

          // Mini player
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: MiniPlayer(height: 72),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label, this.onTap, this.tooltip});
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: cs.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(label, style: Theme.of(context).textTheme.labelLarge),
        ],
      ),
    );
    final withTooltip = (tooltip != null && tooltip!.isNotEmpty)
        ? Tooltip(message: tooltip!, child: chip)
        : chip;
    if (onTap == null) return withTooltip;
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: withTooltip,
    );
  }
}

class _MetaChip extends StatelessWidget {
  const _MetaChip({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: cs.outline.withOpacity(0.1),
          width: 1,
        ),
      ),
      child: SizedBox(
        height: 80, // Fixed height to ensure consistent sizing
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
          Row(
            children: [
              Icon(icon, size: 16, color: cs.primary),
              const SizedBox(width: 6),
              Text(
                label,
                style: text.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: text.bodyMedium?.copyWith(
              color: cs.onSurface,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        ),
      ),
    );
  }
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: cs.onSurface),
                children: [
                  TextSpan(
                    text: '$label\n',
                    style: Theme.of(context).textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                  ),
                  TextSpan(text: value),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Listening Progress ----------
class _ProgressSummary extends StatelessWidget {
  const _ProgressSummary({
    required this.playback,
    required this.book,
    required this.serverProgressFuture,
  });

  final PlaybackRepository playback;
  final Book book;
  final Future<double?> serverProgressFuture;

  /// Get server progress information including completion status
  Future<Map<String, dynamic>> _getServerProgressInfo(PlaybackRepository playback, String bookId) async {
    try {
      final progress = await playback.fetchServerProgress(bookId);
      final isCompleted = await playback.isBookCompleted(bookId);
      return {
        'progress': progress,
        'isCompleted': isCompleted,
      };
    } catch (e) {
      return {'progress': null, 'isCompleted': false};
    }
  }

  @override
  Widget build(BuildContext context) {
    final isThis = playback.nowPlaying?.libraryItemId == book.id;
    if (isThis) {
      // Live summary based on entire book (all tracks), not per track
      return StreamBuilder<Duration>(
        stream: playback.positionStream,
        initialData: playback.player.position,
        builder: (_, pSnap) {
          final np = playback.nowPlaying;
          final curPos = pSnap.data ?? Duration.zero;
          double totalSec = 0;
          double prefixSec = 0;
          if (np != null && np.tracks.isNotEmpty) {
            for (int i = 0; i < np.tracks.length; i++) {
              final d = np.tracks[i].duration;
              if (d > 0) totalSec += d;
              if (i < np.currentIndex && d > 0) prefixSec += d;
            }
          }
          // Fallback to book duration if tracks have unknown durations
          if (totalSec <= 0 && (book.durationMs ?? 0) > 0) {
            totalSec = (book.durationMs ?? 0) / 1000.0;
          }
          final posSec = prefixSec + curPos.inSeconds;
          final isCompleted = totalSec > 0 && (posSec / totalSec) >= 0.999;
          return _renderTextWithCompletion(context, posSec, totalSec > 0 ? totalSec : null, isCompleted);
        },
      );
    }
    return FutureBuilder<Map<String, dynamic>>(
      future: _getServerProgressInfo(playback, book.id),
      builder: (_, sSnap) {
        if (sSnap.connectionState == ConnectionState.waiting) {
          final cs = Theme.of(context).colorScheme;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('Loading progress...', style: Theme.of(context).textTheme.bodyLarge?.copyWith(color: cs.onSurfaceVariant)),
              ],
            ),
          );
        }
        
        final progressInfo = sSnap.data ?? {'progress': null, 'isCompleted': false};
        final sec = progressInfo['progress'] as double?;
        final isCompleted = progressInfo['isCompleted'] as bool;
        
        return _renderTextWithCompletion(context, sec, (book.durationMs ?? 0) / 1000.0, isCompleted);
      },
    );
  }


  Widget _renderTextWithCompletion(BuildContext context, double? seconds, double? totalSeconds, bool isCompleted) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    if (isCompleted) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.primaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.primary.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_rounded, size: 20, color: cs.primary),
            const SizedBox(width: 8),
            Text(
              'Completed',
              style: text.titleMedium?.copyWith(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    } else if (seconds == null || seconds <= 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.outline.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_outline_rounded, size: 20, color: cs.onSurfaceVariant),
            const SizedBox(width: 8),
            Text(
              'Not started',
              style: text.titleMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      );
    } else if (totalSeconds == null || totalSeconds <= 0) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: cs.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: cs.secondary.withOpacity(0.2),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.play_circle_rounded, size: 20, color: cs.onSecondaryContainer),
            const SizedBox(width: 8),
            Text(
              'In progress',
              style: text.titleMedium?.copyWith(
                color: cs.onSecondaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      );
    } else {
      final progress = seconds / totalSeconds;
      final progressPercent = (progress * 100).round();
      
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: cs.surfaceContainerLow,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: cs.outline.withOpacity(0.1),
            width: 1,
          ),
        ),
        child: Column(
          children: [
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress.clamp(0.0, 1.0),
                backgroundColor: cs.surfaceContainerHighest,
                valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 12),
            // Progress text
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${_fmtHMS(seconds)}',
                  style: text.titleMedium?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${progressPercent}%',
                  style: text.titleMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${_fmtHMS(totalSeconds)}',
                  style: text.titleMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      );
    }
  }

  String _fmtHMS(double sec) {
    final d = Duration(milliseconds: (sec * 1000).round());
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}

class _PlayPrimaryButton extends StatelessWidget {
  const _PlayPrimaryButton({required this.book, required this.playback});
  final Book book;
  final PlaybackRepository playback;

  /// Get book progress information including completion status
  Future<Map<String, dynamic>> _getBookProgressInfo(PlaybackRepository playback, String bookId) async {
    try {
      final progress = await playback.fetchServerProgress(bookId);
      final isCompleted = await playback.isBookCompleted(bookId);
      return {
        'hasProgress': (progress ?? 0) > 0,
        'isCompleted': isCompleted,
      };
    } catch (e) {
      return {'hasProgress': false, 'isCompleted': false};
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!book.isAudioBook) {
      return FilledButton.icon(
        onPressed: null,
        icon: const Icon(Icons.block),
        label: const Text('Not an audiobook'),
      );
    }

    // If this book is currently active, bind to player state and show Stop/Loading
    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (context, nowPlayingSnap) {
        final isThis = nowPlayingSnap.data?.libraryItemId == book.id;
        
        if (isThis) {
      return StreamBuilder<bool>(
        stream: playback.playingStream,
        initialData: playback.player.playing,
        builder: (context, playingSnap) {
          return StreamBuilder<ProcessingState>(
            stream: playback.processingStateStream,
            initialData: playback.player.processingState,
            builder: (context, processingSnap) {
              final isPlaying = playingSnap.data ?? false;
              final processing = processingSnap.data ?? ProcessingState.idle;
              final isBuffering = processing == ProcessingState.loading || processing == ProcessingState.buffering;

              if (isBuffering && !isPlaying) {
                return FilledButton.icon(
                  onPressed: null,
                  icon: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  label: const Text('Loading'),
                );
              }

              if (isPlaying) {
                return FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () async {
                    await playback.stop();
                  },
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop'),
                );
              }

              // Active but paused/ready -> Resume
              return FilledButton.icon(
                onPressed: () async {
                  final ok = await playback.resume();
                  if (!ok && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cannot resume: server unavailable and sync progress is required'),
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                  if (context.mounted) {
                    await FullPlayerPage.openOnce(context);
                  }
                },
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Resume'),
              );
            },
          );
        },
      );
        }

        // Not active on player: decide between Resume vs Play by checking saved progress
        return FutureBuilder<Map<String, dynamic>>(
          future: _getBookProgressInfo(playback, book.id),
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return FilledButton.icon(
                onPressed: null,
                icon: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                label: const Text('Loading...'),
              );
            }
            
            final progressInfo = snap.data ?? {'hasProgress': false, 'isCompleted': false};
            final hasProgress = progressInfo['hasProgress'] as bool;
            final isCompleted = progressInfo['isCompleted'] as bool;
            
            String label;
            IconData icon;
            if (isCompleted) {
              label = 'Start';
              icon = Icons.play_arrow_rounded;
            } else if (hasProgress) {
              label = 'Resume';
              icon = Icons.play_arrow_rounded;
            } else {
              label = 'Play';
              icon = Icons.play_arrow_rounded;
            }
            
            return FilledButton.icon(
              onPressed: () async {
                final success = await playback.playItem(book.id, context: context);
                if (!success && context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Cannot play: server unavailable and sync progress is required'),
                      duration: Duration(seconds: 4),
                    ),
                  );
                  return;
                }
                if (!context.mounted) return;
                await FullPlayerPage.openOnce(context);
              },
              icon: icon == Icons.play_arrow_rounded && isCompleted 
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.check_circle, size: 16, color: Colors.green),
                      const SizedBox(width: 4),
                      Icon(icon, size: 20),
                    ],
                  )
                : Icon(icon),
              label: Text(label),
            );
          },
        );
      },
    );
  }
}

/// Converts JSON-like descriptions to a human-readable list, otherwise shows text as-is.
class _HumanizedDescription extends StatelessWidget {
  const _HumanizedDescription({required this.raw});
  final String raw;

  bool _looksLikeJsonList(String s) {
    final t = s.trim();
    return t.startsWith('[') && t.endsWith(']');
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (_looksLikeJsonList(raw)) {
      try {
        final data = jsonDecode(raw);
        if (data is List) {
          final items = data.cast<dynamic>();
          // Render as a pretty bullet list: "Name (id)"
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final it in items)
                if (it is Map)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('• ', style: text.bodyMedium?.copyWith(color: cs.onSurface)),
                        Expanded(
                          child: Text(
                            '${it['name'] ?? it['title'] ?? 'Item'} (${it['id'] ?? ''})',
                            style: text.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                  ),
            ],
          );
        }
      } catch (_) {
        // fall through to plain text
      }
    }

    return Text(raw, style: Theme.of(context).textTheme.bodyMedium);
  }
}

/// Attempts to parse structured JSON in `Book.description` and render
/// a rich, human-readable metadata panel. Falls back to plain text.
class _MetaOrDescription extends StatelessWidget {
  const _MetaOrDescription({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;

    dynamic parsed;
    try {
      final raw = book.description ?? '';
      parsed = jsonDecode(raw);
    } catch (_) {}

    if (parsed is Map<String, dynamic>) {
      final m = parsed;

      String title = book.title;
      final author = book.author ?? _fromList(m['authors']) ?? _fromList(book.authors);
      final narrators = _fromList(m['narrators']) ?? _fromList(book.narrators);
      final publisher = (m['publisher']?.toString()) ?? book.publisher;
      final year = (m['year']?.toString() ?? m['publishYear']?.toString()) ?? (book.publishYear?.toString());
      final genres = _fromList(m['genres'], sep: ' / ') ?? _fromList(book.genres, sep: ' / ');
      final duration = _formatDurationAny(m['duration'] ?? m['durationMs'] ?? book.durationMs);
      final size = _formatSizeAny(m['size'] ?? book.sizeBytes);

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          if (author != null && author.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text('by $author', style: text.titleMedium?.copyWith(color: cs.onSurfaceVariant)),
          ],
          const SizedBox(height: 16),
          if (narrators != null && narrators.isNotEmpty) _kv('Narrators', narrators, context),
          if (year != null && year.isNotEmpty) _kv('Publish Year', year, context),
          if (publisher != null && publisher.isNotEmpty) _kv('Publisher', publisher, context),
          if (genres != null && genres.isNotEmpty) _kv('Genres', genres, context),
          if (duration != null && duration.isNotEmpty) _kv('Duration', duration, context),
          if (size != null && size.isNotEmpty) _kv('Size', size, context),
        ],
      );
    }

    if (parsed is List) {
      // Show as bullet list using humanizer
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Details', style: text.titleMedium),
          const SizedBox(height: 8),
          _HumanizedDescription(raw: book.description!),
        ],
      );
    }

    // Fallback plain text
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Description', style: text.titleMedium),
        const SizedBox(height: 8),
        _RichDescription(book: book),
      ],
    );
  }

  String? _fromList(dynamic v, {String sep = ', '}) {
    if (v == null) return null;
    if (v is List) {
      final parts = <String>[];
      for (final it in v) {
        if (it is String) parts.add(it);
        if (it is Map && (it['name'] != null || it['title'] != null)) {
          parts.add((it['name'] ?? it['title']).toString());
        }
      }
      return parts.join(sep);
    }
    return v.toString();
  }

  String? _formatDurationAny(dynamic v) {
    if (v == null) return null;
    if (v is int) return _fmt(Duration(milliseconds: v));
    if (v is num) return _fmt(Duration(seconds: v.round())) ;
    if (v is String) {
      final n = num.tryParse(v);
      if (n != null) return _formatDurationAny(n);
    }
    return null;
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h hr $m min' : '$m min';
  }

  String? _formatSizeAny(dynamic v) {
    if (v == null) return null;
    num? bytes;
    if (v is num) bytes = v;
    if (v is String) bytes = num.tryParse(v);
    if (bytes == null) return null;
    final mb = bytes / (1024 * 1024);
    return '${mb.toStringAsFixed(2)} MB';
  }

  Widget _kv(String k, String v, BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(k, style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant)),
          const SizedBox(height: 2),
          Text(v, style: text.bodyMedium),
        ],
      ),
    );
  }
}

class _RichDescription extends StatelessWidget {
  const _RichDescription({required this.book});
  final Book book;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final raw = book.description ?? '';
    if (raw.isEmpty) return const SizedBox.shrink();
    final re = RegExp(r'https?://[^\s"\)]+\.(?:png|jpg|jpeg|webp|gif)', caseSensitive: false);
    final parts = <InlineSpan>[];
    int last = 0;
    for (final m in re.allMatches(raw)) {
      if (m.start > last) {
        parts.add(TextSpan(text: raw.substring(last, m.start)));
      }
      final url = m.group(0)!;
      parts.add(WidgetSpan(
        alignment: PlaceholderAlignment.baseline,
        baseline: TextBaseline.alphabetic,
        child: FutureBuilder<Uri>(
          future: repo_helpers.BooksRepository.localOrRemoteDescriptionImageUri(book.id, url),
          builder: (_, snap) {
            final uri = snap.data;
            if (uri == null) return const SizedBox.shrink();
            if (uri.scheme == 'file') {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Image.file(
                  File(uri.toFilePath()),
                  fit: BoxFit.cover,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Image.network(uri.toString(), fit: BoxFit.cover),
            );
          },
        ),
      ));
      last = m.end;
    }
    if (last < raw.length) {
      parts.add(TextSpan(text: raw.substring(last)));
    }
    return RichText(text: TextSpan(style: text.bodyMedium, children: parts));
  }
}
