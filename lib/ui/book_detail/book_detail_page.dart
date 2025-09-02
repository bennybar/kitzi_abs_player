import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';

import '../../core/books_repository.dart';
import '../../models/book.dart';
import '../../core/downloads_repository.dart';
import '../../core/playback_repository.dart';
import '../../widgets/mini_player.dart';
import '../../widgets/download_button.dart';
import '../../main.dart'; // ServicesScope
import '../../ui/player/full_player_page.dart'; // Added import for FullPlayerPage

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
              // Debug: Inspect raw description to understand formatting
              // and confirm whether it is JSON we can parse
              try {
                final raw = b.description ?? '';
                final preview = raw.length > 500 ? raw.substring(0, 500) + '…' : raw;
                debugPrint('[DETAILS] Book id=${b.id} title="${b.title}"');
                debugPrint('[DETAILS] Author=${b.author} durationMs=${b.durationMs} sizeBytes=${b.sizeBytes}');
                debugPrint('[DETAILS] description.length=${raw.length}');
                debugPrint('[DETAILS] description.preview=${preview.replaceAll('\n', ' ')}');
              } catch (_) {}

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

              // Layout: header and actions stay static; description area scrolls independently.
              return Padding(
                padding: const EdgeInsets.only(bottom: 112), // room for mini player
                child: Column(
                  children: [
                    Padding(
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
                                if ((b.narrators ?? const []).isNotEmpty)
                                  _MetaLine(
                                    icon: Icons.record_voice_over_rounded,
                                    label: 'Narrators',
                                    value: b.narrators!.join(', '),
                                  ),
                                if (b.publishYear != null)
                                  _MetaLine(
                                    icon: Icons.calendar_today_rounded,
                                    label: 'Publish Year',
                                    value: b.publishYear.toString(),
                                  ),
                                if ((b.publisher ?? '').isNotEmpty)
                                  _MetaLine(
                                    icon: Icons.business_rounded,
                                    label: 'Publisher',
                                    value: b.publisher!,
                                  ),
                                if ((b.genres ?? const []).isNotEmpty)
                                  _MetaLine(
                                    icon: Icons.category_rounded,
                                    label: 'Genres',
                                    value: b.genres!.join(' / '),
                                  ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    _InfoChip(icon: Icons.schedule, label: fmtDuration()),
                                    _InfoChip(icon: Icons.save_alt, label: fmtSize()),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: _ListeningProgress(
                        playback: playbackRepo,
                        book: b,
                        serverProgressFuture: _serverProgressFut!,
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: () async {
                                await playbackRepo.playItem(b.id);
                                if (!context.mounted) return;
                                await FullPlayerPage.openOnce(context);
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
      debugPrint('[DETAILS] Attempting jsonDecode for book=${book.id}');
      parsed = jsonDecode(raw);
      debugPrint('[DETAILS] jsonDecode success: type=${parsed.runtimeType}');
    } catch (e) {
      debugPrint('[DETAILS] jsonDecode failed: $e');
    }

    if (parsed is Map<String, dynamic>) {
      final m = parsed;
      debugPrint('[DETAILS] Parsed Map keys=${m.keys.toList()}');

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
        Text(book.description ?? '', style: text.bodyMedium),
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
