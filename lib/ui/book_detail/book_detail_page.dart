import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:rxdart/rxdart.dart';
import 'dart:io';
import 'package:flutter_html/flutter_html.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/playback_repository.dart';
import '../../widgets/download_button.dart';
import '../../main.dart'; // ServicesScope
import '../../ui/player/full_player_page.dart'; // Added import for FullPlayerPage
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
  bool _isResolvingDuration = false; // Prevent concurrent duration resolution
  bool _isResolvingSize = false; // Prevent concurrent size resolution

  Future<void> _resolveDurationIfNeeded(Book b, PlaybackRepository playbackRepo) async {
    final current = _resolvedDurationMs ?? b.durationMs ?? 0;
    if (current > 0) return;
    
    // Don't automatically resolve duration on page load to prevent unnecessary transcoding sessions
    // Duration will be resolved when user explicitly requests it (e.g., taps duration chip)
    // or when they actually start playing the book
    return;
  }

  Future<void> _resolveSizeIfNeeded(BuildContext context, Book b) async {
    final current = _resolvedSizeBytes ?? b.sizeBytes ?? 0;
    if (current > 0) return;
    
    // Don't automatically resolve size on page load to prevent unnecessary API calls
    // Size will be resolved when user explicitly requests it (e.g., taps size chip)
    return;
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

  Stream<bool> _getBookCompletionStream(PlaybackRepository playback, String bookId) {
    // Start with the current cache value to avoid race conditions
    final currentValue = playback.completionCache[bookId] ?? false;
    debugPrint('[COMPLETION_DEBUG] _getBookCompletionStream: book=$bookId, currentCacheValue=$currentValue');
    
    return playback.getBookCompletionStream(bookId).startWith(currentValue);
  }

  Future<void> _toggleBookCompletion(BuildContext context, Book book, bool isCurrentlyCompleted) async {
    final playback = ServicesScope.of(context).services.playback;
    final newCompletionStatus = !isCurrentlyCompleted;
    
    debugPrint('[COMPLETION_DEBUG] Toggle called: book=${book.id}, current=$isCurrentlyCompleted, new=$newCompletionStatus');
    debugPrint('[COMPLETION_DEBUG] Cache before: ${playback.completionCache[book.id]}');
    
    // Show confirmation dialog(s)
    Duration? unfinishChoice; // null => cancel, 0 => restart, >0 => resume to that
    if (newCompletionStatus) {
      final confirmed = await _showMarkAsFinishedDialog(context);
      if (!confirmed) return;
    } else {
      unfinishChoice = await _showMarkAsUnfinishedDialog(context, book);
      if (unfinishChoice == null) return; // cancelled
    }
    
    // Save current position and playback state if we're unfinishing
    Duration? savedPosition;
    bool wasPlaying = false;
    if (!newCompletionStatus && playback.nowPlaying?.libraryItemId == book.id) {
      savedPosition = playback.player.position;
      wasPlaying = playback.player.playing;
      debugPrint('[COMPLETION_DEBUG] Saved position: ${savedPosition.inSeconds}s, wasPlaying: $wasPlaying');
    }
    
    // Stop any ongoing playback immediately when marking as finished
    if (newCompletionStatus) {
      try {
        await playback.stop();
        debugPrint('[COMPLETION_DEBUG] Stopped playback before marking as finished');
      } catch (e) {
        debugPrint('[COMPLETION_DEBUG] Error stopping playback: $e');
      }
    }
  
    try {
      // Send the request to server (this will also update the cache)
      double? overrideSeconds;
      if (!newCompletionStatus && unfinishChoice != null) {
        overrideSeconds = unfinishChoice.inSeconds.toDouble();
      }
      await _markBookAsFinished(context, book.id, newCompletionStatus, overrideCurrentTimeSeconds: overrideSeconds);
      
      debugPrint('[COMPLETION_DEBUG] Cache after: ${playback.completionCache[book.id]}');
      
      // If unfinishing, apply the user's choice locally if this book is active
      if (!newCompletionStatus && playback.nowPlaying?.libraryItemId == book.id && unfinishChoice != null) {
        final chosen = unfinishChoice;
        debugPrint('[COMPLETION_DEBUG] Applying user choice after unfinish: seek to ${chosen.inSeconds}s');
        try {
          // Wait a bit for the API call to complete
          await Future.delayed(const Duration(milliseconds: 500));

          // Seek to the saved position (the one we actually sent to the server)
          // Use seekGlobal for multi-track books to properly map position across tracks
          await playback.seekGlobal(chosen, reportNow: true);

          // Resume playback if it was playing before
          if (wasPlaying) {
            // Temporarily disable sync to avoid overriding our preserved position
            await playback.resume(skipSync: true);
            debugPrint('[COMPLETION_DEBUG] Resumed playback at saved position (sync disabled)');
          }

          // Push the position to server after a delay to ensure it's preserved
          Future.delayed(const Duration(seconds: 1), () async {
            try {
              debugPrint('[COMPLETION_DEBUG] Pushing position to server after unfinish: ${savedPosition?.inSeconds}s');
              await playback.reportProgressNow();
            } catch (e) {
              debugPrint('[COMPLETION_DEBUG] Error pushing position to server: $e');
            }
          });
        } catch (e) {
          debugPrint('[COMPLETION_DEBUG] Error seeking to saved position: $e');
        }
      }
      
      // Show feedback to user
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(newCompletionStatus ? 'Book marked as finished' : 'Book marked as unread'),
            duration: const Duration(seconds: 2),
          ),
        );
        
        // Refresh the page to ensure UI is completely up-to-date
        setState(() {
          // This will trigger a rebuild of the entire page
        });
      }
      
    } catch (e) {
      debugPrint('[COMPLETION_DEBUG] Error toggling completion: $e');
      
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update book status: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<bool> _showMarkAsFinishedDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Mark as Finished',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Are you sure you want to mark this book as finished?',
          style: text.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark as Finished'),
          ),
        ],
      ),
    );
    
    return confirmed ?? false;
  }

  Future<Duration?> _showMarkAsUnfinishedDialog(BuildContext context, Book book) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final playback = ServicesScope.of(context).services.playback;
    
    // Get current position from server (more reliable than local player position)
    final currentPositionSeconds = await playback.fetchServerProgress(book.id);
    final currentPosition = currentPositionSeconds != null 
        ? Duration(seconds: currentPositionSeconds.round())
        : playback.player.position;
    final positionText = _formatDuration(currentPosition);
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Mark as Unfinished',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to mark this book as unfinished?',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: cs.primaryContainer,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: cs.primary.withOpacity(0.3),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.access_time_rounded,
                    size: 16,
                    color: cs.onPrimaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Current position: $positionText',
                    style: text.bodyMedium?.copyWith(
                      color: cs.onPrimaryContainer,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'This position will be preserved.',
              style: text.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark as Unfinished'),
          ),
        ],
      ),
    );
    if (confirmed != true) return null;

    // Second step: choose where to resume
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Choose where to resume',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'Resume from the preserved position or start from the beginning.',
          style: text.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop('cancel'),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop('restart'),
            child: const Text('Start from beginning'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop('resume'),
            child: Text('Return to $positionText'),
          ),
        ],
      ),
    );

    if (choice == 'restart') return Duration.zero;
    if (choice == 'resume') return currentPosition; // default to resume
    return null; // cancel
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Future<void> _markBookAsFinished(BuildContext context, String libraryItemId, bool finished, {double? overrideCurrentTimeSeconds}) async {
    final playback = ServicesScope.of(context).services.playback;
    final api = ServicesScope.of(context).services.auth.api;
    
    // Prepare the request body
    Map<String, dynamic> requestBody = {'isFinished': finished};

    // If unfinishing, include current progress to preserve position
    // Always do this using server progress when available (even if this book isn't currently playing)
    if (!finished) {
      // Get position from server (more reliable than local player position)
      double? currentPositionSeconds = await playback.fetchServerProgress(libraryItemId);
      if (overrideCurrentTimeSeconds != null) {
        currentPositionSeconds = overrideCurrentTimeSeconds;
      }
      final bool isActiveOnPlayer = playback.nowPlaying?.libraryItemId == libraryItemId;
      final currentTimeSeconds = currentPositionSeconds ?? (isActiveOnPlayer ? playback.player.position.inSeconds.toDouble() : 0.0);

      // Always include currentTime when override was provided, even if 0; otherwise include only when > 0
      final shouldInclude = overrideCurrentTimeSeconds != null || currentTimeSeconds > 0;
      if (shouldInclude) {
        requestBody['currentTime'] = currentTimeSeconds;

        // Include duration and progress like regular progress updates
        final totalDuration = playback.totalBookDuration;
        if (totalDuration != null && totalDuration.inSeconds > 0) {
          final totalSeconds = totalDuration.inSeconds.toDouble();
          requestBody['duration'] = totalSeconds;
          requestBody['progress'] = (currentTimeSeconds / totalSeconds).clamp(0.0, 1.0);
          debugPrint('[COMPLETION_DEBUG] Including full progress: currentTime=${currentTimeSeconds}s, duration=${totalSeconds}s, progress=${requestBody['progress']}');
        } else {
          debugPrint('[COMPLETION_DEBUG] Including currentTime: ${currentTimeSeconds}s to preserve position (no duration available)');
        }
      }
    }
    
    debugPrint('[COMPLETION_DEBUG] API request: PATCH /api/me/progress/$libraryItemId, body=$requestBody');
    
    try {
      final response = await api.request(
        'PATCH',
        '/api/me/progress/$libraryItemId',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      
      debugPrint('[COMPLETION_DEBUG] API response: ${response.statusCode}');
      
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('[COMPLETION_DEBUG] Updating cache: $libraryItemId -> $finished');
        // Update the global completion status cache and notify all listeners
        await playback.updateBookCompletionStatus(libraryItemId, finished);
        debugPrint('[COMPLETION_DEBUG] Cache updated successfully');

        // Persist the chosen progress locally so the next Play uses it
        if (!finished && overrideCurrentTimeSeconds != null) {
          try {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setDouble('abs_progress:$libraryItemId', overrideCurrentTimeSeconds);
          } catch (_) {}
        }
      } else {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      debugPrint('[COMPLETION_DEBUG] API Error: $e');
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    final services = ServicesScope.of(context).services;
    final playbackRepo = services.playback;
    final downloadsRepo = services.downloads;

    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      body: Column(
        children: [
          // Material Design drag handle (centered, subtle)
          Center(
            child: Container(
              width: 32,
              height: 4,
              margin: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: cs.onSurfaceVariant.withOpacity(0.4),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          // Header with title and mark as finished button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Book Details',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                // Mark as finished button - only show for audio books
                FutureBuilder<Book>(
                  future: _bookFut,
                  builder: (context, bookSnap) {
                    if (bookSnap.connectionState != ConnectionState.done || !bookSnap.hasData) {
                      return const SizedBox.shrink();
                    }
                    
                    final book = bookSnap.data!;
                    if (!book.isAudioBook) {
                      return const SizedBox.shrink();
                    }
                    
                    return StreamBuilder<bool>(
                      stream: _getBookCompletionStream(playbackRepo, book.id),
                      initialData: false,
                      builder: (_, completionSnap) {
                        final isCompleted = completionSnap.data ?? false;
                        final label = isCompleted ? 'Mark as Unfinished' : 'Mark as Finished';
                        return FilledButton.tonal(
                          onPressed: () => _toggleBookCompletion(context, book, isCompleted),
                          style: FilledButton.styleFrom(
                            backgroundColor: isCompleted 
                                ? cs.errorContainer 
                                : cs.surfaceContainerHighest,
                            foregroundColor: isCompleted 
                                ? cs.onErrorContainer 
                                : cs.onSurface,
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          ),
                          child: Text(label),
                        );
                      },
                    );
                  },
                ),
              ],
            ),
          ),
          // Content
          Expanded(
            child: FutureBuilder<Book>(
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
                return Column(
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
                                      // Prevent concurrent duration resolution
                                      if (_isResolvingDuration) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Duration is already being loaded...'),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                        return;
                                      }
                                      
                                      _isResolvingDuration = true;
                                      try {
                                        // Show loading indicator
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Row(
                                                children: [
                                                  SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text('Loading duration...'),
                                                ],
                                              ),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                        
                                        final open = await playbackRepo.openSessionAndGetTracks(b.id);
                                        final totalSec = open.tracks.fold<double>(0.0, (a, t) => a + (t.duration > 0 ? t.duration : 0.0));
                                        if (mounted && totalSec > 0) {
                                          final ms = (totalSec * 1000).round();
                                          setState(() { _resolvedDurationMs = ms; });
                                          
                                          // Persist duration to local cache for future use
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
                                        
                                        // Always close the session to prevent transcoding from continuing
                                        if (open.sessionId != null && open.sessionId!.isNotEmpty) {
                                          await playbackRepo.closeSessionById(open.sessionId!);
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Failed to load duration: $e'),
                                              backgroundColor: Theme.of(context).colorScheme.error,
                                            ),
                                          );
                                        }
                                        return;
                                      } finally {
                                        _isResolvingDuration = false;
                                      }
                                    }
                                    
                                    final txt = fmtDuration();
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Total length: $txt')),
                                      );
                                    }
                                  },
                                ),
                                _InfoChip(
                                  icon: Icons.save_alt,
                                  label: fmtSize(),
                                  tooltip: 'Estimated download size',
                                  onTap: () async {
                                    // If unknown, try resolving via /api/items/{id}/files sum of sizes
                                    if ((_resolvedSizeBytes ?? b.sizeBytes ?? 0) == 0) {
                                      // Prevent concurrent size resolution
                                      if (_isResolvingSize) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Text('Size is already being loaded...'),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                        return;
                                      }
                                      
                                      _isResolvingSize = true;
                                      try {
                                        // Show loading indicator
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(
                                              content: Row(
                                                children: [
                                                  SizedBox(
                                                    width: 16,
                                                    height: 16,
                                                    child: CircularProgressIndicator(strokeWidth: 2),
                                                  ),
                                                  SizedBox(width: 8),
                                                  Text('Loading size...'),
                                                ],
                                              ),
                                              duration: Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                        
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
                                          if (mounted && sum > 0) {
                                            setState(() { _resolvedSizeBytes = sum; });
                                            
                                            // Persist size to local cache for future use
                                            try {
                                              final repo = await _repoFut;
                                              await repo.upsertBook(Book(
                                                id: b.id,
                                                title: b.title,
                                                author: b.author,
                                                coverUrl: b.coverUrl,
                                                description: b.description,
                                                durationMs: b.durationMs,
                                                sizeBytes: sum,
                                                updatedAt: b.updatedAt,
                                                authors: b.authors,
                                                narrators: b.narrators,
                                                publisher: b.publisher,
                                                publishYear: b.publishYear,
                                                genres: b.genres,
                                              ));
                                            } catch (_) {}
                                          }
                                        }
                                      } catch (e) {
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text('Failed to load size: $e'),
                                              backgroundColor: Theme.of(context).colorScheme.error,
                                            ),
                                          );
                                        }
                                        return;
                                      } finally {
                                        _isResolvingSize = false;
                                      }
                                    }
                                    
                                    final txt = fmtSize();
                                    if (mounted) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('Estimated download size: $txt')),
                                      );
                                    }
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
                            child: _PlayPrimaryButton(
                              book: b, 
                              playback: playbackRepo,
                              onResetPerformed: () {
                                // Refresh the page after reset
                                setState(() {
                                  // This will trigger a rebuild of the entire page
                                });
                              },
                            ),
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
                );
              },
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
          Expanded(
            child: Center(
              child: Text(
                value,
                style: text.bodyMedium?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
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

  /// Format duration for display
  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    
    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  /// Get server progress information including completion status
  Future<Map<String, dynamic>> _getServerProgressInfo(PlaybackRepository playback, String bookId) async {
    try {
      final progress = await playback.fetchServerProgress(bookId);
      // Always fetch fresh completion status from server to ensure accuracy
      final isCompleted = await playback.isBookCompleted(bookId);
      // Update the cache with the fresh data
      playback.completionCache[bookId] = isCompleted;
      return {
        'progress': progress,
        'isCompleted': isCompleted,
      };
    } catch (e) {
      return {'progress': null, 'isCompleted': false};
    }
  }

  Stream<Map<String, dynamic>> _getServerProgressStream(PlaybackRepository playback, String bookId) async* {
    // First emit the initial server progress data
    final initialData = await _getServerProgressInfo(playback, bookId);
    yield initialData;
    
    // Then listen to completion status changes and emit updated data
    await for (final completionMap in playback.completionStatusStream) {
      if (completionMap.containsKey(bookId)) {
        final isCompleted = completionMap[bookId]!;
        yield {
          'progress': initialData['progress'],
          'isCompleted': isCompleted,
        };
      }
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
    return StreamBuilder<Map<String, dynamic>>(
      stream: _getServerProgressStream(playback, book.id),
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
      // No action (redundant with top unfinish button)
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
                  _fmtHMS(seconds),
                  style: text.titleMedium?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '$progressPercent%',
                  style: text.titleMedium?.copyWith(
                    color: cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  _fmtHMS(totalSeconds),
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

  Future<void> _showResetProgressDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Mark as Unfinished',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'This book is currently marked as finished. Do you want to reset it to the beginning?',
          style: text.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
            child: const Text('Reset to Beginning'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _resetBookProgress(context, resetToBeginning: true);
    }
  }



  Future<void> _resetBookProgress(BuildContext context, {required bool resetToBeginning}) async {
    final cs = Theme.of(context).colorScheme;
    
    try {
      final api = ServicesScope.of(context).services.auth.api;
      
      // Always do a full reset (isFinished: false, currentTime: 0)
      final requestBody = {
        'isFinished': false,
        'currentTime': 0,
      };
      
      final response = await api.request(
        'PATCH',
        '/api/me/progress/${book.id}',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      
      if (response.statusCode == 200 || response.statusCode == 204) {
        // Clear local progress cache to ensure fresh start
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('abs_progress:${book.id}');
        } catch (e) {
          // Ignore cache clearing errors
        }
        
        // Update the global completion status cache and notify all listeners
        await playback.updateBookCompletionStatus(book.id, false);
        
        if (context.mounted && resetToBeginning) {
          // Start playing the book after reset
          final success = await playback.playItem(book.id, context: context);
          if (success) {
            // Open the full player page
            await FullPlayerPage.openOnce(context);
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Book reset and started playing'),
                backgroundColor: cs.primary,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Book reset but failed to start playing'),
                backgroundColor: cs.error,
              ),
            );
          }
        }
      } else {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reset progress: $e'),
            backgroundColor: cs.error,
          ),
        );
      }
    }
  }

}

class _PlayPrimaryButton extends StatelessWidget {
  const _PlayPrimaryButton({
    required this.book, 
    required this.playback,
    this.onResetPerformed,
  });
  final Book book;
  final PlaybackRepository playback;
  final VoidCallback? onResetPerformed;

  /// Show reset dialog for completed book
  /// Returns true if reset was performed, false if cancelled
  Future<bool> _showResetDialogForCompletedBook(BuildContext context, String bookId) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          'Mark as Unfinished',
          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        content: Text(
          'This book is currently marked as finished. Do you want to reset it to the beginning?',
          style: text.bodyMedium,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(
              'Cancel',
              style: TextStyle(color: cs.onSurfaceVariant),
            ),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: cs.primary,
              foregroundColor: cs.onPrimary,
            ),
            child: const Text('Reset to Beginning'),
          ),
        ],
      ),
    );
    
    if (confirmed == true) {
      await _resetBookProgressForCompletedBook(context, bookId);
      return true;
    }
    return false;
  }

  /// Reset book progress for completed book
  Future<void> _resetBookProgressForCompletedBook(BuildContext context, String bookId) async {
    final cs = Theme.of(context).colorScheme;
    
    try {
      final api = ServicesScope.of(context).services.auth.api;
      
      final requestBody = {
        'isFinished': false,
        'currentTime': 0,
      };
      
      final response = await api.request(
        'PATCH',
        '/api/me/progress/$bookId',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      
      if (response.statusCode == 200 || response.statusCode == 204) {
        // Clear local progress cache to ensure fresh start
        try {
          final prefs = await SharedPreferences.getInstance();
          await prefs.remove('abs_progress:$bookId');
        } catch (e) {
          // Ignore cache clearing errors
        }
        
        await playback.updateBookCompletionStatus(bookId, false);
        
        // Start playing the book after reset
        if (context.mounted) {
          final success = await playback.playItem(bookId, context: context);
          if (success) {
            // Open the full player page
            await FullPlayerPage.openOnce(context);
            
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Book reset and started playing'),
                backgroundColor: cs.primary,
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text('Book reset but failed to start playing'),
                backgroundColor: cs.error,
              ),
            );
          }
          
          // Note: Page refresh will be handled by the parent widget
        }
      } else {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to reset progress: $e'),
            backgroundColor: cs.error,
          ),
        );
      }
    }
  }

  /// Get book progress information including completion status
  Future<Map<String, dynamic>> _getBookProgressInfo(PlaybackRepository playback, String bookId) async {
    try {
      final progress = await playback.fetchServerProgress(bookId);
      
      // ALWAYS use cached completion status - don't fetch from server
      // The cache is the source of truth for UI state
      bool isCompleted = playback.completionCache[bookId] ?? false;
      
      debugPrint('[COMPLETION_DEBUG] _getBookProgressInfo: book=$bookId, progress=$progress, isCompleted=$isCompleted');
      debugPrint('[COMPLETION_DEBUG] Cache contains key: ${playback.completionCache.containsKey(bookId)}');
      debugPrint('[COMPLETION_DEBUG] Cache value: ${playback.completionCache[bookId]}');
      debugPrint('[COMPLETION_DEBUG] Full cache: ${playback.completionCache}');
      debugPrint('[COMPLETION_DEBUG] Cache lookup: ${playback.completionCache[bookId] ?? false}');
      
      return {
        'hasProgress': (progress ?? 0) > 0,
        'isCompleted': isCompleted,
      };
    } catch (e) {
      debugPrint('[COMPLETION_DEBUG] Error in _getBookProgressInfo: $e');
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
              
              // More robust check: ensure we have a valid nowPlaying item and it's actually playing
              final hasValidNowPlaying = isThis && (processing == ProcessingState.ready || processing == ProcessingState.completed);
              final shouldShowAsPlaying = hasValidNowPlaying && isPlaying;

              if (isBuffering && !isPlaying) {
                return FilledButton.icon(
                  onPressed: null,
                  icon: const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  label: const Text('Loading'),
                );
              }

              if (shouldShowAsPlaying) {
                return FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.error,
                    foregroundColor: Theme.of(context).colorScheme.onError,
                  ),
                  onPressed: () async {
                    debugPrint('[BOOK_DETAILS] Stop button pressed. isPlaying: $isPlaying, hasValidNowPlaying: $hasValidNowPlaying, shouldShowAsPlaying: $shouldShowAsPlaying');
                    await playback.pause();
                    debugPrint('[BOOK_DETAILS] Pause completed');
                  },
                  icon: const Icon(Icons.stop_rounded),
                  label: const Text('Stop'),
                );
              }

              // Active but paused/ready -> Resume
              return FilledButton.icon(
                onPressed: () async {
                  debugPrint('[BOOK_DETAILS] Resume button pressed. isPlaying: $isPlaying, hasValidNowPlaying: $hasValidNowPlaying, shouldShowAsPlaying: $shouldShowAsPlaying, NowPlaying: ${playback.nowPlaying?.title}');
                  // Try to resume first, but if that fails (no current item), 
                  // warm load the last item and play it
                  bool success = await playback.resume();
                  debugPrint('[BOOK_DETAILS] Resume result: $success');
                  if (!success) {
                    try {
                      debugPrint('[BOOK_DETAILS] Resume failed, trying warmLoadLastItem');
                      await playback.warmLoadLastItem(playAfterLoad: true);
                      success = true; // Consider warm load a success
                      debugPrint('[BOOK_DETAILS] WarmLoadLastItem succeeded');
                    } catch (e) {
                      debugPrint('[BOOK_DETAILS] WarmLoadLastItem failed: $e');
                      success = false;
                    }
                  }
                  
                  if (!success && context.mounted) {
                    debugPrint('[BOOK_DETAILS] Both resume and warmLoad failed, showing error');
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cannot play: server unavailable and sync progress is required'),
                        duration: Duration(seconds: 4),
                      ),
                    );
                  } else if (success && context.mounted) {
                    debugPrint('[BOOK_DETAILS] Success, opening full player');
                    // Only open the full player page when resume/play succeeds
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
                // Check cache directly to avoid race conditions
                final currentCompletionStatus = playback.completionCache[book.id] ?? false;
                debugPrint('[COMPLETION_DEBUG] Play button pressed: book=${book.id}, streamIsCompleted=$isCompleted, cacheIsCompleted=$currentCompletionStatus, label=$label');
                
                // Use cache value as source of truth for completion status
                if (currentCompletionStatus) {
                  debugPrint('[COMPLETION_DEBUG] Book is completed (from cache), showing reset dialog');
                  final resetPerformed = await _showResetDialogForCompletedBook(context, book.id);
                  if (resetPerformed && onResetPerformed != null) {
                    onResetPerformed!();
                  }
                  return;
                }
                
                debugPrint('[COMPLETION_DEBUG] Book not completed (from cache), starting playback');
                
                // Start playback in background and open full player immediately
                unawaited(playback.playItem(book.id, context: context).then((success) {
                  if (!success && context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Cannot play: server unavailable and sync progress is required'),
                        duration: Duration(seconds: 4),
                      ),
                    );
                  }
                }));
                
                // Open full player page immediately - it will show loading state until NowPlaying is ready
                if (context.mounted) {
                  await FullPlayerPage.openOnce(context);
                }
              },
              icon: Icon(icon),
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

  /// Check if the string contains HTML tags
  bool _isHtml(String text) {
    final htmlPattern = RegExp(r'<\/?[a-z][\s\S]*>', caseSensitive: false);
    return htmlPattern.hasMatch(text);
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final raw = book.description ?? '';
    if (raw.isEmpty) return const SizedBox.shrink();
    
    // Check if description is HTML
    if (_isHtml(raw)) {
      return Html(
        data: raw,
        style: {
          "body": Style(
            margin: Margins.zero,
            padding: HtmlPaddings.zero,
            fontSize: FontSize(text.bodyMedium?.fontSize ?? 14),
            color: cs.onSurface,
            lineHeight: const LineHeight(1.5),
          ),
          "p": Style(
            margin: Margins.only(bottom: 8),
          ),
          "a": Style(
            color: cs.primary,
            textDecoration: TextDecoration.underline,
          ),
          "strong": Style(
            fontWeight: FontWeight.bold,
          ),
          "em": Style(
            fontStyle: FontStyle.italic,
          ),
          "h1, h2, h3, h4, h5, h6": Style(
            fontWeight: FontWeight.bold,
            margin: Margins.only(top: 12, bottom: 8),
          ),
          "ul, ol": Style(
            margin: Margins.only(bottom: 8),
            padding: HtmlPaddings.only(left: 20),
          ),
          "li": Style(
            margin: Margins.only(bottom: 4),
          ),
        },
      );
    }
    
    // Original behavior for non-HTML (image URL detection)
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
