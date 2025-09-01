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

    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 6,
      child: InkWell(
        onTap: () {
          // Push the full player directly (no named route required)
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const FullPlayerPage()),
          );
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
                      const Icon(Icons.menu_book_outlined),
                      const SizedBox(width: 12),
                      Text(
                        'Nothing playing',
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                );
              }

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    // Cover
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        np.coverUrl ?? '',
                        width: height - 24,
                        height: height - 24,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: height - 24,
                          height: height - 24,
                          color: Theme.of(context).colorScheme.surfaceVariant,
                          child: const Icon(Icons.menu_book_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),

                    // Title/author + progress bar
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            np.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                          if (np.author != null && np.author!.isNotEmpty)
                            Text(
                              np.author!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          const SizedBox(height: 6),
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
                                      ? (pos.inMilliseconds /
                                      total.inMilliseconds)
                                      : 0.0;
                                  return LinearProgressIndicator(value: value);
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),

                    // Play/Pause button
                    StreamBuilder<bool>(
                      stream: playback.playingStream,
                      initialData: playback.player.playing,
                      builder: (_, playSnap) {
                        final playing = playSnap.data ?? false;
                        return IconButton.filled(
                          onPressed: () async {
                            if (playing) {
                              await playback.pause();
                            } else {
                              await playback.resume();
                            }
                          },
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
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
