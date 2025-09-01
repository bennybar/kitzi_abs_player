import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../../widgets/mini_player.dart';
import '../../widgets/download_button.dart';
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
                      'Failed to load book.',
                      style: TextStyle(color: cs.error),
                    ),
                  ),
                );
              }

              final b = snap.data!;

              String fmtDuration() {
                if (b.durationMs == null || b.durationMs == 0) return 'Unknown';
                final d = Duration(milliseconds: b.durationMs!);
                final h = d.inHours;
                final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
                return h > 0 ? '$h h $m m' : '$m m';
              }

              String fmtSize() {
                if (b.sizeBytes == null || b.sizeBytes == 0) return '—';
                final mb = (b.sizeBytes! / (1024 * 1024));
                return '${mb.toStringAsFixed(1)} MB';
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 112), // room for mini player
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Row(
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
                                  color: cs.surfaceContainerHighest,
                                  child: const Icon(Icons.menu_book_outlined, size: 48),
                                ),
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(b.title, style: text.titleLarge, maxLines: 2, overflow: TextOverflow.ellipsis),
                                  const SizedBox(height: 6),
                                  Text(b.author ?? 'Unknown author', style: text.titleMedium),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: [
                                      _InfoChip(icon: Icons.schedule, label: fmtDuration()),
                                      _InfoChip(icon: Icons.save_alt, label: fmtSize()),
                                      if (b.updatedAt != null)
                                        _InfoChip(icon: Icons.update, label: b.updatedAt!.toLocal().toString().split('.').first),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _ListeningProgress(
                          playback: playbackRepo,
                          book: b,
                          serverProgressFuture: _serverProgressFut!,
                        ),
                      ),
                    ),
                    if (b.description != null && b.description!.isNotEmpty)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Description', style: text.titleMedium),
                              const SizedBox(height: 8),
                              Text(b.description!, style: text.bodyMedium),
                            ],
                          ),
                        ),
                      ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                        child: Row(
                          children: [
                            Expanded(
                              child: FilledButton.icon(
                                onPressed: () async {
                                  await playbackRepo.playItem(b.id);
                                  if (!context.mounted) return;
                                  Navigator.of(context).pushNamed('/player');
                                },
                                icon: const Icon(Icons.play_arrow),
                                label: const Text('Play'),
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
                    ),
                    // Optional inline per-book progress strip (kept)
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        child: StreamBuilder<TaskUpdate>(
                          stream: downloadsRepo.progressStream(),
                          builder: (_, snapUp) {
                            if (!snapUp.hasData) return const SizedBox.shrink();
                            final up = snapUp.data!;
                            final metaStr = up.task.metaData ?? '';
                            final isThisBook = metaStr.contains(b.id);
                            if (!isThisBook) return const SizedBox.shrink();

                            double? progressValue;
                            String statusText = 'running';

                            if (up is TaskProgressUpdate) {
                              progressValue = up.progress;
                            } else if (up is TaskStatusUpdate) {
                              statusText = up.status.name;
                              progressValue = null; // indeterminate
                            }

                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
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
              child: MiniPlayer(height: 112),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
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
  }
}

// ---------- Listening Progress ----------
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

    return FutureBuilder<double?>(
      future: serverProgressFuture,
      builder: (_, snap) {
        final sec = (snap.data ?? 0.0);
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
        Text('Listening progress', style: Theme.of(context).textTheme.titleMedium),
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
