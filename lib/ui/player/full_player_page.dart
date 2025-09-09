// lib/ui/player/full_player_page.dart
import 'package:flutter/material.dart';

import '../../core/playback_repository.dart';
import '../../core/playback_speed_service.dart';
import '../../core/sleep_timer_service.dart';
import '../../main.dart'; // ServicesScope

class FullPlayerPage extends StatefulWidget {
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

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage> {
  double _dragY = 0.0;

  PopupMenuItem<double> _speedItem(BuildContext context, double current, double value) {
    final sel = (current - value).abs() < 0.001;
    return PopupMenuItem<double>(
      value: value,
      child: Row(
        children: [
          if (sel) ...[
            Icon(Icons.check_rounded, size: 18, color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 6),
          ] else ...[
            const SizedBox(width: 24),
          ],
          Text('${value.toStringAsFixed(2)}×'),
        ],
      ),
    );
  }

  Widget _speedIndicator(double current, ColorScheme cs, TextTheme text) {
    if ((current - 1.0).abs() < 0.001) {
      return Icon(
        Icons.speed_rounded,
        color: cs.onSurfaceVariant,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outline.withOpacity(0.2)),
      ),
      child: Text(
        '${current.toStringAsFixed(2)}×',
        style: text.labelLarge?.copyWith(color: cs.onSurfaceVariant, fontWeight: FontWeight.w600),
      ),
    );
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
      if (pos >= chapters[i].start) {
        currentIdx = i;
      } else {
        break;
      }
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
                  stream: ServicesScope.of(context).services.playback.positionStream,
                  initialData: ServicesScope.of(context).services.playback.player.position,
                  builder: (_, posSnap) {
                    final pos = posSnap.data ?? Duration.zero;
                    int liveIdx = 0;
                    for (int i = 0; i < chapters.length; i++) {
                      if (pos >= chapters[i].start) {
                        liveIdx = i;
                      } else {
                        break;
                      }
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
                          // Show raw time for debugging when long-pressing a row
                          onLongPress: () {
                            debugPrint('[Chapters] Tap ${i+1}: "${c.title}" start=${c.start.inMilliseconds}ms');
                          },
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
                            await ServicesScope.of(context).services.playback.seek(c.start, reportNow: true);
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

  Future<void> _showSleepTimerSheet(BuildContext context, NowPlaying np) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final hasChapters = np.chapters.isNotEmpty;
    final timer = SleepTimerService.instance;

    Duration? selected;
    bool eoc = timer.isEndOfChapter;

    String fmt(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
      final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
      return h > 0 ? '$h:$m:$s' : '$m:$s';
    }

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: cs.surface,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) {
            Widget chip(String label, Duration d) {
              final sel = selected == d && !eoc;
              return ChoiceChip(
                label: Text(label),
                selected: sel,
                onSelected: (_) {
                  setState(() {
                    eoc = false;
                    selected = d;
                  });
                },
              );
            }

            return Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.nights_stay_rounded, color: cs.primary),
                      const SizedBox(width: 12),
                      Text('Sleep timer', style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
                      const Spacer(),
                      if (timer.isActive)
                        TextButton(
                          onPressed: () {
                            timer.stopTimer();
                            setState(() {});
                          },
                          child: const Text('Clear'),
                        ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      chip('1 min', const Duration(minutes: 1)),
                      chip('5 min', const Duration(minutes: 5)),
                      chip('15 min', const Duration(minutes: 15)),
                      chip('30 min', const Duration(minutes: 30)),
                      chip('45 min', const Duration(minutes: 45)),
                      chip('60 min', const Duration(minutes: 60)),
                      chip('90 min', const Duration(minutes: 90)),
                    ],
                  ),
                  if (hasChapters) ...[
                    const SizedBox(height: 8),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('At end of chapter'),
                      subtitle: const Text('Auto-cancels if you change chapters'),
                      value: eoc,
                      onChanged: (v) {
                        setState(() {
                          eoc = v;
                          if (v) selected = null;
                        });
                      },
                    ),
                  ],
                  const SizedBox(height: 8),
                  StreamBuilder<Duration?>(
                    stream: timer.remainingTimeStream,
                    initialData: timer.remainingTime,
                    builder: (ctx, snap) {
                      final rem = snap.data;
                      if (!timer.isActive || rem == null) return const SizedBox.shrink();
                      final modeLabel = timer.isEndOfChapter ? 'End of chapter' : 'Time remaining';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Icon(Icons.timer_rounded, size: 18, color: cs.onSurfaceVariant),
                            const SizedBox(width: 8),
                            Text('$modeLabel: ${fmt(rem)}', style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant)),
                          ],
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () {
                            if (eoc) {
                              timer.startEndOfChapter();
                            } else if (selected != null) {
                              timer.startTimer(selected!);
                            }
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Start'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            timer.stopTimer();
                            Navigator.of(ctx).pop();
                          },
                          child: const Text('Cancel timer'),
                        ),
                      ),
                    ],
                  )
                ],
              ),
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
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (details) {
          final dy = details.delta.dy;
          if (dy > 0 || _dragY > 0) {
            setState(() {
              _dragY = (_dragY + dy).clamp(0.0, MediaQuery.of(context).size.height);
            });
          }
        },
        onVerticalDragEnd: (details) {
          final v = details.velocity.pixelsPerSecond.dy;
          final shouldDismiss = _dragY > 140 || v > 700;
          if (shouldDismiss) {
            Navigator.of(context).maybePop();
          } else {
            setState(() {
              _dragY = 0.0;
            });
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transform: Matrix4.translationValues(0, _dragY, 0),
          child: SafeArea(
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
                          StreamBuilder<double>(
                            stream: ServicesScope.of(context).services.playback.player.speedStream,
                            initialData: ServicesScope.of(context).services.playback.player.speed,
                            builder: (_, speedSnap) {
                              final cur = speedSnap.data ?? 1.0;
                              final speeds = PlaybackSpeedService.instance.availableSpeeds;
                              return PopupMenuButton<double>(
                                tooltip: 'Playback speed',
                                icon: _speedIndicator(cur, cs, text),
                                onSelected: (v) async {
                                  await PlaybackSpeedService.instance.setSpeed(v);
                                },
                                itemBuilder: (context) => [
                                  for (final s in speeds) _speedItem(context, cur, s),
                                ],
                              );
                            },
                          ),
                        ],
                      ),
                    ),

                    // ARTWORK + TITLE
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
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
                            const SizedBox(height: 20),

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
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
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
                                        enabledThumbRadius: 10,
                                        elevation: 4,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
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

                    const SizedBox(height: 8),

                    // CONTROLS + CHAPTERS
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 20),
                      child: Column(
                        children: [
                          // Large transport controls (Material 3) - single row, auto-sized
                          LayoutBuilder(
                            builder: (context, constraints) {
                              final maxW = constraints.maxWidth;
                              double spacing = 12;
                              double side = 56;   // base side buttons
                              double center = 72; // base center button
                              final needed = 4 * side + center + 4 * spacing;
                              if (needed > maxW) {
                                final scale = (maxW - 4 * spacing) / (4 * side + center);
                                final clamped = scale.clamp(0.6, 1.0);
                                side = side * clamped;
                                center = center * clamped;
                              }
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  _ControlButton(
                                    tooltip: 'Previous track',
                                    icon: Icons.skip_previous_rounded,
                                    size: side,
                                    onTap: () async {
                                      if (playback.hasPrev) {
                                        await playback.prevTrack();
                                      }
                                    },
                                  ),
                                  SizedBox(width: spacing),
                                  _ControlButton(
                                    tooltip: 'Back 30s',
                                    icon: Icons.replay_30_rounded,
                                    size: side,
                                    onTap: () => playback.nudgeSeconds(-30),
                                  ),
                                  SizedBox(width: spacing),
                                  StreamBuilder<bool>(
                                    stream: playback.playingStream,
                                    initialData: playback.player.playing,
                                    builder: (_, playSnap) {
                                      final playing = playSnap.data ?? false;
                                      return _ControlButton(
                                        tooltip: playing ? 'Pause' : 'Play',
                                        icon: playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                                        isPrimary: true,
                                        isCircular: !playing, // keep round when showing Play triangle
                                        size: center,
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
                                  SizedBox(width: spacing),
                                  _ControlButton(
                                    tooltip: 'Forward 30s',
                                    icon: Icons.forward_30_rounded,
                                    size: side,
                                    onTap: () => playback.nudgeSeconds(30),
                                  ),
                                  SizedBox(width: spacing),
                                  _ControlButton(
                                    tooltip: 'Next track',
                                    icon: Icons.skip_next_rounded,
                                    size: side,
                                    onTap: () async {
                                      if (playback.hasNext) {
                                        await playback.nextTrack();
                                      }
                                    },
                                  ),
                                ],
                              );
                            },
                          ),

                          const SizedBox(height: 24),

                          // Chapters + Sleep controls with enhanced design
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
                                child: StreamBuilder<Duration?>(
                                  stream: SleepTimerService.instance.remainingTimeStream,
                                  initialData: SleepTimerService.instance.remainingTime,
                                  builder: (ctx, snap) {
                                    final active = SleepTimerService.instance.isActive;
                                    final label = active && snap.data != null
                                        ? 'Sleep · ${SleepTimerService.instance.formattedRemainingTime}'
                                        : 'Sleep';
                                    return FilledButton.tonalIcon(
                                      icon: const Icon(Icons.nightlight_round),
                                      label: Text(label),
                                      onPressed: () => _showSleepTimerSheet(context, np),
                                      style: FilledButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(vertical: 16),
                                        shape: RoundedRectangleBorder(
                                          borderRadius: BorderRadius.circular(16),
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          StreamBuilder<Duration?>(
                            stream: SleepTimerService.instance.remainingTimeStream,
                            initialData: SleepTimerService.instance.remainingTime,
                            builder: (ctx, snap) {
                              final active = SleepTimerService.instance.isActive;
                              if (!active || snap.data == null) return const SizedBox.shrink();
                              final isEoc = SleepTimerService.instance.isEndOfChapter;
                              return Container(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                decoration: BoxDecoration(
                                  color: cs.surfaceContainerHighest,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: cs.outline.withOpacity(0.2)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.timer_rounded, size: 18, color: cs.onSurfaceVariant),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        isEoc
                                            ? 'Sleeping at end of chapter · ${SleepTimerService.instance.formattedRemainingTime}'
                                            : 'Sleep timer · ${SleepTimerService.instance.formattedRemainingTime}',
                                        style: text.bodyMedium?.copyWith(color: cs.onSurfaceVariant),
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () => SleepTimerService.instance.stopTimer(),
                                      child: const Text('Cancel'),
                                    ),
                                  ],
                                ),
                              );
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

/// Enhanced circular MD3 icon button used for transport controls
class _ControlButton extends StatelessWidget {
  const _ControlButton({
    required this.icon,
    required this.onTap,
    this.tooltip,
    this.isPrimary = false,
    this.size = 64,
    this.isCircular = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isPrimary;
  final double size;
  final bool isCircular;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final bg = isPrimary ? cs.primary : cs.surfaceContainerHighest;
    final fg = isPrimary ? cs.onPrimary : cs.onSurface;

    final shape = isCircular
        ? const CircleBorder()
        : RoundedRectangleBorder(borderRadius: BorderRadius.circular(16));

    final child = SizedBox(
      width: size,
      height: size,
      child: Icon(icon, size: size * 0.48, color: fg),
    );

    final button = Material(
      color: bg,
      shape: shape,
      elevation: isPrimary ? 4 : 0,
      shadowColor: isPrimary ? cs.primary.withOpacity(0.3) : Colors.transparent,
      child: InkWell(
        customBorder: shape,
        onTap: onTap,
        child: child,
      ),
    );

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}
