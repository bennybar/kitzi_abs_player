import 'package:flutter/material.dart';

import '../core/playback_repository.dart';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, this.height = 96});

  final double height;

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.15),
            blurRadius: 20,
            offset: const Offset(0, -4),
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
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: cs.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.menu_book_outlined,
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                        const SizedBox(width: 16),
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
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
                  child: Row(
                    children: [
                      // Enhanced cover with better border radius
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: cs.shadow.withOpacity(0.1),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: Image.network(
                            np.coverUrl ?? '',
                            width: height - 32,
                            height: height - 32,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                              width: height - 32,
                              height: height - 32,
                              decoration: BoxDecoration(
                                color: cs.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Icon(
                                Icons.menu_book_outlined,
                                color: cs.onSurfaceVariant,
                                size: 32,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),

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
                              const SizedBox(height: 4),
                              Text(
                                np.author!,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ],
                            const SizedBox(height: 8),
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
                                    return ClipRRect(
                                      borderRadius: BorderRadius.circular(2),
                                      child: LinearProgressIndicator(
                                        value: value,
                                        backgroundColor: cs.surfaceContainerHighest,
                                        valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
                                        minHeight: 4,
                                      ),
                                    );
                                  },
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),

                      // Enhanced play/pause button
                      StreamBuilder<bool>(
                        stream: playback.playingStream,
                        initialData: playback.player.playing,
                        builder: (_, playSnap) {
                          final playing = playSnap.data ?? false;
                          return Container(
                            decoration: BoxDecoration(
                              color: cs.primary,
                              borderRadius: BorderRadius.circular(16),
                              boxShadow: [
                                BoxShadow(
                                  color: cs.primary.withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: IconButton.filled(
                              onPressed: () async {
                                if (playing) {
                                  await playback.pause();
                                } else {
                                  await playback.resume();
                                }
                              },
                              icon: Icon(
                                playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                color: cs.onPrimary,
                              ),
                              style: IconButton.styleFrom(
                                backgroundColor: cs.primary,
                                foregroundColor: cs.onPrimary,
                                padding: const EdgeInsets.all(12),
                              ),
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
      ),
    );
  }
}
