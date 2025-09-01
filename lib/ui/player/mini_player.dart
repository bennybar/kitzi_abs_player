import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';

import '../../core/playback_repository.dart';
import 'full_player_sheet.dart';

class MiniPlayer extends StatelessWidget {
  const MiniPlayer({super.key, required this.playback});
  final PlaybackRepository playback;

  void _openFull(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FullPlayerSheet(playback: playback),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (_, snap) {
        final np = snap.data;
        if (np == null) return const SizedBox.shrink();

        return Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Material(
            color: cs.surface,
            elevation: 3,
            borderRadius: BorderRadius.circular(16),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _openFull(context),
              child: SizedBox(
                height: 68,
                child: Row(
                  children: [
                    const SizedBox(width: 8),
                    // cover thumb
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.network(
                        np.coverUrl ?? '',
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => Container(
                          width: 52,
                          height: 52,
                          color: cs.surfaceContainerHighest,
                          child: const Icon(Icons.menu_book_outlined),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // title + chapter
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
                          StreamBuilder<Duration?>(
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
                                      ? pos.inMilliseconds /
                                      total.inMilliseconds
                                      : 0.0;
                                  return LinearProgressIndicator(
                                    value: v.clamp(0.0, 1.0),
                                    minHeight: 4,
                                  );
                                },
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    // controls
                    IconButton(
                      tooltip: 'Back 30s',
                      icon: const Icon(Icons.replay_30),
                      onPressed: () => playback.nudgeSeconds(-30),
                    ),
                    StreamBuilder<PlayerState>(
                      stream: playback.playerStateStream,
                      initialData: playback.player.playerState,
                      builder: (_, s) {
                        final playing = s.data?.playing ?? false;
                        return IconButton.filled(
                          tooltip: playing ? 'Pause' : 'Play',
                          onPressed: playing ? playback.pause : playback.resume,
                          icon: Icon(
                            playing ? Icons.pause : Icons.play_arrow,
                          ),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: 'Forward 30s',
                      icon: const Icon(Icons.forward_30),
                      onPressed: () => playback.nudgeSeconds(30),
                    ),
                    const SizedBox(width: 8),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
