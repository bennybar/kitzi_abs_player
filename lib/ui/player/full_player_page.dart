// lib/ui/player/full_player_page.dart
import 'package:flutter/material.dart';

import '../../core/playback_repository.dart';
import '../../main.dart'; // ServicesScope

class FullPlayerPage extends StatelessWidget {
  const FullPlayerPage({super.key});

  // Prevent duplicate openings of the FullPlayerPage within the same session.
  static bool _isOpen = false;
  static Future<void> openOnce(BuildContext context) async {
    if (_isOpen) return;
    _isOpen = true;
    try {
      await Navigator.of(context).push(PageRouteBuilder(
        pageBuilder: (_, __, ___) => const FullPlayerPage(),
        transitionsBuilder: (_, anim, __, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(curved),
              child: child,
            ),
          );
        },
      ));
    } finally {
      _isOpen = false;
    }
  }

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

    // Determine the current chapter index once when opening
    final pos = playback.player.position;
    int currentIdx = 0;
    for (int i = 0; i < chapters.length; i++) {
      if (pos >= chapters[i].start) currentIdx = i; else break;
    }

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 16),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.list_alt_rounded,
                      color: Theme.of(ctx).colorScheme.primary,
                    ),
                    const SizedBox(width: 12),
                    Text(
                      'Chapters',
                      style: Theme.of(ctx).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: StreamBuilder<Duration>(
                  stream: playback.positionStream,
                  initialData: playback.player.position,
                  builder: (_, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    int liveIdx = 0;
                    for (int i = 0; i < chapters.length; i++) {
                      if (pos >= chapters[i].start) liveIdx = i; else break;
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      itemCount: chapters.length,
                      separatorBuilder: (_, __) => Divider(
                        height: 1,
                        color: Theme.of(ctx).colorScheme.outline.withOpacity(0.2),
                      ),
                      itemBuilder: (_, i) {
                        final c = chapters[i];
                        final isCurrent = i == liveIdx;
                        return ListTile(
                          dense: false,
                          contentPadding: const EdgeInsets.symmetric(vertical: 8),
                          title: Text(
                            c.title.isEmpty ? 'Chapter ${i + 1}' : c.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.bodyLarge?.copyWith(
                              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
                              color: isCurrent
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                          subtitle: Text(
                            _fmt(c.start),
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              color: isCurrent
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: isCurrent
                                  ? Theme.of(ctx).colorScheme.primary
                                  : Theme.of(ctx).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Center(
                              child: Text(
                                '${i + 1}',
                                style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                                  color: isCurrent
                                      ? Theme.of(ctx).colorScheme.onPrimary
                                      : Theme.of(ctx).colorScheme.onPrimaryContainer,
                                  fontWeight: isCurrent ? FontWeight.w800 : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          trailing: isCurrent
                              ? Icon(Icons.play_arrow_rounded,
                                  color: Theme.of(ctx).colorScheme.primary)
                              : null,
                          onTap: () async {
                            Navigator.of(ctx).pop();
                            await playback.seek(c.start, reportNow: true);
                          },
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
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
      body: SafeArea(
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
                // Custom App Bar
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                        style: IconButton.styleFrom(
                          backgroundColor: cs.surfaceContainerHighest,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        'Now Playing',
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: 'Chapters',
                        icon: Icon(
                          Icons.list_alt_rounded,
                          color: cs.onSurfaceVariant,
                        ),
                        onPressed: () async {
                          final npNow = playback.nowPlaying;
                          if (npNow != null) {
                            await _showChaptersSheet(context, playback, npNow);
                          }
                        },
                      ),
                      PopupMenuButton<double>(
                        tooltip: 'Playback speed',
                        icon: Icon(
                          Icons.speed_rounded,
                          color: cs.onSurfaceVariant,
                        ),
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
                ),

                // ARTWORK + TITLE
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                    child: Column(
                      children: [
                        // Cover with enhanced shadow and border
                        Hero(
                          tag: 'mini-cover-${np.libraryItemId}',
                          child: Container(
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(24),
                              boxShadow: [
                                BoxShadow(
                                  color: cs.shadow.withOpacity(0.25),
                                  blurRadius: 18,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(24),
                              child: AspectRatio(
                                aspectRatio: 1,
                                child: Image.network(
                                  np.coverUrl ?? '',
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => Container(
                                    color: cs.surfaceContainerHighest,
                                    child: Icon(
                                      Icons.menu_book_outlined,
                                      size: 88,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 32),

                        // Title / author with enhanced typography
                        Text(
                          np.title,
                          textAlign: TextAlign.center,
                          style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            height: 1.2,
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (np.author != null && np.author!.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            np.author!,
                            textAlign: TextAlign.center,
                            style: text.titleMedium?.copyWith(
                              color: cs.onSurfaceVariant,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),

                // POSITION + SLIDER
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
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
                              // Enhanced slider with custom theme
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 6,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 12,
                                    elevation: 4,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
                                  activeTrackColor: cs.primary,
                                  inactiveTrackColor: cs.surfaceContainerHighest,
                                  thumbColor: cs.primary,
                                  overlayColor: cs.primary.withOpacity(0.2),
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
                              // Time indicators
                              Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 4),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      _fmt(pos),
                                      style: text.labelLarge?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    Text(
                                      total == Duration.zero ? '' : '-${_fmt(total - pos)}',
                                      style: text.labelLarge?.copyWith(
                                        color: cs.onSurfaceVariant,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        },
                      );
                    },
                  ),
                ),

                const SizedBox(height: 16),

                // CONTROLS + CHAPTERS
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 32),
                  child: Column(
                    children: [
                      // Large transport controls (Material 3)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          _RoundIconButton(
                            tooltip: 'Previous track',
                            icon: Icons.skip_previous_rounded,
                            onTap: () async {
                              if (playback.hasPrev) {
                                await playback.prevTrack();
                              }
                            },
                          ),
                          _RoundIconButton(
                            tooltip: 'Back 30s',
                            icon: Icons.replay_30_rounded,
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
                                size: 96,
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
                            icon: Icons.forward_30_rounded,
                            onTap: () => playback.nudgeSeconds(30),
                          ),
                          _RoundIconButton(
                            tooltip: 'Next track',
                            icon: Icons.skip_next_rounded,
                            onTap: () async {
                              if (playback.hasNext) {
                                await playback.nextTrack();
                              }
                            },
                          ),
                        ],
                      ),

                      const SizedBox(height: 24),

                      // Chapters + Queue controls with enhanced design
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.list_alt_rounded),
                              label: const Text('Chapters'),
                              onPressed: () => _showChaptersSheet(context, playback, np),
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: FilledButton.tonalIcon(
                              icon: const Icon(Icons.queue_music_rounded),
                              label: const Text('Queue'),
                              onPressed: () {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(content: Text('Queue view not implemented yet')),
                                );
                              },
                              style: FilledButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(16),
                                ),
                              ),
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

/// Enhanced circular MD3 icon button used for transport controls
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

    final bg = isPrimary ? cs.primary : cs.surfaceContainerHighest;
    final fg = isPrimary ? cs.onPrimary : cs.onSurface;

    final button = Material(
      color: bg,
      shape: const CircleBorder(),
      elevation: isPrimary ? 4 : 0,
      shadowColor: isPrimary ? cs.primary.withOpacity(0.3) : Colors.transparent,
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
