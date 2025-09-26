// lib/ui/player/full_player_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // Create multiple curved animations for different elements
          final slideCurve = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.8, curve: Curves.easeOutQuart),
          );
          final fadeCurve = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 1.0, curve: Curves.easeOut),
          );
          final scaleCurve = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.0, 0.9, curve: Curves.elasticOut),
          );
          final contentCurve = CurvedAnimation(
            parent: animation,
            curve: const Interval(0.2, 1.0, curve: Curves.easeOutCubic),
          );

          return SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.15),
              end: Offset.zero,
            ).animate(slideCurve),
            child: FadeTransition(
              opacity: fadeCurve,
              child: ScaleTransition(
                scale: Tween<double>(
                  begin: 0.95,
                  end: 1.0,
                ).animate(scaleCurve),
                child: AnimatedBuilder(
                  animation: contentCurve,
                  builder: (context, child) {
                    return Transform.translate(
                      offset: Offset(0, 20 * (1 - contentCurve.value)),
                      child: Opacity(
                        opacity: contentCurve.value,
                        child: child,
                      ),
                    );
                  },
                  child: child,
                ),
              ),
            ),
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
      ));
    } finally {
      _isOpen = false;
    }
  }

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage> with TickerProviderStateMixin {
  double _dragY = 0.0;
  bool _dualProgressEnabled = true;
  late AnimationController _contentAnimationController;
  late Animation<double> _coverAnimation;
  late Animation<double> _titleAnimation;
  late Animation<double> _controlsAnimation;

  @override
  void initState() {
    super.initState();
    _loadDualProgressPref();
    _setupContentAnimations();
  }

  void _setupContentAnimations() {
    _contentAnimationController = AnimationController(
      duration: const Duration(milliseconds: 600),
      vsync: this,
    );

    _coverAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: const Interval(0.0, 0.6, curve: Curves.easeOutBack),
    ));

    _titleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: const Interval(0.2, 0.8, curve: Curves.easeOutCubic),
    ));

    _controlsAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: const Interval(0.4, 1.0, curve: Curves.easeOutCubic),
    ));

    // Start the content animation after a short delay
    Future.delayed(const Duration(milliseconds: 100), () {
      if (mounted) {
        _contentAnimationController.forward();
      }
    });
  }

  @override
  void dispose() {
    _contentAnimationController.dispose();
    super.dispose();
  }

  Future<void> _loadDualProgressPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _dualProgressEnabled = prefs.getBool('ui_dual_progress_enabled') ?? true;
      });
    } catch (_) {}
  }

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

    final timer = SleepTimerService.instance;

    Duration? selected;
    bool eoc = false;

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
              final sel = selected == d;
              return ChoiceChip(
                label: Text(
                  label,
                  style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                ),
                labelPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                selected: sel,
                onSelected: (_) {
                  setState(() {
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
                      chip('15', const Duration(minutes: 15)),
                      chip('30', const Duration(minutes: 30)),
                      chip('45', const Duration(minutes: 45)),
                      chip('60', const Duration(minutes: 60)),
                      chip('90', const Duration(minutes: 90)),
                    ],
                  ),
                  // End-of-chapter option removed
                  const SizedBox(height: 8),
                  StreamBuilder<Duration?>(
                    stream: timer.remainingTimeStream,
                    initialData: timer.remainingTime,
                    builder: (ctx, snap) {
                      final rem = snap.data;
                      if (!timer.isActive || rem == null) return const SizedBox.shrink();
                      const modeLabel = 'Time remaining';
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
                            if (selected != null) {
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
          final shouldDismiss = _dragY > 120 || v > 650;
          if (shouldDismiss) {
            Navigator.of(context).maybePop();
          } else {
            setState(() {
              _dragY = 0.0;
            });
          }
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutQuart,
          transform: Matrix4.translationValues(0, _dragY, 0)
            ..scale(1.0 - (_dragY * 0.0003).clamp(0.0, 0.1)),
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
                      child: RepaintBoundary(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Column(
                            children: [
                            // Cover with enhanced shadow and border - made smaller
                            AnimatedBuilder(
                              animation: _coverAnimation,
                              builder: (context, child) {
                                return Transform.scale(
                                  scale: 0.8 + (0.2 * _coverAnimation.value),
                                  child: Transform.translate(
                                    offset: Offset(0, 30 * (1 - _coverAnimation.value)),
                                    child: Opacity(
                                      opacity: _coverAnimation.value,
                                      child: Center(
                                        child: SizedBox(
                                          width: MediaQuery.of(context).size.width * 0.85, // 85% of screen width
                                          child: Hero(
                                            tag: 'mini-cover-${np.libraryItemId}',
                                            child: Container(
                                              decoration: BoxDecoration(
                                                borderRadius: BorderRadius.circular(24),
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: cs.shadow.withOpacity(0.18),
                                                    blurRadius: 12,
                                                    offset: const Offset(0, 6),
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
                                                    gaplessPlayback: true,
                                                    filterQuality: FilterQuality.low,
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
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                            const SizedBox(height: 20),

                            // Title / author / narrator with enhanced typography
                            AnimatedBuilder(
                              animation: _titleAnimation,
                              builder: (context, child) {
                                return Transform.translate(
                                  offset: Offset(0, 20 * (1 - _titleAnimation.value)),
                                  child: Opacity(
                                    opacity: _titleAnimation.value,
                                    child: Column(
                                      children: [
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
                                );
                              },
                            ),
                            if (np.narrator != null && np.narrator!.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(
                                'Narrated by ${np.narrator!}',
                                textAlign: TextAlign.center,
                                style: text.titleSmall?.copyWith(
                                  color: cs.onSurfaceVariant.withOpacity(0.8),
                                  fontWeight: FontWeight.w400,
                                  fontStyle: FontStyle.italic,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ],
                          ),
                        ),
                      ),
                    ),

                    // POSITION + SLIDER
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                      child: StreamBuilder<Duration>(
                        stream: playback.positionStream,
                        initialData: playback.player.position,
                        builder: (_, posSnap) {
                          // Prefer global book progress when enabled and available; otherwise fall back to per-track
                          final globalTotal = playback.totalBookDuration;
                          final useGlobal = _dualProgressEnabled && globalTotal != null && globalTotal > Duration.zero;

                          if (useGlobal) {
                            final globalPos = playback.globalBookPosition ?? Duration.zero;
                            final max = globalTotal.inMilliseconds.toDouble();
                            final value = globalPos.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0);

                            // Determine chapter info for display
                            final np = playback.nowPlaying;
                            int chapterIdx = 0;
                            Duration? chapterStart;
                            Duration? chapterEnd;
                            if (np != null && np.chapters.isNotEmpty) {
                              for (int i = 0; i < np.chapters.length; i++) {
                                if (globalPos >= np.chapters[i].start) {
                                  chapterIdx = i;
                                } else {
                                  break;
                                }
                              }
                              chapterStart = np.chapters[chapterIdx].start;
                              if (chapterIdx + 1 < np.chapters.length) {
                                chapterEnd = np.chapters[chapterIdx + 1].start;
                              } else {
                                chapterEnd = globalTotal;
                              }
                            
                            }

                            final chapterElapsed = (chapterStart != null)
                                ? globalPos - chapterStart
                                : null;
                            final chapterDuration = (chapterStart != null && chapterEnd != null)
                                ? (chapterEnd - chapterStart)
                                : null;

                            return RepaintBoundary(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      thumbShape: const RoundSliderThumbShape(
                                        enabledThumbRadius: 9,
                                        elevation: 3,
                                      ),
                                      overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                      activeTrackColor: cs.primary,
                                      inactiveTrackColor: cs.surfaceContainerHighest,
                                      thumbColor: cs.primary,
                                      overlayColor: cs.primary.withOpacity(0.16),
                                    ),
                                    child: Slider(
                                      min: 0.0,
                                      max: max > 0 ? max : 1.0,
                                      value: value,
                                      onChanged: (v) async {
                                        await playback.seekGlobal(
                                          Duration(milliseconds: v.round()),
                                          reportNow: false,
                                        );
                                      },
                                      onChangeEnd: (v) async {
                                        await playback.seekGlobal(
                                          Duration(milliseconds: v.round()),
                                          reportNow: true,
                                        );
                                      },
                                    ),
                                  ),
                                  // Global time indicators
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          _fmt(globalPos),
                                          style: text.labelLarge?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        Text(
                                          '-${_fmt(globalTotal - globalPos)}',
                                          style: text.labelLarge?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                // Chapter index + chapter time
                                if (np != null && np.chapters.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Padding(
                                    padding: const EdgeInsets.symmetric(horizontal: 4),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          'Chapter ${chapterIdx + 1} of ${np.chapters.length}',
                                          style: text.labelMedium?.copyWith(
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        if (chapterElapsed != null && chapterDuration != null)
                                          Text(
                                            '${_fmt(chapterElapsed)} of ${_fmt(chapterDuration)}',
                                            style: text.labelMedium?.copyWith(
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ],
                                ],
                              ),
                            );
                          }

                          // Fallback: per-track slider (existing behavior)
                          final total = playback.player.duration ?? Duration.zero;
                          final pos = posSnap.data ?? Duration.zero;
                          final max = total.inMilliseconds.toDouble().clamp(0.0, double.infinity);
                          final value = pos.inMilliseconds.toDouble().clamp(0.0, max);

                          return RepaintBoundary(
                            child: Column(
                              children: [
                                SliderTheme(
                                  data: SliderTheme.of(context).copyWith(
                                    trackHeight: 4,
                                    thumbShape: const RoundSliderThumbShape(
                                      enabledThumbRadius: 9,
                                      elevation: 3,
                                    ),
                                    overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                                    activeTrackColor: cs.primary,
                                    inactiveTrackColor: cs.surfaceContainerHighest,
                                    thumbColor: cs.primary,
                                    overlayColor: cs.primary.withOpacity(0.16),
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
                            ),
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 8),

                    // CONTROLS + CHAPTERS
                    AnimatedBuilder(
                      animation: _controlsAnimation,
                      builder: (context, child) {
                        return Transform.translate(
                          offset: Offset(0, 30 * (1 - _controlsAnimation.value)),
                          child: Opacity(
                            opacity: _controlsAnimation.value,
                            child: RepaintBoundary(
                              child: Padding(
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
                                                if (playback.hasSmartPrev) {
                                                  await playback.smartPrev();
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
                                                if (playback.hasSmartNext) {
                                                  await playback.smartNext();
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
                                        // Removed redundant countdown widget (countdown shown on Sleep button only)
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
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
