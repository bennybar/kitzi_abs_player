import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../player/full_player_sheet.dart';
import '../player/mini_player.dart';
import '../../main.dart'; // ServicesScope

class BookDetailPage extends StatefulWidget {
  const BookDetailPage({super.key, required this.bookId});
  final String bookId;

  @override
  State<BookDetailPage> createState() => _BookDetailPageState();
}

class _BookDetailPageState extends State<BookDetailPage> {
  late final Future<BooksRepository> _repoFut;
  Future<Book>? _bookFut;

  DownloadsRepository? _downloadsRepo;
  PlaybackRepository? _playbackRepo;
  bool _depsInited = false;

  Future<double?>? _serverProgressFut;

  @override
  void initState() {
    super.initState();
    _repoFut = BooksRepository.create();
    _bookFut = _repoFut.then((r) => r.getBook(widget.bookId));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_depsInited) return;
    final services = ServicesScope.of(context).services;
    _downloadsRepo = services.downloads..init();
    _playbackRepo = services.playback;
    _serverProgressFut = _playbackRepo!.fetchServerProgress(widget.bookId);
    _depsInited = true;
  }

  void _openFullPlayer(PlaybackRepository pb) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FullPlayerSheet(playback: pb),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final playbackRepo = _playbackRepo;
    final downloadsRepo = _downloadsRepo;
    if (playbackRepo == null || downloadsRepo == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Book')),
      body: Stack(
        children: [
          FutureBuilder<Book>(
            future: _bookFut,
            builder: (context, snap) {
              if (!snap.hasData) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('Error: ${snap.error}', style: TextStyle(color: cs.error)),
                    ),
                  );
                }
                return const Center(child: CircularProgressIndicator());
              }

              final b = snap.data!;

              return Padding(
                // leave room for mini-player if showing
                padding: const EdgeInsets.only(bottom: 72),
                child: Column(
                  children: [
                    // Scrollable content
                    Expanded(
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(12),
                                  child: CachedNetworkImage(
                                    imageUrl: b.coverUrl,
                                    width: 140,
                                    height: 210,
                                    fit: BoxFit.cover,
                                    errorWidget: (_, __, ___) => Container(
                                      width: 140,
                                      height: 210,
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color: cs.surfaceContainerHighest,
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: const Icon(Icons.menu_book_outlined, size: 48),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 16),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(b.title, style: Theme.of(context).textTheme.titleLarge),
                                      const SizedBox(height: 4),
                                      Text(b.author ?? 'Unknown', style: Theme.of(context).textTheme.bodyMedium),
                                      const SizedBox(height: 12),
                                      if (b.durationMs != null)
                                        Text('Duration: ${(b.durationMs! / 3600000).toStringAsFixed(1)} h'),
                                      if (b.sizeBytes != null)
                                        Text('Size: ${(b.sizeBytes! / (1024 * 1024)).toStringAsFixed(1)} MB'),
                                      if (b.updatedAt != null) Text('Updated: ${b.updatedAt}'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),

                            // Listening progress (server + live)
                            _ListeningProgress(
                              playback: playbackRepo,
                              book: b,
                              serverProgressFuture: _serverProgressFut!,
                            ),

                            const SizedBox(height: 12),

                            if (b.description != null && b.description!.isNotEmpty) ...[
                              Text('Description', style: Theme.of(context).textTheme.titleMedium),
                              const SizedBox(height: 8),
                              Text(b.description!),
                            ],
                            const SizedBox(height: 16),

                            // Inline download progress for this book
                            StreamBuilder<TaskUpdate>(
                              stream: downloadsRepo.progressStream(),
                              builder: (_, snap) {
                                if (!snap.hasData) return const SizedBox.shrink();
                                final up = snap.data!;
                                final metaStr = up.task.metaData ?? '';
                                final isThisBook = metaStr.contains(b.id);
                                if (!isThisBook) return const SizedBox.shrink();

                                double? progressValue;
                                String statusText = 'running';

                                if (up is TaskProgressUpdate) {
                                  progressValue = up.progress; // 0..1
                                } else if (up is TaskStatusUpdate) {
                                  statusText = up.status.name;
                                  progressValue = null; // indeterminate
                                }

                                return Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const SizedBox(height: 8),
                                    LinearProgressIndicator(value: progressValue),
                                    const SizedBox(height: 4),
                                    Text(
                                      progressValue != null
                                          ? 'Download: $statusText • ${(progressValue * 100).toStringAsFixed(0)}%'
                                          : 'Download: $statusText',
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // Sticky bottom action bar (moved up so mini-player can show)
                    SafeArea(
                      top: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: StreamBuilder<NowPlaying?>(
                                stream: playbackRepo.nowPlayingStream,
                                initialData: playbackRepo.nowPlaying,
                                builder: (_, npSnap) {
                                  final np = npSnap.data;
                                  final isThis = np?.libraryItemId == b.id;

                                  return StreamBuilder<ProcessingState>(
                                    stream: playbackRepo.processingStateStream,
                                    initialData: playbackRepo.player.processingState,
                                    builder: (_, procSnap) {
                                      final proc = procSnap.data ?? ProcessingState.idle;

                                      return StreamBuilder<bool>(
                                        stream: playbackRepo.playingStream,
                                        initialData: playbackRepo.player.playing,
                                        builder: (_, playSnap) {
                                          final isPlaying = playSnap.data ?? false;

                                          // Decide label + state:
                                          final bool isBuffering = isThis &&
                                              (proc == ProcessingState.loading ||
                                                  proc == ProcessingState.buffering);

                                          final String label =
                                          isThis && isPlaying ? 'Stop'
                                              : isBuffering ? 'Buffering…'
                                              : 'Play';

                                          final bool disabled = isBuffering;

                                          return FilledButton.icon(
                                            onPressed: disabled
                                                ? null
                                                : () async {
                                              if (isThis && isPlaying) {
                                                await playbackRepo.stop();
                                              } else {
                                                await playbackRepo.playItem(b.id);
                                                if (context.mounted) {
                                                  _openFullPlayer(playbackRepo);
                                                }
                                              }
                                            },
                                            icon: Icon(
                                              isThis && isPlaying
                                                  ? Icons.stop
                                                  : Icons.play_arrow,
                                            ),
                                            label: Text(label),
                                          );
                                        },
                                      );
                                    },
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  await downloadsRepo.enqueueItemDownloads(b.id);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Added to download queue')),
                                    );
                                  }
                                },
                                icon: const Icon(Icons.download),
                                label: const Text('Download'),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),

          // Mini-player overlay on this page too
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: MiniPlayer(playback: _playbackRepo!),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------- Widgets ----------

class _ListeningProgress extends StatelessWidget {
  const _ListeningProgress({
    required this.playback,
    required this.book,
    required this.serverProgressFuture,
  });

  final PlaybackRepository playback;
  final Book book;
  final Future<double?> serverProgressFuture;

  @override
  Widget build(BuildContext context) {
    final isThis = playback.nowPlaying?.libraryItemId == book.id;

    // If playing this book now, use live position/duration
    if (isThis) {
      return StreamBuilder<Duration?>(
        stream: playback.durationStream,
        initialData: playback.player.duration,
        builder: (_, dSnap) {
          final total = dSnap.data ?? Duration.zero;
          return StreamBuilder<Duration>(
            stream: playback.positionStream,
            initialData: playback.player.position,
            builder: (_, pSnap) {
              final pos = pSnap.data ?? Duration.zero;
              final v = (total.inMilliseconds > 0)
                  ? pos.inMilliseconds / total.inMilliseconds
                  : 0.0;
              return _progressTile(
                context,
                value: v,
                left: _fmt(pos),
                right: total == Duration.zero ? '' : '-${_fmt(total - pos)}',
              );
            },
          );
        },
      );
    }

    // Otherwise, show server-stored progress for this book
    return FutureBuilder<double?>(
      future: serverProgressFuture,
      builder: (_, snap) {
        final sec = snap.data ?? 0.0;
        final durMs = book.durationMs ?? 0;
        final totalSec = durMs / 1000.0;
        final v = (totalSec > 0) ? (sec / totalSec).clamp(0.0, 1.0) : 0.0;
        return _progressTile(
          context,
          value: v,
          left: _fmt(Duration(milliseconds: (sec * 1000).round())),
          right: (totalSec > 0)
              ? '-${_fmt(Duration(milliseconds: (totalSec * 1000 - sec * 1000).round()))}'
              : '',
        );
      },
    );
  }

  Widget _progressTile(BuildContext context,
      {required double value, required String left, required String right}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Listening progress',
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 6),
        LinearProgressIndicator(value: value),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(left, style: Theme.of(context).textTheme.labelLarge),
            Text(right, style: Theme.of(context).textTheme.labelLarge),
          ],
        ),
      ],
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }
}
