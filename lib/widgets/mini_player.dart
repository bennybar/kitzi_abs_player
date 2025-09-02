import 'package:flutter/material.dart';

import '../core/playback_repository.dart';
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
                          tag: 'cover-${np.libraryItemId}',
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.network(
                              np.coverUrl ?? '',
                              width: height - 20,
                              height: height - 20,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                width: height - 20,
                                height: height - 20,
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Icon(
                                  Icons.menu_book_outlined,
                                  color: cs.onSurfaceVariant,
                                  size: 28,
                                ),
                              ),
                            ),
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
                            return Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: 'Back 15s',
                                  icon: const Icon(Icons.replay_10_rounded),
                                  onPressed: () => ServicesScope.of(context).services.playback.nudgeSeconds(-15),
                                ),
                                AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  transitionBuilder: (child, anim) => FadeTransition(opacity: anim, child: child),
                                  child: IconButton.filled(
                                    key: ValueKey(playing),
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
                                      padding: const EdgeInsets.all(8),
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Forward 30s',
                                  icon: const Icon(Icons.forward_30_rounded),
                                  onPressed: () => ServicesScope.of(context).services.playback.nudgeSeconds(30),
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
