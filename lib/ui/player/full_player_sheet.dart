import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/playback_repository.dart';

class FullPlayerSheet extends StatefulWidget {
  const FullPlayerSheet({super.key, required this.playback});
  final PlaybackRepository playback;

  @override
  State<FullPlayerSheet> createState() => _FullPlayerSheetState();
}

class _FullPlayerSheetState extends State<FullPlayerSheet> {
  double _speed = 1.0;
  Timer? _sleepTimer;
  String _sleepLabel = 'Sleep';

  @override
  void initState() {
    super.initState();
    _speed = widget.playback.player.speed;
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pb = widget.playback;

    return DraggableScrollableSheet(
      initialChildSize: 0.92,
      minChildSize: 0.5,
      maxChildSize: 0.96,
      expand: false,
      builder: (ctx, controller) {
        return DecoratedBox(
          decoration: BoxDecoration(
            color: cs.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
            boxShadow: const [BoxShadow(blurRadius: 18, offset: Offset(0, -4))],
          ),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: StreamBuilder<NowPlaying?>(
              stream: pb.nowPlayingStream,
              initialData: pb.nowPlaying,
              builder: (_, snap) {
                final np = snap.data;
                if (np == null) {
                  return const Center(child: Text('Nothing playing'));
                }

                final hasChapters = np.chapters.isNotEmpty;

                return ListView(
                  controller: controller,
                  children: [
                    Center(
                      child: Container(
                        height: 5,
                        width: 48,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: cs.outlineVariant,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),

                    // Cover
                    AspectRatio(
                      aspectRatio: 1,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: CachedNetworkImage(
                          imageUrl: np.coverUrl ?? '',
                          fit: BoxFit.cover,
                          errorWidget: (_, __, ___) => Container(
                            color: cs.surfaceContainerHighest,
                            child: const Center(
                              child: Icon(Icons.menu_book_outlined, size: 72),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Title/author
                    if (np.author != null && np.author!.isNotEmpty)
                      Text(
                        np.author!,
                        textAlign: TextAlign.center,
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    const SizedBox(height: 6),
                    Text(
                      np.title,
                      textAlign: TextAlign.center,
                      style: Theme.of(context)
                          .textTheme
                          .headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 18),

                    // Slider + timecodes
                    StreamBuilder<Duration?>(
                      stream: pb.durationStream,
                      initialData: pb.player.duration,
                      builder: (_, dSnap) {
                        final total = dSnap.data ?? Duration.zero;
                        return StreamBuilder<Duration>(
                          stream: pb.positionStream,
                          initialData: pb.player.position,
                          builder: (_, pSnap) {
                            final pos = pSnap.data ?? Duration.zero;
                            final v = (total.inMilliseconds > 0)
                                ? pos.inMilliseconds / total.inMilliseconds
                                : 0.0;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Slider(
                                  value: v.clamp(0.0, 1.0),
                                  onChanged: (nv) {
                                    final target = Duration(
                                      milliseconds:
                                      (total.inMilliseconds * nv).round(),
                                    );
                                    pb.seek(target, reportNow: false);
                                  },
                                  onChangeEnd: (nv) {
                                    final target = Duration(
                                      milliseconds:
                                      (total.inMilliseconds * nv).round(),
                                    );
                                    pb.seek(target, reportNow: true);
                                  },
                                ),
                                Row(
                                  mainAxisAlignment:
                                  MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(_fmt(pos),
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge),
                                    Text('-${_fmt(total - pos)}',
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelLarge),
                                  ],
                                ),
                              ],
                            );
                          },
                        );
                      },
                    ),

                    const SizedBox(height: 12),

                    // Main controls
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        IconButton(
                          iconSize: 28,
                          icon: const Icon(Icons.skip_previous),
                          onPressed: pb.hasPrev ? pb.prevTrack : null,
                        ),
                        IconButton.filledTonal(
                          iconSize: 28,
                          onPressed: () => pb.nudgeSeconds(-15),
                          icon: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [Icon(Icons.replay), Text('15')],
                          ),
                        ),
                        StreamBuilder<bool>(
                          stream: pb.playingStream,
                          initialData: pb.player.playing,
                          builder: (_, s) {
                            final isPlaying = s.data ?? false;
                            return FilledButton(
                              style: FilledButton.styleFrom(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 28, vertical: 10),
                                  shape: const StadiumBorder()),
                              onPressed: isPlaying ? pb.pause : pb.resume,
                              child: Icon(
                                isPlaying
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                size: 36,
                              ),
                            );
                          },
                        ),
                        IconButton.filledTonal(
                          iconSize: 28,
                          onPressed: () => pb.nudgeSeconds(15),
                          icon: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [Icon(Icons.forward), Text('15')],
                          ),
                        ),
                        IconButton(
                          iconSize: 28,
                          icon: const Icon(Icons.skip_next),
                          onPressed: pb.hasNext ? pb.nextTrack : null,
                        ),
                      ],
                    ),

                    const SizedBox(height: 10),

                    // Chapter controls row
                    if (np.chapters.isNotEmpty)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          TextButton.icon(
                            onPressed: _prevChapter,
                            icon: const Icon(Icons.skip_previous_rounded),
                            label: const Text('Chapter'),
                          ),
                          FilledButton.tonalIcon(
                            onPressed: _showChapters,
                            icon: const Icon(Icons.list),
                            label: const Text('Chapters'),
                          ),
                          TextButton.icon(
                            onPressed: _nextChapter,
                            icon: const Icon(Icons.skip_next_rounded),
                            label: const Text('Chapter'),
                          ),
                        ],
                      ),

                    const SizedBox(height: 12),

                    // Speed / Sleep row
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: [
                        TextButton.icon(
                          onPressed: _pickSpeed,
                          icon: const Icon(Icons.speed),
                          label: Text('${_speed.toStringAsFixed(2)}x'),
                        ),
                        TextButton.icon(
                          onPressed: _pickSleep,
                          icon: const Icon(Icons.nightlight_round),
                          label: Text(_sleepLabel),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  // ------ Speed / Sleep ------
  Future<void> _pickSpeed() async {
    final v = await showModalBottomSheet<double>(
      context: context,
      builder: (_) => _SpeedSheet(current: _speed),
    );
    if (v != null) {
      setState(() => _speed = v);
      await widget.playback.setSpeed(v);
    }
  }

  Future<void> _pickSleep() async {
    final v = await showModalBottomSheet<Duration?>(
      context: context,
      builder: (_) => const _SleepSheet(),
    );
    _sleepTimer?.cancel();
    if (v != null) {
      setState(() => _sleepLabel = '${v.inMinutes} min');
      _sleepTimer = Timer(v, () {
        widget.playback.pause();
        if (mounted) setState(() => _sleepLabel = 'Sleep');
      });
    } else {
      if (mounted) setState(() => _sleepLabel = 'Sleep');
    }
  }

  // ------ Chapters ------
  void _showChapters() {
    final np = widget.playback.nowPlaying;
    if (np == null || np.chapters.isEmpty) return;
    showModalBottomSheet(
      context: context,
      builder: (_) => ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: np.chapters.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) {
          final c = np.chapters[i];
          return ListTile(
            leading: Text('${i + 1}'),
            title: Text(c.title, maxLines: 2, overflow: TextOverflow.ellipsis),
            trailing: Text(_fmt(c.start)),
            onTap: () {
              Navigator.pop(context);
              widget.playback.seek(c.start);
            },
          );
        },
      ),
    );
  }

  int _currentChapterIndex() {
    final np = widget.playback.nowPlaying;
    if (np == null || np.chapters.isEmpty) return -1;
    final pos = widget.playback.player.position;
    for (var i = 0; i < np.chapters.length; i++) {
      final start = np.chapters[i].start;
      final nextStart =
      (i + 1 < np.chapters.length) ? np.chapters[i + 1].start : null;
      if (nextStart == null) {
        if (pos >= start) return i;
      } else {
        if (pos >= start && pos < nextStart) return i;
      }
    }
    return -1;
  }

  void _prevChapter() {
    final np = widget.playback.nowPlaying;
    if (np == null || np.chapters.isEmpty) return;
    final idx = _currentChapterIndex();
    final target = (idx > 0) ? idx - 1 : 0;
    widget.playback.seek(np.chapters[target].start);
  }

  void _nextChapter() {
    final np = widget.playback.nowPlaying;
    if (np == null || np.chapters.isEmpty) return;
    final idx = _currentChapterIndex();
    final target =
    (idx >= 0 && idx + 1 < np.chapters.length) ? idx + 1 : np.chapters.length - 1;
    widget.playback.seek(np.chapters[target].start);
  }
}

class _SpeedSheet extends StatelessWidget {
  const _SpeedSheet({required this.current});
  final double current;

  @override
  Widget build(BuildContext context) {
    final options = [0.8, 1.0, 1.25, 1.5, 1.75, 2.0];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final v in options)
            RadioListTile<double>(
              value: v,
              groupValue: current,
              title: Text('${v.toStringAsFixed(2)}x'),
              onChanged: (nv) => Navigator.pop(context, nv),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _SleepSheet extends StatelessWidget {
  const _SleepSheet();

  @override
  Widget build(BuildContext context) {
    final options = const [
      Duration(minutes: 15),
      Duration(minutes: 30),
      Duration(minutes: 45),
      Duration(hours: 1),
    ];
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in options)
            ListTile(
              leading: const Icon(Icons.nightlight_round),
              title: Text('${d.inMinutes} minutes'),
              onTap: () => Navigator.pop(context, d),
            ),
          ListTile(
            leading: const Icon(Icons.cancel_outlined),
            title: const Text('Cancel timer'),
            onTap: () => Navigator.pop(context, null),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}
