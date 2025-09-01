// lib/ui/player/full_player_page.dart
import 'package:flutter/material.dart';

import '../../core/playback_repository.dart';
import '../../main.dart'; // ServicesScope

class FullPlayerPage extends StatelessWidget {
  const FullPlayerPage({super.key});

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  Future<void> _showChaptersSheet(
      BuildContext context,
      PlaybackRepository playback,
      NowPlaying np,
      ) async {
    final chapters = np.chapters;
    if (chapters.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chapters available')),
      );
      return;
    }

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          itemCount: chapters.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (_, i) {
            final c = chapters[i];
            return ListTile(
              dense: false,
              title: Text(
                c.title.isEmpty ? 'Chapter ${i + 1}' : c.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: Text(_fmt(c.start)),
              leading: CircleAvatar(
                child: Text('${i + 1}'),
              ),
              onTap: () async {
                Navigator.of(ctx).pop();
                await playback.seek(c.start, reportNow: true);
              },
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: AppBar(
        centerTitle: false,
        title: const Text('Now Playing'),
        actions: [
          // Speed selector
          PopupMenuButton<double>(
            tooltip: 'Playback speed',
            icon: const Icon(Icons.speed),
            onSelected: (v) => playback.setSpeed(v),
            itemBuilder: (context) => const [
              PopupMenuItem(value: 0.75, child: Text('0.75×')),
              PopupMenuItem(value: 1.0, child: Text('1.0×')),
              PopupMenuItem(value: 1.25, child: Text('1.25×')),
              PopupMenuItem(value: 1.5, child: Text('1.5×')),
              PopupMenuItem(value: 1.75, child: Text('1.75×')),
              PopupMenuItem(value: 2.0, child: Text('2.0×')),
            ],
          ),
        ],
      ),
      body: SafeArea(
        bottom: false,
        child: StreamBuilder<NowPlaying?>(
          stream: playback.nowPlayingStream,
          initialData: playback.nowPlaying,
          builder: (context, snap) {
            final np = snap.data;
            if (np == null) {
              return const Center(child: Text('Nothing playing'));
            }

            return Column(
              children: [
                // ARTWORK + TITLE
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Column(
                      children: [
                        // Cover
                        AspectRatio(
                          aspectRatio: 1,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.network(
                              np.coverUrl ?? '',
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => Container(
                                color: cs.surfaceVariant,
                                child: const Icon(Icons.menu_book_outlined, size: 88),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // Title / author centered
                        Text(
                          np.title,
                          textAlign: TextAlign.center,
                          style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (np.author != null && np.author!.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            np.author!,
                            textAlign: TextAlign.center,
                            style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // POSITION + SLIDER
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: StreamBuilder<Duration?>(
                    stream: playback.durationStream,
                    initialData: playback.player.duration,
                    builder: (_, durSnap) {
                      final total = durSnap.data ?? Duration.zero;
                      return StreamBuilder<Duration>(
                        stream: playback.positionStream,
                        initialData: playback.player.position,
                        builder: (_, posSnap) {
                          final pos = posSnap.data ?? Duration.zero;
                          final max = total.inMilliseconds.toDouble().clamp(0.0, double.infinity);
                          final value = pos.inMilliseconds.toDouble().clamp(0.0, max);

                          return Column(
                            children: [
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 5,
                                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
                                ),
                                child: Slider(
                                  min: 0.0,
                                  max: max > 0 ? max : 1.0,
                                  value: value,
                                  onChanged: (v) async {
                                    await playback.seek(
                                      Duration(milliseconds: v.round()),
                                      reportNow: false,
                                    );
                                  },
                                  onChangeEnd: (v) async {
                                    await playback.seek(
                                      Duration(milliseconds: v.round()),
                                      reportNow: true,
                                    );
                                  },
                                ),
                              ),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(_fmt(pos), style: text.labelLarge),
                                  Text(
                                    total == Duration.zero ? '' : '-${_fmt(total - pos)}',
                                    style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant),
                                  ),
                                ],
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 8),

                // CONTROLS + CHAPTERS
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
                  child: Column(
                    children: [
                      // Large transport controls (Material 3)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundIconButton(
                            tooltip: 'Back 30s',
                            icon: Icons.replay_30,
                            onTap: () => playback.nudgeSeconds(-30),
                          ),
                          StreamBuilder<bool>(
                            stream: playback.playingStream,
                            initialData: playback.player.playing,
                            builder: (_, playSnap) {
                              final playing = playSnap.data ?? false;
                              return _RoundIconButton(
                                tooltip: playing ? 'Pause' : 'Play',
                                icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                isPrimary: true,
                                size: 88,
                                onTap: () async {
                                  if (playing) {
                                    await playback.pause();
                                  } else {
                                    await playback.resume();
                                  }
                                },
                              );
                            },
                          ),
                          _RoundIconButton(
                            tooltip: 'Forward 30s',
                            icon: Icons.forward_30,
                            onTap: () => playback.nudgeSeconds(30),
                          ),
                        ],
                      ),

                      const SizedBox(height: 12),

                      // Chapters + Queue controls
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.list_alt_rounded),
                              label: const Text('Chapters'),
                              onPressed: () => _showChaptersSheet(context, playback, np),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.queue_music_rounded),
                              label: const Text('Queue'),
                              onPressed: () {
                                // Optional future: open upcoming tracks
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Queue view not implemented yet')),
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Big circular MD3 icon button used for transport controls
class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.isPrimary = false,
    this.size = 64,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isPrimary;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final bg = isPrimary ? cs.primary : cs.surfaceVariant;
    final fg = isPrimary ? cs.onPrimary : cs.onSurface;

    final button = Material(
      color: bg,
      shape: const CircleBorder(),
      elevation: isPrimary ? 2 : 0,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Icon(icon, size: size * 0.48, color: fg),
        ),
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
