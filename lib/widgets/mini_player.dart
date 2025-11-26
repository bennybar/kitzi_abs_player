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

    // iOS: floating rounded Material card
    if (Platform.isIOS) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: BorderSide(
              color: cs.outline.withOpacity(0.1),
              width: 0.5,
            ),
          ),
          child: _buildContent(context, playback, cs, showTopBorder: false),
        ),
      );
    }

    // Others: full-width Material surface with top divider
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(
            color: cs.outlineVariant.withOpacity(0.3),
            width: 0.5,
          ),
        ),
      ),
      child: _buildContent(context, playback, cs, showTopBorder: true),
    );
  }

  Widget _buildContent(BuildContext context, PlaybackRepository playback, ColorScheme cs, {bool showTopBorder = true}) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await FullPlayerPage.openOnce(context);
        },
        child: Container(
          height: height,
          decoration: showTopBorder
              ? BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: cs.outlineVariant.withOpacity(0.3),
                      width: 0.5,
                    ),
                  ),
                )
              : null,
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

                      // Title/author with progress (YouTube Music style)
                      Expanded(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
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
                            Row(
                              children: [
                                if (np.author != null && np.author!.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      np.author!,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                                  ),
                                StreamBuilder<Duration>(
                                  stream: playback.positionStream,
                                  initialData: playback.player.position,
                                  builder: (_, posSnap) {
                                    // Use total book progress instead of current track
                                    final globalTotal = playback.totalBookDuration;
                                    final globalPos = playback.globalBookPosition;
                                    
                                    // Prefer global book progress if available, otherwise use current track
                                    final position = globalPos ?? (posSnap.data ?? Duration.zero);
                                    final duration = globalTotal;
                                    
                                    if (duration == null || duration == Duration.zero) {
                                      // Fallback to current track duration if global not available
                                      final trackDuration = playback.player.duration;
                                      if (trackDuration == null || trackDuration == Duration.zero) {
                                        return const SizedBox.shrink();
                                      }
                                      final posStr = _formatTime(posSnap.data ?? Duration.zero);
                                      final durStr = _formatTime(trackDuration);
                                      return Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          if (np.author != null && np.author!.isNotEmpty)
                                            const SizedBox(width: 8),
                                          Text(
                                            '$posStr / $durStr',
                                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ],
                                      );
                                    }
                                    
                                    final posStr = _formatTime(position);
                                    final durStr = _formatTime(duration);
                                    
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (np.author != null && np.author!.isNotEmpty)
                                          const SizedBox(width: 8),
                                        Text(
                                          '$posStr / $durStr',
                                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 12),

                      // 10 seconds rewind button
                      IconButton(
                        onPressed: () async {
                          await playback.nudgeSeconds(-10);
                        },
                        icon: const Icon(Icons.replay_10),
                        tooltip: 'Rewind 10 seconds',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          foregroundColor: cs.onSurface,
                        ),
                      ),

                      // Play/Pause button only (YouTube Music style)
                      StreamBuilder<bool>(
                        stream: playback.playingStream,
                        initialData: playback.player.playing,
                        builder: (_, playSnap) {
                          final playing = playSnap.data ?? false;
                          // Ensure we have a valid nowPlaying item and it's actually playing
                          final hasValidNowPlaying = np != null && playing;
                          return IconButton(
                            onPressed: () async {
                              // Button pressed
                              if (hasValidNowPlaying) {
                                // Pausing playback
                                await playback.pause();
                                // Don't open full player on pause
                              } else {
                                // Attempting to resume/play
                                // Try to resume first, but if that fails (no current item), 
                                // warm load the last item and play it
                                bool success = await playback.resume(context: context);
                                // Resume result
                                if (!success) {
                                  try {
                                    // Resume failed, trying warmLoadLastItem
                                    await playback.warmLoadLastItem(playAfterLoad: true);
                                    success = true; // Consider warm load a success
                                    // WarmLoadLastItem succeeded
                                  } catch (e) {
                                    // WarmLoadLastItem failed
                                    success = false;
                                  }
                                }
                                
                                if (!success && context.mounted) {
                                  // Both resume and warmLoad failed, showing error
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('Cannot play: server unavailable and sync progress is required'),
                                      duration: Duration(seconds: 4),
                                    ),
                                  );
                                } else if (success && context.mounted) {
                                  // Success, opening full player
                                  // Open the full player page when resuming, like the book detail page does
                                  await FullPlayerPage.openOnce(context);
                                }
                              }
                            },
                            icon: Icon(
                              hasValidNowPlaying ? Icons.pause : Icons.play_arrow,
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

String _formatTime(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);
  
  if (hours > 0) {
    return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  } else {
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
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
