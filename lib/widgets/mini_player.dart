import 'package:flutter/material.dart';

import '../core/playback_repository.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:io';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.height = 72});

  final double height;

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: cs.shadow.withOpacity(0.15),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () async {
              await FullPlayerPage.openOnce(context);
            },
            child: SizedBox(
              height: height,
              child: StreamBuilder<NowPlaying?>(
                stream: playback.nowPlayingStream,
                initialData: playback.nowPlaying,
                builder: (context, snap) {
                  final np = snap.data;
                  if (np == null) {
                    // Nothing playing — keep a slim placeholder so layout is stable
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              Icons.menu_book_outlined,
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              'Nothing playing',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
                    child: Row(
                      children: [
                        // Enhanced cover with Hero
                        Hero(
                          tag: 'mini-cover-${np.libraryItemId}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: _MiniCover(url: np.coverUrl, size: height - 20),
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Title/author + progress bar with enhanced layout
                        Expanded(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                np.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (np.author != null && np.author!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(
                                  np.author!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ],
                              const SizedBox(height: 6),
                              // Enhanced progress bar
                              StreamBuilder<Duration?>(
                                stream: playback.durationStream,
                                initialData: playback.player.duration,
                                builder: (_, durSnap) {
                                  final total = durSnap.data ?? Duration.zero;
                                  return StreamBuilder<Duration>(
                                    stream: playback.positionStream,
                                    initialData: playback.player.position,
                                    builder: (_, posSnap) {
                                      final pos = posSnap.data ?? Duration.zero;
                                      final value = (total.inMilliseconds > 0)
                                          ? (pos.inMilliseconds / total.inMilliseconds)
                                          : 0.0;
                                      return LinearProgressIndicator(
                                        value: value,
                                        backgroundColor: cs.surfaceContainerHighest,
                                        valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                                        minHeight: 3,
                                      );
                                    },
                                  );
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),

                        // Controls: back 15s, play/pause, forward 30s
                        StreamBuilder<bool>(
                          stream: playback.playingStream,
                          initialData: playback.player.playing,
                          builder: (_, playSnap) {
                            final playing = playSnap.data ?? false;
                            ColorScheme cs2 = cs;
                            Widget squareBtn(IconData icon, VoidCallback onTap) {
                              return Material(
                                color: cs2.surfaceContainerHighest,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                child: InkWell(
                                  customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  onTap: onTap,
                                  child: const SizedBox(width: 40, height: 40, child: Icon(Icons.abc, size: 22)),
                                ),
                              );
                            }
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Back 15s (squarish)
                                Material(
                                  color: cs.surfaceContainerHighest,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: InkWell(
                                    customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    onTap: () => ServicesScope.of(context).services.playback.nudgeSeconds(-15),
                                    child: const SizedBox(width: 40, height: 40, child: Icon(Icons.replay_10_rounded, size: 22)),
                                  ),
                                ),
                                const SizedBox(width: 10),
                                // Play/Pause (round when play)
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                                  child: playing
                                      ? Material(
                                          key: const ValueKey('pause'),
                                          color: cs.primary,
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                          child: InkWell(
                                            customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                            onTap: () async { await playback.pause(); },
                                            child: SizedBox(
                                              width: 44,
                                              height: 44,
                                              child: Icon(Icons.pause_rounded, color: cs.onPrimary),
                                            ),
                                          ),
                                        )
                                      : Material(
                                          key: const ValueKey('play'),
                                          color: cs.primary,
                                          shape: const CircleBorder(),
                                          child: InkWell(
                                            customBorder: const CircleBorder(),
                                            onTap: () async { await playback.resume(); },
                                            child: SizedBox(
                                              width: 48,
                                              height: 48,
                                              child: Icon(Icons.play_arrow_rounded, color: cs.onPrimary),
                                            ),
                                          ),
                                        ),
                                ),
                                const SizedBox(width: 10),
                                // Forward 30s (squarish)
                                Material(
                                  color: cs.surfaceContainerHighest,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                  child: InkWell(
                                    customBorder: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    onTap: () => ServicesScope.of(context).services.playback.nudgeSeconds(30),
                                    child: const SizedBox(width: 40, height: 40, child: Icon(Icons.forward_30_rounded, size: 22)),
                                  ),
                                ),
                              ],
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
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
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
