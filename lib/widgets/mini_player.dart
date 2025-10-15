import 'package:flutter/material.dart';

import '../core/playback_repository.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';
import 'audio_waveform.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.height = 60});

  final double height;

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;

    // YouTube Music style: full-width, flat, no rounded corners
    // Use lighter surface to avoid being too dark with tinted surfaces
    return Material(
      color: cs.surface,
      elevation: 2,
      child: InkWell(
        onTap: () async {
          await FullPlayerPage.openOnce(context);
        },
        child: Container(
          height: height,
          decoration: BoxDecoration(
            border: Border(
              top: BorderSide(
                color: cs.outlineVariant.withOpacity(0.5),
                width: 1,
              ),
            ),
          ),
          child: StreamBuilder<NowPlaying?>(
            stream: playback.nowPlayingStream,
            initialData: playback.nowPlaying,
            builder: (context, snap) {
              final np = snap.data;
              // Return empty when no content - parent AnimatedSize will collapse this
              if (np == null) {
                return const SizedBox.shrink();
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    // Album art with Hero (YouTube Music style - square, slightly rounded)
                    Hero(
                      tag: 'mini-cover-${np.libraryItemId}',
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: _MiniCover(url: np.coverUrl, size: height - 16),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Title/author (YouTube Music style - no progress bar in mini)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            np.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (np.author != null && np.author!.isNotEmpty)
                            Text(
                              np.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Waveform indicator (only visible when playing)
                    StreamBuilder<bool>(
                      stream: playback.playingStream,
                      initialData: playback.player.playing,
                      builder: (_, playSnap) {
                        final playing = playSnap.data ?? false;
                        return AnimatedSize(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                          child: playing
                              ? Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: MiniAudioWaveform(
                                    isPlaying: playing,
                                    color: cs.primary,
                                  ),
                                )
                              : const SizedBox.shrink(),
                        );
                      },
                    ),

                    // Play/Pause button only (YouTube Music style)
                    StreamBuilder<bool>(
                      stream: playback.playingStream,
                      initialData: playback.player.playing,
                      builder: (_, playSnap) {
                        final playing = playSnap.data ?? false;
                        return IconButton(
                          onPressed: () async {
                            if (playing) {
                              await playback.pause();
                            } else {
                              // Try to resume first, but if that fails (no current item), 
                              // warm load the last item and play it
                              bool success = await playback.resume();
                              if (!success) {
                                try {
                                  await playback.warmLoadLastItem(playAfterLoad: true);
                                  success = true; // Consider warm load a success
                                } catch (e) {
                                  success = false;
                                }
                              }
                              
                              if (!success && context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Cannot play: server unavailable and sync progress is required'),
                                    duration: Duration(seconds: 4),
                                  ),
                                );
                              } else if (success && context.mounted) {
                                // Open the full player page when resuming, like the book detail page does
                                await FullPlayerPage.openOnce(context);
                              }
                            }
                          },
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                            size: 28,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            foregroundColor: cs.onSurface,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _MiniCover extends StatelessWidget {
  const _MiniCover({required this.url, required this.size});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // YouTube Music style: subtle rounded corners (4px)
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Icon(
        Icons.menu_book_outlined,
        color: cs.onSurfaceVariant,
        size: size * 0.45,
      ),
    );

    final src = url ?? '';
    if (src.startsWith('file://')) {
      final file = File(Uri.parse(src).toFilePath());
      if (file.existsSync()) {
        return Image.file(file, width: size, height: size, fit: BoxFit.cover);
      }
      return placeholder;
    }

    if (src.isEmpty) return placeholder;

    return CachedNetworkImage(
      imageUrl: src,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );
  }
}
