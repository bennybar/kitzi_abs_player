// lib/ui/player/full_player_page.dart
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/playback_repository.dart';
import '../../core/playback_speed_service.dart';
import '../../core/sleep_timer_service.dart';
import '../../core/ui_prefs.dart';
import '../../core/downloads_repository.dart';
import '../../core/books_repository.dart';
import '../../widgets/glass_widget.dart';
import '../../widgets/book_metadata_sheet.dart';
import '../../main.dart'; // ServicesScope
import 'full_player_overlay.dart';
import 'player_visual_cache.dart';
import '../../core/playback_journal_service.dart';
import 'journal_sheets.dart';

enum _TopMenuAction {
  toggleCompletion,
  toggleGradient,
  toggleChapterizedProgressBar,
  cast,
  playHistory,
  bookmarks,
}

/// Custom slider track shape that allows tighter horizontal padding than the
/// default Material slider track.
class _EdgeToEdgeSliderTrackShape extends RoundedRectSliderTrackShape {
  const _EdgeToEdgeSliderTrackShape({this.horizontalInset = 0});

  final double horizontalInset;

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 2.0;
    final inset = horizontalInset.clamp(0.0, parentBox.size.width / 2);
    final trackLeft = offset.dx;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width - inset * 2;
    return Rect.fromLTWH(trackLeft + inset, trackTop, trackWidth, trackHeight);
  }
}

class _LineSliderThumbShape extends SliderComponentShape {
  const _LineSliderThumbShape({
    this.width = 4,
    this.height = 24,
    this.activeWidth = 6,
    this.activeHeight = 32,
  });

  final double width;
  final double height;
  final double activeWidth;
  final double activeHeight;

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) {
    return Size(activeWidth, activeHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    final canvas = context.canvas;
    final colorTween = ColorTween(
      begin: sliderTheme.disabledThumbColor,
      end: sliderTheme.thumbColor,
    );
    final color = colorTween.evaluate(enableAnimation) ?? sliderTheme.thumbColor;
    final t = activationAnimation.value;
    final w = width + (activeWidth - width) * t;
    final h = height + (activeHeight - height) * t;
    final rect = Rect.fromCenter(center: center, width: w, height: h);
    final rRect = RRect.fromRectAndRadius(rect, Radius.circular(w / 2));
    canvas.drawRRect(rRect, Paint()..color = color ?? Colors.white);
  }
}

class _ChapterTickPainter extends CustomPainter {
  const _ChapterTickPainter({
    required this.fractions,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.trackHeight,
    required this.tickHeight,
    required this.tickWidth,
  });

  final List<double> fractions;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double trackHeight;
  final double tickHeight;
  final double tickWidth;

  @override
  void paint(Canvas canvas, Size size) {
    if (fractions.isEmpty) return;
    final cy = size.height / 2;
    final activePaint = Paint()..color = activeColor;
    final inactivePaint = Paint()..color = inactiveColor;
    final radius = Radius.circular(tickWidth / 2);
    for (final f in fractions) {
      final x = size.width * f;
      final rect = Rect.fromCenter(
        center: Offset(x, cy),
        width: tickWidth,
        height: tickHeight,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, radius),
        f <= progress ? activePaint : inactivePaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChapterTickPainter old) {
    return old.progress != progress ||
        old.activeColor != activeColor ||
        old.inactiveColor != inactiveColor ||
        old.fractions.length != fractions.length;
  }
}

String _formatPlaybackSpeedLabel(double speed) {
  if ((speed - speed.roundToDouble()).abs() < 0.001) {
    return '${speed.toStringAsFixed(0)}×';
  }
  if ((speed * 10 - (speed * 10).roundToDouble()).abs() < 0.001) {
    return '${speed.toStringAsFixed(1)}×';
  }
  return '${speed.toStringAsFixed(2)}×';
}

String _formatDurationHMS(Duration d) {
  final h = d.inHours;
  final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
  final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

Future<void> _handleResumeFromHistory(BuildContext context) async {
  final playback = ServicesScope.of(context).services.playback;
  final prefs = await SharedPreferences.getInstance();
  final enabled = prefs.getBool('ui_resume_from_history_enabled') ?? true;
  if (!context.mounted) return;
  if (!enabled) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Resume previous position is disabled in Settings'),
      ),
    );
    return;
  }
  final needConfirm = prefs.getBool('ui_sync_from_server_confirm') ?? true;

  Duration? lastPosition;
  final nowPlaying = playback.nowPlaying;
  if (nowPlaying != null) {
    try {
      final history = await PlaybackJournalService.instance.historyFor(
        nowPlaying.libraryItemId,
        limit: 1,
      );
      if (history.isNotEmpty) {
        lastPosition = Duration(milliseconds: history.first.positionMs);
      }
    } catch (_) {}
  }

  if (!context.mounted) return;

  bool proceed = true;
  if (needConfirm) {
    proceed =
        await showDialog<bool>(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text('Resume previous position?'),
                content: Text(
                  lastPosition != null
                      ? 'Resume to ${_formatDurationHMS(lastPosition)} from your last pause point?'
                      : 'Replace the current play position with the last saved pause position?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('Resume'),
                  ),
                ],
              ),
        ) ??
        false;
  }

  if (!proceed) return;

  final ok = await playback.resumeFromHistory();
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        ok ? 'Resumed previous position' : 'No previous position found',
      ),
      duration: const Duration(seconds: 2),
    ),
  );
}

/// Cached network image widget with cache validation
/// Checks if cached image is valid, and clears cache if not
class _ValidatedCachedNetworkImage extends StatefulWidget {
  final String imageUrl;
  final BoxFit fit;
  final Duration fadeInDuration;
  final Duration fadeOutDuration;
  final Widget Function(BuildContext, String)? placeholder;
  final Widget Function(BuildContext, String, dynamic)? errorWidget;

  const _ValidatedCachedNetworkImage({
    required this.imageUrl,
    this.fit = BoxFit.cover,
    this.fadeInDuration = const Duration(milliseconds: 220),
    this.fadeOutDuration = const Duration(milliseconds: 120),
    this.placeholder,
    this.errorWidget,
  });

  @override
  State<_ValidatedCachedNetworkImage> createState() =>
      _ValidatedCachedNetworkImageState();
}

class _ValidatedCachedNetworkImageState
    extends State<_ValidatedCachedNetworkImage> {
  String? _currentUrl;
  bool _hasValidated = false;
  int _retryKey = 0; // Key to force rebuild when cache is cleared
  bool _hasRetried = false; // Prevent infinite retry loop

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.imageUrl;
    _validateCache();
  }

  @override
  void didUpdateWidget(_ValidatedCachedNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _currentUrl = widget.imageUrl;
      _hasValidated = false;
      _retryKey = 0;
      _hasRetried = false;
      _validateCache();
    }
  }

  Future<void> _validateCache() async {
    if (_hasValidated) return;
    _hasValidated = true;

    try {
      final cacheManager = DefaultCacheManager();
      final fileInfo = await cacheManager.getFileFromCache(_currentUrl!);

      if (fileInfo != null) {
        final file = fileInfo.file;
        // Check if file exists and has valid size (> 0 bytes)
        bool shouldClear = false;
        if (await file.exists()) {
          final length = await file.length();
          if (length == 0) {
            // Invalid cached file (0 bytes), clear it
            shouldClear = true;
          } else {
            // Try to verify it's a valid image by checking if we can read it
            try {
              final bytes = await file.readAsBytes();
              if (bytes.isEmpty) {
                shouldClear = true;
              } else {
                // Check if cache entry is too old (more than 30 days)
                // This helps with stale cache after app reopens
                final now = DateTime.now();
                final validUntil = fileInfo.validTill;
                if (validUntil != null && now.isAfter(validUntil)) {
                  shouldClear = true;
                }
              }
            } catch (_) {
              // Can't read file, clear cache
              shouldClear = true;
            }
          }
        } else {
          // File doesn't exist, clear cache entry
          shouldClear = true;
        }

        if (shouldClear) {
          await cacheManager.removeFile(_currentUrl!);
          if (mounted) {
            setState(() {
              _retryKey++; // Force rebuild with new key
            });
          }
        }
      }
    } catch (_) {
      // If validation fails, just proceed with normal loading
    }
  }

  Future<void> _handleImageError(
    BuildContext context,
    String url,
    dynamic error,
  ) async {
    // Only retry once to prevent infinite loop
    if (_hasRetried) return;
    _hasRetried = true;

    // Clear cache on error and retry
    try {
      final cacheManager = DefaultCacheManager();
      await cacheManager.removeFile(url);
      if (mounted) {
        setState(() {
          _retryKey++; // Force rebuild to retry
        });
      }
    } catch (_) {
      // If clearing cache fails, just show error widget
    }
  }

  @override
  Widget build(BuildContext context) {
    return CachedNetworkImage(
      key: ValueKey(
        '${_currentUrl}_$_retryKey',
      ), // Force rebuild when retry key changes
      imageUrl: _currentUrl!,
      fit: widget.fit,
      fadeInDuration: widget.fadeInDuration,
      fadeOutDuration: widget.fadeOutDuration,
      placeholder: widget.placeholder,
      errorWidget: (context, url, error) {
        // Clear cache and retry on error (only once)
        if (!_hasRetried) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _handleImageError(context, url, error);
          });
        }
        // Show error widget
        return widget.errorWidget?.call(context, url, error) ??
            Container(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: Icon(
                Icons.menu_book_outlined,
                size: 88,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            );
      },
    );
  }
}

class FullPlayerPage extends StatefulWidget {
  const FullPlayerPage({super.key});

  // Prevent duplicate openings of the FullPlayerPage within the same session.
  static bool _isOpen = false;

  static Future<void> openOnce(BuildContext context) async {
    // Tab mode: bring the Player tab into view instead of opening a modal.
    if (UiPrefs.fullPlayerAsTab.value) {
      FullPlayerOverlay.requestOpen();
      return;
    }
    if (_isOpen) return;
    _isOpen = true;
    FullPlayerOverlay.isVisible.value = true;
    try {
      final playback = ServicesScope.of(context).services.playback;
      final coverUrl = playback.nowPlaying?.coverUrl;
      unawaited(PlayerVisualCache.prewarmCover(coverUrl, context));
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        backgroundColor: Colors.transparent,
        builder:
            (context) => Container(
              height: MediaQuery.of(context).size.height,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(24),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: const FullPlayerPage(),
            ),
      );
    } finally {
      _isOpen = false;
      FullPlayerOverlay.isVisible.value = false;
    }
  }

  @override
  State<FullPlayerPage> createState() => _FullPlayerPageState();
}

class _FullPlayerPageState extends State<FullPlayerPage>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const double _metadataTextScale = 0.85;
  bool _dualProgressEnabled = true;
  ProgressPrimary _progressPrimary = UiPrefs.progressPrimary.value;
  VoidCallback? _progressPrefListener;
  bool _paletteScheduled = false;
  late AnimationController _contentAnimationController;
  late Animation<double> _coverAnimation;
  late Animation<double> _titleAnimation;
  late Animation<double> _controlsAnimation;
  Color? _palettePrimary;
  Color? _paletteSecondary;
  String? _paletteCoverUrl;
  bool _paletteLoading = false;
  bool _warmLoadInProgress = false;
  bool _warmLoadAttempted = false;
  String? _warmLoadError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadDualProgressPref();
    _progressPrimary = UiPrefs.progressPrimary.value;
    _progressPrefListener = () {
      if (mounted) {
        setState(() {
          _progressPrimary = UiPrefs.progressPrimary.value;
        });
      }
    };
    UiPrefs.progressPrimary.addListener(_progressPrefListener!);
    _setupContentAnimations();
    // If the player opens with no active session (e.g., app resumed from long sleep),
    // try to warm-load the last item so we don't stick on the loading screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restoreNowPlayingIfNeeded();
    });
  }

  Future<void> _restoreNowPlayingIfNeeded({bool force = false}) async {
    if (!mounted) return;
    final playback = ServicesScope.of(context).services.playback;
    if (!force &&
        (playback.nowPlaying != null ||
            _warmLoadInProgress ||
            _warmLoadAttempted)) {
      return;
    }

    setState(() {
      _warmLoadAttempted = true;
      _warmLoadInProgress = true;
      _warmLoadError = null;
    });

    try {
      await playback.warmLoadLastItem(playAfterLoad: false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _warmLoadError = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _warmLoadInProgress = false;
        });
      } else {
        _warmLoadInProgress = false;
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      // When returning from a long sleep/background, the playback repo might
      // have been torn down; kick a warm load if nothing is active.
      final playback = ServicesScope.of(context).services.playback;
      if (playback.nowPlaying == null) {
        _restoreNowPlayingIfNeeded(force: true);
      }
    }
  }

  void _setupContentAnimations() {
    _contentAnimationController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );

    _coverAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentAnimationController,
        curve: Curves.easeOut,
      ),
    );

    _titleAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _controlsAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _contentAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _contentAnimationController.forward();
      }
    });
  }

  void _schedulePaletteUpdate(NowPlaying np) {
    if (_paletteScheduled || _paletteLoading) return;
    _paletteScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _paletteScheduled = false;
        return;
      }
      try {
        await _maybeUpdatePalette(np);
      } finally {
        _paletteScheduled = false;
      }
    });
  }

  Future<void> _maybeUpdatePalette(NowPlaying np) async {
    final cover = np.coverUrl;

    if (cover == null || cover.isEmpty) {
      if (_paletteCoverUrl != null ||
          _palettePrimary != null ||
          _paletteSecondary != null) {
        setState(() {
          _paletteCoverUrl = null;
          _palettePrimary = null;
          _paletteSecondary = null;
        });
      }
      return;
    }

    if (_paletteCoverUrl == cover || _paletteLoading) return;

    _paletteLoading = true;
    try {
      final palette = await PlayerVisualCache.paletteForCover(
        cover,
        size: const Size(200, 200),
        maximumColorCount: 12,
      );

      if (!mounted) return;
      setState(() {
        _paletteCoverUrl = cover;
        _palettePrimary = palette.primary;
        _paletteSecondary = palette.secondary ?? palette.primary;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _paletteCoverUrl = cover;
        _palettePrimary = null;
        _paletteSecondary = null;
      });
    } finally {
      _paletteLoading = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _contentAnimationController.dispose();
    if (_progressPrefListener != null) {
      UiPrefs.progressPrimary.removeListener(_progressPrefListener!);
    }
    super.dispose();
  }

  Future<void> _loadDualProgressPref() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      setState(() {
        _dualProgressEnabled =
            prefs.getBool('ui_dual_progress_enabled') ?? true;
      });
    } catch (_) {}
  }

  _CoverDims _coverDimensionsForSize(
    BuildContext context,
    PlayerCoverSize size, {
    double? availableHeight,
    int metadataLineCount = 3,
  }) {
    final widthFactor = switch (size) {
      PlayerCoverSize.small => 0.48,
      PlayerCoverSize.medium => 0.62,
      PlayerCoverSize.large => 0.7,
      PlayerCoverSize.extraLarge => 0.78,
    };
    final radius = switch (size) {
      PlayerCoverSize.small => 20.0,
      PlayerCoverSize.medium => 22.0,
      PlayerCoverSize.large => 24.0,
      PlayerCoverSize.extraLarge => 26.0,
    };
    final screenWidth = MediaQuery.of(context).size.width;
    var width = screenWidth * widthFactor;

    if (availableHeight != null && availableHeight > 0) {
      final reservedHeight = 24.0 + metadataLineCount * 18.0;
      final dynamicMax =
          (availableHeight - reservedHeight)
              .clamp(screenWidth * 0.48, screenWidth * 0.9)
              .toDouble();
      width = dynamicMax;
    }

    return _CoverDims(width: width, radius: radius);
  }

  int _estimatedMetadataLineCount(NowPlaying np) {
    int lines = 1;

    final titleLength = np.title.trim().length;
    if (titleLength > 26) lines++;
    if (titleLength > 52) lines++;

    final author = np.author?.trim() ?? '';
    if (author.isNotEmpty) {
      lines += author.length > 30 ? 2 : 1;
    }

    final narrator = np.narrator?.trim() ?? '';
    if (narrator.isNotEmpty) {
      final narratorLabelLength = narrator.length + 12;
      lines += narratorLabelLength > 34 ? 2 : 1;
    }

    return lines.clamp(2, 6);
  }

  Widget _buildBookProgressSection({
    required BuildContext context,
    required TextTheme text,
    required ColorScheme cs,
    required PlaybackRepository playback,
    required Duration position,
    required Duration total,
    required bool isPrimary,
    List<Chapter> chapters = const [],
  }) {
    final max = total.inMilliseconds.toDouble();
    final sliderMax = max > 0 ? max : 1.0;
    final value = position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final remaining =
        (total - position).isNegative ? Duration.zero : total - position;
    final sliderHeight = isPrimary ? 30.0 : 26.0;

    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: 4,
      padding: EdgeInsets.zero,
      thumbShape: _LineSliderThumbShape(
        width: isPrimary ? 5 : 4,
        height: isPrimary ? 30 : 24,
      ),
      overlayShape: SliderComponentShape.noOverlay,
      activeTrackColor: cs.primary,
      inactiveTrackColor: cs.surfaceContainerHighest,
      thumbColor: cs.primary,
      trackShape: const _EdgeToEdgeSliderTrackShape(horizontalInset: 0),
    );

    final chapterTicks = <double>[];
    if (chapters.length > 1 && max > 0) {
      for (int i = 1; i < chapters.length; i++) {
        final ms = chapters[i].start.inMilliseconds.toDouble();
        if (ms > 0 && ms < max) {
          chapterTicks.add(ms / max);
        }
      }
    }

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SliderTheme(
            data: sliderTheme,
            child: SizedBox(
              height: sliderHeight,
              width: double.infinity,
              child: Stack(
                children: [
                  Slider(
                    min: 0.0,
                    max: sliderMax,
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
                  if (chapterTicks.isNotEmpty)
                    Positioned.fill(
                      child: IgnorePointer(
                        child: ValueListenableBuilder<bool>(
                          valueListenable: UiPrefs.progressBarChapterized,
                          builder: (_, chapterized, __) {
                            if (!chapterized) return const SizedBox.shrink();
                            return CustomPaint(
                              painter: _ChapterTickPainter(
                                fractions: chapterTicks,
                                progress: (value / sliderMax).clamp(0.0, 1.0),
                                activeColor: cs.onPrimary.withOpacity(0.55),
                                inactiveColor:
                                    cs.onSurfaceVariant.withOpacity(0.55),
                                trackHeight: 4,
                                tickHeight: 6,
                                tickWidth: 2,
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(position),
                  style: (isPrimary ? text.labelLarge : text.bodyMedium)
                      ?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                ),
                Text(
                  '-${_fmt(remaining)}',
                  style: (isPrimary ? text.labelLarge : text.bodyMedium)
                      ?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
                      ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChapterProgressPrimary({
    required BuildContext context,
    required TextTheme text,
    required ColorScheme cs,
    required PlaybackRepository playback,
    required ChapterProgressMetrics metrics,
  }) {
    final duration = metrics.duration;
    if (duration <= Duration.zero) return const SizedBox.shrink();
    final max = duration.inMilliseconds.toDouble();
    final value = metrics.elapsed.inMilliseconds.toDouble().clamp(0.0, max);
    final remaining = duration - metrics.elapsed;
    const sliderHeight = 30.0;

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              padding: EdgeInsets.zero,
              thumbShape: const _LineSliderThumbShape(
                width: 5,
                height: 30,
              ),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
              trackShape: const _EdgeToEdgeSliderTrackShape(
                horizontalInset: 0,
              ),
            ),
            child: SizedBox(
              height: sliderHeight,
              width: double.infinity,
              child: Slider(
                min: 0.0,
                max: max > 0 ? max : 1.0,
                value: value,
                onChanged: (v) async {
                  await playback.seekGlobal(
                    metrics.start + Duration(milliseconds: v.round()),
                    reportNow: false,
                  );
                },
                onChangeEnd: (v) async {
                  await playback.seekGlobal(
                    metrics.start + Duration(milliseconds: v.round()),
                    reportNow: true,
                  );
                },
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(metrics.elapsed),
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  '-${_fmt(remaining)}',
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _chapterDescriptor(metrics),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: text.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${_fmt(metrics.elapsed)} / ${_fmt(duration)}',
                  style: text.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBookDetailStyleChapterTimeline({
    required TextTheme text,
    required ColorScheme cs,
    required Duration position,
    required Duration total,
    required List<Chapter> chapters,
    required ChapterProgressMetrics? metrics,
  }) {
    if (total <= Duration.zero || chapters.length <= 1) {
      return const SizedBox.shrink();
    }

    int chapterIndex = metrics?.index ?? 0;
    if (metrics == null) {
      for (int i = chapters.length - 1; i >= 0; i--) {
        if (position >= chapters[i].start) {
          chapterIndex = i;
          break;
        }
      }
    }

    final chapterLabel =
        metrics != null
            ? _chapterDescriptor(metrics)
            : 'Chapter ${chapterIndex + 1} of ${chapters.length}';
    final chapterTimeLabel =
        metrics != null
            ? '${_fmt(metrics.elapsed)} / ${_fmt(metrics.duration)}'
            : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Text(
            chapterLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            softWrap: false,
            style: text.bodySmall?.copyWith(
              color: cs.primary,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (chapterTimeLabel != null) ...[
          const SizedBox(width: 12),
          Text(
            chapterTimeLabel,
            style: text.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildTrackProgressFallback({
    required BuildContext context,
    required ColorScheme cs,
    required TextTheme text,
    required PlaybackRepository playback,
    required Duration total,
    required Duration position,
  }) {
    final max = total.inMilliseconds.toDouble().clamp(0.0, double.infinity);
    final value = position.inMilliseconds.toDouble().clamp(
      0.0,
      max > 0 ? max : 1.0,
    );

    return RepaintBoundary(
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 4,
              padding: EdgeInsets.zero,
              thumbShape: const _LineSliderThumbShape(
                width: 5,
                height: 30,
              ),
              overlayShape: SliderComponentShape.noOverlay,
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
              trackShape: const _EdgeToEdgeSliderTrackShape(
                horizontalInset: 0,
              ),
            ),
            child: SizedBox(
              width: double.infinity,
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
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(position),
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
                Text(
                  '-${_fmt(total - position)}',
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  BoxDecoration _playerBackgroundDecoration(
    bool gradientEnabled,
    ColorScheme cs,
    Brightness brightness, {
    Color? palettePrimary,
    Color? paletteSecondary,
  }) {
    if (!gradientEnabled) {
      return BoxDecoration(color: cs.surface);
    }
    final primary = palettePrimary ?? cs.primary;
    final secondary = paletteSecondary ?? cs.secondary;
    final colors =
        brightness == Brightness.dark
            ? [
              Color.alphaBlend(primary.withOpacity(0.2), cs.surface),
              Color.alphaBlend(
                secondary.withOpacity(0.14),
                cs.surfaceContainerHighest,
              ),
              Colors.black,
            ]
            : [
              Color.alphaBlend(primary.withOpacity(0.12), cs.surface),
              Color.alphaBlend(secondary.withOpacity(0.08), cs.surface),
              Colors.white,
            ];
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    );
  }

  List<BoxShadow> _artworkShadows(
    _CoverDims dims,
    ColorScheme cs,
    bool isPlaying,
  ) {
    final glowColor = _palettePrimary ?? cs.primary;
    if (!isPlaying) {
      return [
        ...dims.shadows(cs),
        BoxShadow(
          color: glowColor.withOpacity(0.10),
          blurRadius: 44,
          spreadRadius: -6,
          offset: const Offset(0, 10),
        ),
      ];
    }
    return [
      BoxShadow(
        color: cs.shadow.withOpacity(0.22),
        blurRadius: 28,
        spreadRadius: 0,
        offset: const Offset(0, 14),
      ),
      BoxShadow(
        color: glowColor.withOpacity(0.26),
        blurRadius: 56,
        spreadRadius: 2,
        offset: const Offset(0, 18),
      ),
    ];
  }

  Widget _buildHeroArtwork({
    required BuildContext context,
    required PlaybackRepository playback,
    required NowPlaying np,
    required _CoverDims dims,
    required ColorScheme cs,
  }) {
    return StreamBuilder<bool>(
      stream: playback.playingStream,
      initialData: playback.player.playing,
      builder: (_, playSnap) {
        final isPlaying = playSnap.data ?? false;
        return AnimatedBuilder(
          animation: _coverAnimation,
          builder: (context, child) {
            final t = _coverAnimation.value;
            final fade = Curves.easeOut.transform(t);
            final entranceScale = 0.975 + 0.0325 * Curves.easeOut.transform(t);
            final translateY = 14 * (1 - t);
            return Transform.translate(
              offset: Offset(0, translateY),
              child: Opacity(
                opacity: fade,
                child: Transform.scale(
                  scale: entranceScale,
                  child: AnimatedScale(
                    scale: isPlaying ? 1.018 : 1.0,
                    duration: const Duration(milliseconds: 650),
                    curve: Curves.easeOutCubic,
                    child: child,
                  ),
                ),
              ),
            );
          },
          child: Center(
            child: SizedBox(
              width: dims.width,
              child: AspectRatio(
                aspectRatio: 1,
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(dims.radius + 10),
                          gradient: RadialGradient(
                            center: const Alignment(-0.2, -0.35),
                            radius: 1.0,
                            colors: [
                              (_palettePrimary ?? cs.primary).withOpacity(0.28),
                              (_paletteSecondary ?? cs.secondary).withOpacity(
                                0.14,
                              ),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.52, 1.0],
                          ),
                        ),
                      ),
                    ),
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 650),
                      curve: Curves.easeOutCubic,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(dims.radius),
                        border: Border.all(
                          color: cs.outline.withOpacity(0.6),
                          width: 2.0,
                        ),
                        boxShadow: _artworkShadows(dims, cs, isPlaying),
                      ),
                    ),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(dims.radius),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Transform.scale(
                            scale: 1.024,
                            child:
                                np.coverUrl != null && np.coverUrl!.isNotEmpty
                                    ? _ValidatedCachedNetworkImage(
                                      imageUrl: np.coverUrl!,
                                      fit: BoxFit.cover,
                                      fadeInDuration: const Duration(
                                        milliseconds: 220,
                                      ),
                                      fadeOutDuration: const Duration(
                                        milliseconds: 120,
                                      ),
                                      placeholder:
                                          (_, __) => Container(
                                            decoration: BoxDecoration(
                                              gradient: LinearGradient(
                                                colors: [
                                                  cs.surfaceContainerHighest,
                                                  cs.surfaceContainerHigh
                                                      .withOpacity(0.9),
                                                ],
                                                begin: Alignment.topLeft,
                                                end: Alignment.bottomRight,
                                              ),
                                            ),
                                            child: Icon(
                                              Icons.menu_book_outlined,
                                              size: 88,
                                              color: cs.onSurfaceVariant
                                                  .withOpacity(0.75),
                                            ),
                                          ),
                                      errorWidget:
                                          (_, __, ___) => Container(
                                            color: cs.surfaceContainerHighest,
                                            child: Icon(
                                              Icons.menu_book_outlined,
                                              size: 88,
                                              color: cs.onSurfaceVariant,
                                            ),
                                          ),
                                    )
                                    : Container(
                                      color: cs.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.menu_book_outlined,
                                        size: 88,
                                        color: cs.onSurfaceVariant,
                                      ),
                                    ),
                          ),
                          DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withOpacity(0.04),
                                  Colors.black.withOpacity(0.4),
                                ],
                                stops: const [0.55, 0.72, 1.0],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Positioned.fill(child: _SleepTimerArcOverlay()),
                    Positioned(
                      top: 12,
                      right: 12,
                      child: _CoverIconButton(
                        icon: Symbols.bookmark_add,
                        tooltip: 'Add bookmark',
                        onTap: () => _addBookmark(context, playback),
                      ),
                    ),
                    Positioned(
                      bottom: 12,
                      left: 12,
                      child: _CoverIconButton(
                        icon: Symbols.history,
                        tooltip: 'Resume previous play position',
                        iconColor: const Color(0xFF7EE08A),
                        label: 'Last position',
                        onTap: () => _handleResumeFromHistory(context),
                      ),
                    ),
                    Positioned(
                      bottom: 12,
                      right: 12,
                      child: _CoverIconButton(
                        icon: Symbols.info,
                        tooltip: 'Book details',
                        label: 'More info',
                        onTap:
                            () => _showPlayerMetadataSheet(
                              context,
                              playback,
                              np,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildHeroMetadata({
    required BuildContext context,
    required TextTheme text,
    required ColorScheme cs,
    required PlaybackRepository playback,
    required NowPlaying np,
    required Duration? totalDuration,
    bool embedded = false,
  }) {
    final chapterMetrics = playback.currentChapterProgress;
    final content = Column(
      children: [
        ValueListenableBuilder<bool>(
          valueListenable: UiPrefs.playerScrollingSingleLineTitle,
          builder: (context, singleLineScrollingTitle, _) {
            final titleStyle = text.headlineSmall?.copyWith(
              fontSize:
                  (text.headlineSmall?.fontSize ?? 28) * _metadataTextScale,
              fontWeight: FontWeight.w800,
              height: 1.08,
              letterSpacing: -0.45,
            );
            if (!singleLineScrollingTitle) {
              return Text(
                np.title,
                textAlign: TextAlign.center,
                style: titleStyle,
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              );
            }
            return _LoopingMarqueeText(
              text: np.title,
              style: titleStyle,
              gap: 40,
              pause: const Duration(milliseconds: 900),
              pixelsPerSecond: 36,
            );
          },
        ),
        if (np.author != null && np.author!.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            np.author!,
            textAlign: TextAlign.center,
            style: text.titleMedium?.copyWith(
              fontSize:
                  (text.titleMedium?.fontSize ?? 17) * _metadataTextScale,
              color: cs.onSurfaceVariant.withOpacity(0.92),
              fontWeight: FontWeight.w600,
              letterSpacing: 0.05,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        if (np.narrator != null && np.narrator!.isNotEmpty) ...[
          const SizedBox(height: 3),
          Text(
            'Narrated by ${np.narrator!}',
            textAlign: TextAlign.center,
            style: text.bodyMedium?.copyWith(
              fontSize:
                  (text.bodyMedium?.fontSize ?? 14) * _metadataTextScale,
              color: cs.onSurfaceVariant.withOpacity(0.66),
              fontWeight: FontWeight.w500,
              letterSpacing: 0.1,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
        const SizedBox(height: 10),
        if (totalDuration != null)
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              _InfoPill(
                icon: Symbols.schedule,
                label: _formatDuration(totalDuration),
              ),
            ],
          ),
      ],
    );

    return AnimatedBuilder(
      animation: _titleAnimation,
      builder: (context, child) {
        return Transform.translate(
          offset: Offset(0, 20 * (1 - _titleAnimation.value)),
          child: Opacity(
            opacity: _titleAnimation.value,
            child: SizedBox(
              width: double.infinity,
              child: child,
            ),
          ),
        );
      },
      child:
          embedded
              ? content
              : _GlassPanel(
                borderRadius: 30,
                tint: Color.alphaBlend(
                  cs.surface.withOpacity(0.34),
                  cs.surfaceContainerHigh.withOpacity(0.74),
                ),
                padding: const EdgeInsets.fromLTRB(18, 20, 18, 14),
                child: content,
              ),
    );
  }

  Future<void> _showPlayerMetadataSheet(
    BuildContext context,
    PlaybackRepository playback,
    NowPlaying np,
  ) {
    return showBookMetadataSheet(
      context: context,
      title: np.title,
      subtitle: np.author,
      cacheKey: np.libraryItemId,
      loadFacts: () => _loadPlayerMetadataFacts(context, playback, np),
    );
  }

  Future<List<BookMetadataFact>> _loadPlayerMetadataFacts(
    BuildContext context,
    PlaybackRepository playback,
    NowPlaying np,
  ) async {
    final facts = <BookMetadataFact>[];

    void add(String label, String? value, IconData icon) {
      final trimmed = value?.trim();
      if (trimmed == null || trimmed.isEmpty) return;
      facts.add(BookMetadataFact(label: label, value: trimmed, icon: icon));
    }

    final services = ServicesScope.of(context).services;
    final api = services.auth.api;

    Map<String, dynamic>? item;
    List<dynamic> files = const [];
    try {
      final itemResp = await api.request('GET', '/api/items/${np.libraryItemId}');
      if (itemResp.statusCode == 200 && itemResp.body.isNotEmpty) {
        final parsed = jsonDecode(itemResp.body);
        item =
            (parsed is Map && parsed['item'] is Map)
                ? (parsed['item'] as Map).cast<String, dynamic>()
                : (parsed as Map).cast<String, dynamic>();
      }
    } catch (_) {}
    try {
      final filesResp = await api.request(
        'GET',
        '/api/items/${np.libraryItemId}/files',
      );
      if (filesResp.statusCode == 200 && filesResp.body.isNotEmpty) {
        final parsed = jsonDecode(filesResp.body);
        if (parsed is Map && parsed['files'] is List) {
          files = parsed['files'] as List;
        } else if (parsed is List) {
          files = parsed;
        }
      }
    } catch (_) {}
    DateTime? firstStartedAt;
    try {
      final progressResp = await api.request(
        'GET',
        '/api/me/progress/${np.libraryItemId}',
      );
      if (progressResp.statusCode == 200 && progressResp.body.isNotEmpty) {
        final parsed = jsonDecode(progressResp.body);
        if (parsed is Map<String, dynamic>) {
          firstStartedAt = _extractStartedAtFromProgress(parsed);
        }
      }
    } catch (_) {}

    final meta =
        item?['media'] is Map &&
                (item!['media'] as Map)['metadata'] is Map<String, dynamic>
            ? ((item['media'] as Map)['metadata'] as Map).cast<String, dynamic>()
            : const <String, dynamic>{};

    final cachedRepo = await BooksRepository.create();
    final cachedBook = await cachedRepo.getBookFromDb(np.libraryItemId);
    cachedRepo.dispose();

    add('Author', np.author ?? cachedBook?.author, Symbols.person);
    add(
      'Narrator',
      np.narrator ??
          ((cachedBook?.narrators?.isNotEmpty ?? false)
              ? cachedBook!.narrators!.join(', ')
              : null),
      Symbols.mic,
    );
    facts.add(
      BookMetadataFact(
        label: 'Released year',
        value:
            _extractMetadataYear(
              cachedBook?.publishYear,
              meta,
              item,
            ) ??
            'Unknown',
        icon: Symbols.calendar_today,
      ),
    );
    add(
      'Publisher',
      cachedBook?.publisher ?? meta['publisher']?.toString(),
      Symbols.business,
    );
    add(
      'Distribution',
      (meta['distribution'] ?? meta['distributor'])?.toString(),
      Symbols.local_shipping,
    );
    add(
      'File type',
      _playerMetadataFileTypes(files, np.tracks),
      Symbols.audio_file,
    );
    add(
      'Bitrate',
      _playerMetadataBitrate(files),
      Symbols.graph_2,
    );
    add('Tracks', np.tracks.length.toString(), Symbols.queue_music);
    add(
      'Length',
      np.durationSec != null && np.durationSec! > 0
          ? _formatDuration(Duration(seconds: np.durationSec!.round()))
          : (cachedBook?.durationMs != null
              ? _formatDuration(Duration(milliseconds: cachedBook!.durationMs!))
              : null),
      Symbols.schedule,
    );
    facts.add(
      BookMetadataFact(
        label: 'Size',
        value:
            _playerMetadataSizeLabel(cachedBook?.sizeBytes, item, files) ??
            'Unavailable',
        icon: Symbols.folder_zip,
      ),
    );
    add(
      'Source',
      np.tracks.isNotEmpty && np.tracks.every((t) => t.isLocal)
          ? 'Downloaded'
          : 'Streaming',
      Symbols.cloud_done,
    );
    add(
      'Started',
      _formatMetadataDateTime(firstStartedAt ?? playback.listeningStartedAt),
      Symbols.history,
    );
    add(
      'Added to library',
      _formatMetadataDateTime(cachedBook?.addedAt),
      Symbols.library_add,
    );
    add(
      'Updated',
      _formatMetadataDateTime(cachedBook?.updatedAt),
      Symbols.update,
    );

    return facts;
  }

  String? _playerMetadataFileTypes(
    List<dynamic> files,
    List<PlaybackTrack> tracks,
  ) {
    final values = <String>{};
    for (final file in files) {
      if (file is! Map) continue;
      final map = file.cast<String, dynamic>();
      final raw =
          (map['mimeType'] ??
                  map['contentType'] ??
                  map['ext'] ??
                  map['extension'])
              ?.toString();
      final formatted = _formatMetadataFileType(raw);
      if (formatted != null) values.add(formatted);
    }
    for (final track in tracks) {
      final formatted = _formatMetadataFileType(track.mimeType);
      if (formatted != null) values.add(formatted);
    }
    if (values.isEmpty) return null;
    return values.take(3).join(' / ');
  }

  String? _playerMetadataBitrate(List<dynamic> files) {
    final values = <int>{};
    for (final file in files) {
      if (file is! Map) continue;
      final map = file.cast<String, dynamic>();
      final raw =
          map['bitRate'] ??
          map['bitrate'] ??
          map['bit_rate'] ??
          map['audioBitrate'];
      int? parsed;
      if (raw is num) parsed = raw.round();
      if (raw is String) parsed = int.tryParse(raw);
      if (parsed == null || parsed <= 0) continue;
      if (parsed > 1000) parsed = (parsed / 1000).round();
      values.add(parsed);
    }
    if (values.isEmpty) return null;
    final sorted = values.toList()..sort();
    return sorted.map((it) => '${it} kbps').join(' / ');
  }

  int _playerMetadataTotalBytes(List<dynamic> files) {
    int total = 0;
    for (final file in files) {
      if (file is! Map) continue;
      final map = file.cast<String, dynamic>();
      final raw = map['size'] ?? map['bytes'] ?? map['fileSize'];
      if (raw is num) total += raw.toInt();
      if (raw is String) total += int.tryParse(raw) ?? 0;
    }
    return total;
  }

  String? _playerMetadataSizeLabel(
    int? cachedSize,
    Map<String, dynamic>? item,
    List<dynamic> files,
  ) {
    final fileTotal = _playerMetadataTotalBytes(files);
    if (fileTotal > 0) return _formatBytes(fileTotal);
    if (cachedSize != null && cachedSize > 0) return _formatBytes(cachedSize);
    final media = item?['media'];
    if (media is Map) {
      final raw = media['size'] ?? media['bytes'] ?? media['fileSize'];
      final parsed = _parseMetadataInt(raw);
      if (parsed != null && parsed > 0) return _formatBytes(parsed);
    }
    final parsed = _parseMetadataInt(
      item?['size'] ?? item?['bytes'] ?? item?['fileSize'],
    );
    if (parsed != null && parsed > 0) return _formatBytes(parsed);
    return null;
  }

  String? _extractMetadataYear(
    int? cachedYear,
    Map<String, dynamic> meta,
    Map<String, dynamic>? item,
  ) {
    if (cachedYear != null && cachedYear > 0) return cachedYear.toString();
    final candidates = [
      meta['publishYear'],
      meta['year'],
      meta['releaseYear'],
      meta['publishedYear'],
      item?['year'],
      item?['publishYear'],
      item?['releaseYear'],
      item?['publishedYear'],
      item?['publishedAt'],
      item?['releaseDate'],
    ];
    for (final candidate in candidates) {
      final parsed = _parseMetadataYear(candidate);
      if (parsed != null) return parsed.toString();
    }
    return null;
  }

  int? _parseMetadataYear(dynamic raw) {
    final parsed = _parseMetadataInt(raw);
    if (parsed != null && parsed >= 1000 && parsed <= 3000) return parsed;
    if (raw is String && raw.trim().isNotEmpty) {
      final match = RegExp(r'(19|20)\d{2}').firstMatch(raw);
      if (match != null) return int.tryParse(match.group(0)!);
    }
    return null;
  }

  int? _parseMetadataInt(dynamic raw) {
    if (raw is num) return raw.toInt();
    if (raw is String && raw.trim().isNotEmpty) {
      return int.tryParse(raw.trim());
    }
    return null;
  }

  String? _formatMetadataFileType(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final normalized = raw.trim().toLowerCase();
    if (normalized.contains('/')) {
      final parts = normalized.split('/');
      return parts.last.toUpperCase();
    }
    return normalized.replaceFirst('.', '').toUpperCase();
  }

  String _formatMetadataDateTime(DateTime? date) {
    if (date == null) return '';
    final local = date.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    final hour = local.hour.toString().padLeft(2, '0');
    final minute = local.minute.toString().padLeft(2, '0');
    return '${local.year}-$month-$day $hour:$minute';
  }

  DateTime? _extractStartedAtFromProgress(Map<String, dynamic> data) {
    final raw =
        data['startedAt'] ??
        data['startTime'] ??
        data['firstStartedAt'] ??
        data['createdAt'];
    final direct = _parseMetadataDateTime(raw);
    if (direct != null) return direct;
    final nested = _firstMapValue(data);
    if (nested == null) return null;
    return _parseMetadataDateTime(
      nested['startedAt'] ??
          nested['startTime'] ??
          nested['firstStartedAt'] ??
          nested['createdAt'],
    );
  }

  DateTime? _parseMetadataDateTime(dynamic raw) {
    if (raw == null) return null;
    if (raw is num) {
      final value = raw.toDouble();
      if (value > 1000000000000) {
        return DateTime.fromMillisecondsSinceEpoch(value.round(), isUtc: true);
      }
      if (value > 1000000000) {
        return DateTime.fromMillisecondsSinceEpoch(
          (value * 1000).round(),
          isUtc: true,
        );
      }
    }
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  Map<String, dynamic>? _firstMapValue(Map<String, dynamic> data) {
    for (final value in data.values) {
      if (value is Map<String, dynamic>) return value;
      if (value is Map) {
        return value.cast<String, dynamic>();
      }
    }
    return null;
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return 'Unknown';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    double value = bytes.toDouble();
    int unitIndex = 0;
    while (value >= 1024 && unitIndex < units.length - 1) {
      value /= 1024;
      unitIndex++;
    }
    final decimals = value >= 100 || unitIndex == 0 ? 0 : 1;
    return '${value.toStringAsFixed(decimals)} ${units[unitIndex]}';
  }

  void _showCastingComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Casting support is coming soon.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _buildChaptersQuickIcon({
    required BuildContext context,
    required ColorScheme cs,
    required int totalChapters,
    required int currentChapter,
  }) {
    final disabled = totalChapters <= 1;
    return Icon(
      Symbols.format_list_bulleted,
      color: disabled ? cs.onSurfaceVariant : cs.onSurface,
    );
  }

  String _chapterDescriptor(ChapterProgressMetrics metrics) {
    final base = 'Chapter ${metrics.index + 1} of ${metrics.totalChapters}';
    final title = metrics.title;
    if (title == null || title.isEmpty) return base;
    return '$base • $title';
  }

  Stream<bool> _getBookCompletionStream() {
    final playback = ServicesScope.of(context).services.playback;
    return playback.nowPlayingStream.asyncExpand((np) {
      if (np == null) return Stream.value(false);

      // Use the new completion status stream from PlaybackRepository
      return playback.getBookCompletionStream(np.libraryItemId);
    });
  }

  Future<void> _toggleBookCompletion(
    BuildContext context,
    bool isCurrentlyCompleted,
  ) async {
    final playback = ServicesScope.of(context).services.playback;
    final np = playback.nowPlaying;
    if (np == null) return;

    final newCompletionStatus = !isCurrentlyCompleted;

    // Show confirmation dialog(s)
    Duration? unfinishChoice; // null => cancel, 0 => restart, >0 => resume
    if (newCompletionStatus) {
      final confirmed = await _showMarkAsFinishedDialog(context);
      if (!confirmed) return;
    } else {
      unfinishChoice = await _showMarkAsUnfinishedDialog(context);
      if (unfinishChoice == null) return;
    }

    // Save current position if we're unfinishing
    Duration? savedPosition;
    bool wasPlaying = false;
    if (!newCompletionStatus) {
      savedPosition = playback.player.position;
      wasPlaying = playback.player.playing;
      // Saved position and playback state
    }

    try {
      // Log the request for troubleshooting
      // Toggling book completion

      // Send the request to server
      double? overrideSeconds;
      if (!newCompletionStatus && unfinishChoice != null) {
        overrideSeconds = unfinishChoice.inSeconds.toDouble();
      }
      await _markBookAsFinished(
        np.libraryItemId,
        newCompletionStatus,
        overrideCurrentTimeSeconds: overrideSeconds,
      );

      // Update the global completion status cache and notify all listeners
      await playback.updateBookCompletionStatus(
        np.libraryItemId,
        newCompletionStatus,
      );

      // If marking as finished, stop playback and navigate to book details
      if (newCompletionStatus) {
        // Book marked as finished, stopping playback

        // Stop the current playback
        await playback.stop();

        // Show feedback to user
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Book marked as finished'),
              duration: Duration(seconds: 2),
            ),
          );
        }

        // Navigate back to book details page. Only pop when we're actually
        // presented on a route (modal mode); in tab mode the player is not a
        // route, so popping would dismiss an unrelated route.
        if (mounted) {
          final nav = Navigator.of(context);
          if (!UiPrefs.fullPlayerAsTab.value && nav.canPop()) {
            nav.pop(); // Close the full player
          }
          // The book details page should already be showing the updated "Completed" status
          // due to the global completion status stream we set up
        }
      } else {
        // If unfinishing, apply the user's choice locally
        if (unfinishChoice != null) {
          // Seeking to chosen position
          try {
            // Wait a bit for the API call to complete
            await Future.delayed(const Duration(milliseconds: 500));

            // Seek to the saved position (the one we actually sent to the server)
            // Use seekGlobal for multi-track books to properly map position across tracks
            await playback.seekGlobal(unfinishChoice, reportNow: true);

            // Resume playback if it was playing before
            if (wasPlaying && mounted) {
              // Temporarily disable sync to avoid overriding our preserved position
              await playback.resume(skipSync: true, context: context);
              // Resumed playback at saved position
            }

            // Push the position to server after a delay to ensure it's preserved
            Future.delayed(const Duration(seconds: 1), () async {
              if (!mounted) return;
              try {
                // Pushing position to server after unfinish
                await playback.reportProgressNow();
              } catch (e) {
                // Error pushing position to server
              }
            });
          } catch (e) {
            // Error seeking to saved position
          }
        }

        // Show feedback for unmarking as finished
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Book marked as unread'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
    } catch (e) {
      // Error toggling completion

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to update book status: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _addBookmark(
    BuildContext context,
    PlaybackRepository playback,
  ) async {
    final np = playback.nowPlaying;
    final globalPos = playback.globalBookPosition;
    if (np == null || globalPos == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Start playback to add a bookmark.')),
      );
      return;
    }
    final metrics = playback.currentChapterProgress;
    final chapterTitle =
        metrics?.title ??
        (metrics != null ? 'Chapter ${metrics.index + 1}' : null);
    try {
      await PlaybackJournalService.instance.addBookmark(
        libraryItemId: np.libraryItemId,
        bookTitle: np.title,
        positionMs: globalPos.inMilliseconds,
        chapterTitle: chapterTitle,
        chapterIndex: metrics?.index,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Bookmark saved')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to save bookmark: $e')));
    }
  }

  Future<void> _openHistorySheet(
    BuildContext context,
    PlaybackRepository playback,
  ) async {
    final np = playback.nowPlaying;
    if (np == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audiobook is playing right now.')),
      );
      return;
    }
    final entry = await showModalBottomSheet<PlaybackHistoryEntry>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder:
          (_) => PlayHistorySheet(
            libraryItemId: np.libraryItemId,
            bookTitle: np.title,
          ),
    );
    if (entry == null) return;
    if (!mounted) return;
    final confirmed = await _confirmPositionJump(
      context,
      entry.chapterTitle ?? np.title,
      entry.position,
    );
    if (!confirmed) return;
    await playback.seekGlobal(entry.position, reportNow: true);
    await playback.player.play();
  }

  Future<void> _openBookmarksSheet(
    BuildContext context,
    PlaybackRepository playback,
  ) async {
    final np = playback.nowPlaying;
    if (np == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No audiobook is playing right now.')),
      );
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder:
          (_) => BookmarksSheet(
            libraryItemId: np.libraryItemId,
            bookTitle: np.title,
            playback: playback,
          ),
    );
  }

  Future<bool> _confirmPositionJump(
    BuildContext context,
    String title,
    Duration position,
  ) async {
    final text = Theme.of(context).textTheme;
    final cs = Theme.of(context).colorScheme;
    final result = await showDialog<bool>(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: Text(
              'Resume from bookmark?',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            content: Text(
              'Jump to "$title" at ${_fmt(position)}?',
              style: text.bodyMedium,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(
                  backgroundColor: cs.primary,
                  foregroundColor: cs.onPrimary,
                ),
                child: const Text('Resume'),
              ),
            ],
          ),
    );
    return result ?? false;
  }

  Future<bool> _showMarkAsFinishedDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              'Mark as Finished',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            content: Text(
              'Are you sure you want to mark this book as finished? This will stop playback and return you to the book details.',
              style: text.bodyMedium,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Mark as Finished'),
              ),
            ],
          ),
    );

    return confirmed ?? false;
  }

  Future<Duration?> _showMarkAsUnfinishedDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final playback = ServicesScope.of(context).services.playback;
    final np = playback.nowPlaying;
    if (np == null) return null;

    // Get current position from server (more reliable than local player position)
    final currentPositionSeconds = await playback.fetchServerProgress(
      np.libraryItemId,
    );
    final currentPosition =
        currentPositionSeconds != null
            ? Duration(seconds: currentPositionSeconds.round())
            : playback.player.position;
    final positionText = _formatDuration(currentPosition);

    if (!mounted) return null;
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              'Mark as Unfinished',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Are you sure you want to mark this book as unfinished?',
                  style: text.bodyMedium,
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: cs.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: cs.primary.withOpacity(0.3),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.access_time_rounded,
                        size: 16,
                        color: cs.onPrimaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Current position: $positionText',
                        style: text.bodyMedium?.copyWith(
                          color: cs.onPrimaryContainer,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'This position will be preserved.',
                  style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: cs.onSurfaceVariant),
                ),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Mark as Unfinished'),
              ),
            ],
          ),
    );
    if (confirmed != true) return null;

    if (!mounted) return null;
    // Second choice: resume or restart
    final choice = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              'Choose where to resume',
              style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600),
            ),
            content: Text(
              'Resume from saved position or start from the beginning.',
              style: text.bodyMedium,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop('cancel'),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.of(context).pop('restart'),
                child: const Text('Start from beginning'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop('resume'),
                child: Text('Return to $positionText'),
              ),
            ],
          ),
    );

    if (choice == 'restart') return Duration.zero;
    if (choice == 'resume') return currentPosition;
    return null;
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours}h ${minutes}m ${seconds}s';
    } else if (minutes > 0) {
      return '${minutes}m ${seconds}s';
    } else {
      return '${seconds}s';
    }
  }

  Future<void> _markBookAsFinished(
    String libraryItemId,
    bool finished, {
    double? overrideCurrentTimeSeconds,
  }) async {
    final playback = ServicesScope.of(context).services.playback;
    final api = ServicesScope.of(context).services.auth.api;

    // Prepare the request body
    Map<String, dynamic> requestBody = {'isFinished': finished};

    // If unfinishing, include current progress to preserve position
    if (!finished) {
      // Get position from server (more reliable than local player position)
      double? currentPositionSeconds = await playback.fetchServerProgress(
        libraryItemId,
      );
      if (overrideCurrentTimeSeconds != null) {
        currentPositionSeconds = overrideCurrentTimeSeconds;
      }
      final currentTimeSeconds =
          currentPositionSeconds ??
          playback.player.position.inSeconds.toDouble();

      if (currentTimeSeconds > 0) {
        requestBody['currentTime'] = currentTimeSeconds;

        // Include duration and progress like regular progress updates
        final totalDuration = playback.totalBookDuration;
        if (totalDuration != null && totalDuration.inSeconds > 0) {
          final totalSeconds = totalDuration.inSeconds.toDouble();
          requestBody['duration'] = totalSeconds;
          requestBody['progress'] = (currentTimeSeconds / totalSeconds).clamp(
            0.0,
            1.0,
          );
          // Including full progress
        } else {
          // Including currentTime to preserve position
        }
      }
    }

    // Log the API request for troubleshooting
    // API Request for updating progress

    try {
      final response = await api.request(
        'PATCH',
        '/api/me/progress/$libraryItemId',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );

      // API Response received

      if (response.statusCode == 200 || response.statusCode == 204) {
        // Successfully updated book completion status
      } else {
        throw Exception(
          'Server returned ${response.statusCode}: ${response.body}',
        );
      }
    } catch (e) {
      // API Error
      rethrow;
    }
  }

  Future<void> _showChaptersSheet(
    BuildContext context,
    PlaybackRepository playback,
    NowPlaying np,
  ) async {
    final chapters = np.chapters;
    if (chapters.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No chapters available')));
      return;
    }

    // Determine the current chapter index once when opening
    final globalTotal = playback.totalBookDuration;
    final useGlobal =
        _dualProgressEnabled &&
        globalTotal != null &&
        globalTotal > Duration.zero;
    final globalPos =
        useGlobal
            ? (playback.globalBookPosition ?? Duration.zero)
            : playback.player.position;

    int currentIdx = 0;
    for (int i = 0; i < chapters.length; i++) {
      if (globalPos >= chapters[i].start) {
        currentIdx = i;
      } else {
        break;
      }
    }

    // Create a ScrollController to auto-scroll to current chapter
    final scrollController = ScrollController();

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) {
        // Auto-scroll to current chapter after the sheet is built
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scrollController.hasClients) {
            // Estimate item height (approximately 72px per item including separator)
            final estimatedItemHeight = 72.0;
            final targetOffset = currentIdx * estimatedItemHeight;
            scrollController.animateTo(
              targetOffset.clamp(
                0.0,
                scrollController.position.maxScrollExtent,
              ),
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).colorScheme.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
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
                child: ValueListenableBuilder<Duration>(
                  valueListenable: playback.currentPosition,
                  builder: (_, pos, __) {
                    final currentGlobalPos =
                        useGlobal
                            ? (playback.globalBookPosition ?? Duration.zero)
                            : pos;
                    int liveIdx = 0;
                    for (int i = 0; i < chapters.length; i++) {
                      if (currentGlobalPos >= chapters[i].start) {
                        liveIdx = i;
                      } else {
                        break;
                      }
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                      itemCount: chapters.length,
                      separatorBuilder:
                          (_, __) => Divider(
                            height: 1,
                            color: Theme.of(
                              ctx,
                            ).colorScheme.outline.withOpacity(0.2),
                          ),
                      itemBuilder: (_, i) {
                        final c = chapters[i];
                        final isCurrent = i == liveIdx;
                        return ListTile(
                          dense: false,
                          contentPadding: const EdgeInsets.symmetric(
                            vertical: 8,
                          ),
                          title: Text(
                            c.title.isEmpty ? 'Chapter ${i + 1}' : c.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(ctx).textTheme.bodyLarge?.copyWith(
                              fontWeight:
                                  isCurrent ? FontWeight.w700 : FontWeight.w500,
                              color:
                                  isCurrent
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(ctx).colorScheme.onSurface,
                            ),
                          ),
                          // Show raw time for debugging when long-pressing a row
                          onLongPress: () {
                            // Chapter tap
                          },
                          subtitle: Text(
                            _fmt(c.start),
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              color:
                                  isCurrent
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(
                                        ctx,
                                      ).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          leading: Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color:
                                  isCurrent
                                      ? Theme.of(ctx).colorScheme.primary
                                      : Theme.of(
                                        ctx,
                                      ).colorScheme.primaryContainer,
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Center(
                              child: Text(
                                '${i + 1}',
                                style: Theme.of(
                                  ctx,
                                ).textTheme.labelLarge?.copyWith(
                                  color:
                                      isCurrent
                                          ? Theme.of(ctx).colorScheme.onPrimary
                                          : Theme.of(
                                            ctx,
                                          ).colorScheme.onPrimaryContainer,
                                  fontWeight:
                                      isCurrent
                                          ? FontWeight.w800
                                          : FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          trailing:
                              isCurrent
                                  ? Icon(
                                    Icons.play_arrow_rounded,
                                    color: Theme.of(ctx).colorScheme.primary,
                                  )
                                  : null,
                          onTap: () async {
                            SleepTimerService.instance
                                .cancelChapterSleepIfActive();
                            Navigator.of(ctx).pop();
                            await ServicesScope.of(
                              context,
                            ).services.playback.seek(c.start, reportNow: true);
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
    ).then((_) {
      // Dispose scroll controller when sheet is closed
      scrollController.dispose();
    });
  }

  Future<void> _showSleepTimerSheet(BuildContext context, NowPlaying np) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final timer = SleepTimerService.instance;
    final supportsChapterSleep = np.chapters.length > 1;

    Duration? selected;
    bool eoc = timer.isChapterMode && supportsChapterSleep;

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
                labelPadding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                selected: sel,
                onSelected: (_) {
                  setState(() {
                    selected = d;
                    eoc = false;
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
                      Text(
                        'Sleep timer',
                        style: text.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
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
                      if (supportsChapterSleep)
                        ChoiceChip(
                          label: Text(
                            'Chapter end',
                            style: text.labelLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          labelPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                          selected: eoc,
                          onSelected: (_) {
                            setState(() {
                              eoc = true;
                              selected = null;
                            });
                          },
                        ),
                    ],
                  ),
                  if (supportsChapterSleep)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        'Stops playback when the current chapter ends. '
                        'Changing chapters will cancel the sleep timer, but quick seek buttons will not.',
                        style: text.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  StreamBuilder<Duration?>(
                    stream: timer.remainingTimeStream,
                    initialData: timer.remainingTime,
                    builder: (ctx, snap) {
                      final rem = snap.data;
                      if (!timer.isActive || rem == null) {
                        return const SizedBox.shrink();
                      }
                      final modeLabel =
                          timer.isChapterMode
                              ? 'Until chapter ends'
                              : 'Time remaining';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.timer_rounded,
                              size: 18,
                              color: cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '$modeLabel: ${fmt(rem)}',
                              style: text.bodyMedium?.copyWith(
                                color: cs.onSurfaceVariant,
                              ),
                            ),
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
                          onPressed:
                              (selected == null && !eoc)
                                  ? null
                                  : () async {
                                    var started = true;
                                    if (eoc) {
                                      started =
                                          timer.startSleepUntilChapterEnd();
                                      if (!started) {
                                        ScaffoldMessenger.of(
                                          context,
                                        ).showSnackBar(
                                          const SnackBar(
                                            content: Text(
                                              'Unable to start chapter sleep. Try again later.',
                                            ),
                                          ),
                                        );
                                      }
                                    } else if (selected != null) {
                                      timer.startTimer(selected!);
                                    }
                                    if (started) {
                                      Navigator.of(ctx).pop();
                                    }
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
                  ),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;

    return ValueListenableBuilder<bool>(
      valueListenable: UiPrefs.playerGradientBackground,
      builder: (_, gradientEnabled, __) {
        return DecoratedBox(
          decoration: _playerBackgroundDecoration(
            gradientEnabled,
            cs,
            brightness,
            palettePrimary: _palettePrimary,
            paletteSecondary: _paletteSecondary,
          ),
          child: PopScope(
            canPop: false,
            onPopInvoked: (didPop) {
              if (!didPop) {
                // Only pop when we're actually presented on a route (modal
                // mode). In tab mode the outer MainScaffold handles back.
                final nav = Navigator.of(context);
                if (nav.canPop()) nav.pop();
              }
            },
            child: Scaffold(
              backgroundColor: Colors.transparent,
              body: SafeArea(
                child: StreamBuilder<NowPlaying?>(
                  stream: playback.nowPlayingStream,
                  initialData: playback.nowPlaying,
                  builder: (context, snap) {
                    final np = snap.data;
                    if (np == null) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            if (_warmLoadInProgress) ...[
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(
                                'Loading your last book…',
                                style: text.titleMedium?.copyWith(
                                  color: cs.onSurfaceVariant,
                                ),
                              ),
                            ] else ...[
                              Icon(
                                Icons.headphones_rounded,
                                size: 48,
                                color: cs.onSurfaceVariant,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'Nothing playing',
                                style: text.titleMedium?.copyWith(
                                  color: cs.onSurface,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 32,
                                ),
                                child: Text(
                                  'Pick a book from your library, or tap below to resume the last one you were listening to.',
                                  textAlign: TextAlign.center,
                                  style: text.bodyMedium?.copyWith(
                                    color: cs.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                onPressed:
                                    () =>
                                        _restoreNowPlayingIfNeeded(force: true),
                                icon: const Icon(Icons.play_arrow_rounded),
                                label: const Text('Resume last book'),
                              ),
                              if (_warmLoadError != null) ...[
                                const SizedBox(height: 12),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 32,
                                  ),
                                  child: Text(
                                    'Couldn\'t load: $_warmLoadError',
                                    textAlign: TextAlign.center,
                                    style: text.bodySmall?.copyWith(
                                      color: cs.error,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ],
                        ),
                      );
                    }

                    _schedulePaletteUpdate(np);
                    final totalDuration =
                        np.durationSec != null && np.durationSec! > 0
                            ? Duration(seconds: np.durationSec!.round())
                            : null;

                    return Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                      child: Column(
                        children: [
                          const SizedBox(height: 2),

                            // ARTWORK + TITLE
                            Expanded(
                              child: LayoutBuilder(
                                builder: (context, sectionConstraints) {
                                  final metadataLineCount =
                                      _estimatedMetadataLineCount(np);
                                  return RepaintBoundary(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        8,
                                        8,
                                        8,
                                        6,
                                      ),
                                      child: Column(
                                        children: [
                                          Expanded(
                                            child: LayoutBuilder(
                                              builder: (
                                                context,
                                                coverConstraints,
                                              ) {
                                                const coverSize =
                                                    PlayerCoverSize.small;
                                                final dims =
                                                    _coverDimensionsForSize(
                                                      context,
                                                      coverSize,
                                                      availableHeight:
                                                          coverConstraints
                                                              .maxHeight,
                                                      metadataLineCount: 0,
                                                    );
                                                return Align(
                                                  alignment: Alignment.topCenter,
                                                  child: _buildHeroArtwork(
                                                    context: context,
                                                    playback: playback,
                                                    np: np,
                                                    dims: dims,
                                                    cs: cs,
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          const SizedBox(height: 1),
                                          _buildHeroMetadata(
                                            context: context,
                                            text: text,
                                            cs: cs,
                                            playback: playback,
                                            np: np,
                                            totalDuration: totalDuration,
                                            embedded: true,
                                          ),
                                          const SizedBox(height: 3),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),


                            // POSITION + SLIDER
                            Padding(
                              padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
                              child: ValueListenableBuilder<Duration>(
                            valueListenable: playback.currentPosition,
                            builder: (_, pos, __) {
                              final globalTotal = playback.totalBookDuration;
                              final hasGlobal =
                                  _dualProgressEnabled &&
                                  globalTotal != null &&
                                  globalTotal > Duration.zero;
                              final chapterMetrics =
                                  hasGlobal
                                      ? playback.currentChapterProgress
                                      : null;
                              final chapters =
                                  playback.nowPlaying?.chapters ??
                                  const <Chapter>[];
                              final preferChapter =
                                  hasGlobal &&
                                  chapterMetrics != null &&
                                  _progressPrimary == ProgressPrimary.chapter;

                              Widget progressContent;
                              if (preferChapter) {
                                final globalPos =
                                    playback.globalBookPosition ?? pos;
                                progressContent = Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildChapterProgressPrimary(
                                      context: context,
                                      text: text,
                                      cs: cs,
                                      playback: playback,
                                      metrics: chapterMetrics!,
                                    ),
                                    if (globalTotal != null &&
                                        chapters.length > 1) ...[
                                      const SizedBox(height: 6),
                                      _buildBookDetailStyleChapterTimeline(
                                        text: text,
                                        cs: cs,
                                        position: globalPos,
                                        total: globalTotal,
                                        chapters: chapters,
                                        metrics: chapterMetrics,
                                      ),
                                    ],
                                  ],
                                );
                              } else if (hasGlobal) {
                                final globalPos =
                                    playback.globalBookPosition ??
                                    Duration.zero;
                                progressContent = Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    _buildBookProgressSection(
                                      context: context,
                                      text: text,
                                      cs: cs,
                                      playback: playback,
                                      position: globalPos,
                                      total: globalTotal!,
                                      isPrimary: true,
                                      chapters: chapters,
                                    ),
                                    if (chapters.length > 1) ...[
                                      const SizedBox(height: 6),
                                      _buildBookDetailStyleChapterTimeline(
                                        text: text,
                                        cs: cs,
                                        position: globalPos,
                                        total: globalTotal,
                                        chapters: chapters,
                                        metrics: chapterMetrics,
                                      ),
                                    ],
                                  ],
                                );
                              } else {
                                final total =
                                    playback.player.duration ?? Duration.zero;
                                progressContent = _buildTrackProgressFallback(
                                  context: context,
                                  cs: cs,
                                  text: text,
                                  playback: playback,
                                  total: total,
                                  position: pos,
                                );
                              }

                              return Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  12,
                                  8,
                                  12,
                                  4,
                                ),
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Row(
                                      mainAxisAlignment:
                                          MainAxisAlignment.spaceBetween,
                                      children: [
                                        Text(
                                          preferChapter
                                              ? 'CHAPTER PROGRESS'
                                              : 'BOOK PROGRESS',
                                          style: text.labelSmall?.copyWith(
                                            letterSpacing: 0.8,
                                            color: cs.onSurfaceVariant
                                                .withOpacity(0.6),
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                        GestureDetector(
                                          onTap:
                                              hasGlobal
                                                  ? () {
                                                    final next =
                                                        _progressPrimary ==
                                                                ProgressPrimary
                                                                    .chapter
                                                            ? ProgressPrimary
                                                                .book
                                                            : ProgressPrimary
                                                                .chapter;
                                                    UiPrefs.setProgressPrimary(
                                                      next,
                                                    );
                                                  }
                                                  : null,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 5,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cs.primary.withOpacity(
                                                0.12,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(999),
                                            ),
                                            child: Text(
                                              preferChapter ? 'Chapter' : 'Book',
                                              style: text.labelSmall?.copyWith(
                                                color: cs.primary,
                                                fontWeight: FontWeight.w700,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                    const SizedBox(height: 10),
                                    progressContent,
                                  ],
                                ),
                              );
                            },
                          ),
                            ),

                            // CONTROLS + CHAPTERS
                            AnimatedBuilder(
                          animation: _controlsAnimation,
                          builder: (context, child) {
                            return Transform.translate(
                              offset: Offset(
                                0,
                                30 * (1 - _controlsAnimation.value),
                              ),
                              child: Opacity(
                                opacity: _controlsAnimation.value,
                                child: RepaintBoundary(
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        4,
                                        6,
                                        4,
                                        UiPrefs.fullPlayerAsTab.value ? 2.4 : 6,
                                      ),
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        12,
                                        4,
                                        12,
                                        UiPrefs.fullPlayerAsTab.value ? 2 : 12,
                                      ),
                                      child: Column(
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                'PLAYBACK',
                                                style: text.labelSmall
                                                    ?.copyWith(
                                                      letterSpacing: 0.8,
                                                      color: cs.onSurfaceVariant
                                                          .withOpacity(0.62),
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                              ),
                                              const Spacer(),
                                              _InfoPill(
                                                icon: Symbols.auto_stories,
                                                label:
                                                    np.chapters.length > 1
                                                        ? 'Chapter ${(playback.currentChapterProgress?.index ?? 0) + 1}'
                                                        : 'Ready',
                                              ),
                                              const SizedBox(width: 6),
                                              StreamBuilder<bool>(
                                                stream: _getBookCompletionStream(),
                                                initialData: false,
                                                builder: (_, completionSnap) {
                                                  final isCompleted =
                                                      completionSnap.data ??
                                                      false;
                                                  final menuBg =
                                                      gradientEnabled
                                                          ? Color.alphaBlend(
                                                            (_palettePrimary ??
                                                                    cs.primary)
                                                                .withOpacity(
                                                                  0.1,
                                                                ),
                                                            cs.surface,
                                                          )
                                                          : cs.surface;
                                                  return PopupMenuButton<
                                                    _TopMenuAction
                                                  >(
                                                    tooltip: 'More options',
                                                    padding: EdgeInsets.zero,
                                                    child: AppLiquidGlassPill(
                                                      blur: 26,
                                                      opacity:
                                                          Theme.of(context)
                                                                      .brightness ==
                                                                  Brightness
                                                                      .dark
                                                              ? 0.16
                                                              : 0.08,
                                                      tint: Color.alphaBlend(
                                                        Colors.black.withValues(
                                                          alpha: Theme.of(
                                                                        context,
                                                                      ).brightness ==
                                                                      Brightness
                                                                          .dark
                                                                  ? 0.0
                                                                  : 0.04,
                                                        ),
                                                        cs.surface,
                                                      ),
                                                      elevation: 5,
                                                      lightenAmount:
                                                          Theme.of(context)
                                                                      .brightness ==
                                                                  Brightness
                                                                      .dark
                                                              ? null
                                                              : 0.07,
                                                      padding:
                                                          const EdgeInsets.symmetric(
                                                            horizontal: 10,
                                                            vertical: 7,
                                                          ),
                                                      child: Icon(
                                                        Symbols.more_vert,
                                                        size: 16,
                                                        color:
                                                            cs.onSurfaceVariant,
                                                      ),
                                                    ),
                                                    color: menuBg,
                                                    shape: RoundedRectangleBorder(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                            18,
                                                          ),
                                                      side: BorderSide(
                                                        color: cs
                                                            .outlineVariant
                                                            .withOpacity(0.2),
                                                      ),
                                                    ),
                                                    onSelected: (action) {
                                                      switch (action) {
                                                        case _TopMenuAction
                                                            .toggleCompletion:
                                                          _toggleBookCompletion(
                                                            context,
                                                            isCompleted,
                                                          );
                                                          break;
                                                        case _TopMenuAction
                                                            .toggleGradient:
                                                          final next =
                                                              !gradientEnabled;
                                                          UiPrefs.setPlayerGradientBackground(
                                                            next,
                                                          );
                                                          ScaffoldMessenger.of(
                                                            context,
                                                          ).showSnackBar(
                                                            SnackBar(
                                                              content: Text(
                                                                next
                                                                    ? 'Gradient background enabled'
                                                                    : 'Gradient background disabled',
                                                              ),
                                                              duration:
                                                                  const Duration(
                                                                    seconds: 2,
                                                                  ),
                                                            ),
                                                          );
                                                          break;
                                                        case _TopMenuAction
                                                            .toggleChapterizedProgressBar:
                                                          final next =
                                                              !UiPrefs
                                                                  .progressBarChapterized
                                                                  .value;
                                                          UiPrefs.setProgressBarChapterized(
                                                            next,
                                                          );
                                                          ScaffoldMessenger.of(
                                                            context,
                                                          ).showSnackBar(
                                                            SnackBar(
                                                              content: Text(
                                                                next
                                                                    ? 'Chapter indicators enabled'
                                                                    : 'Chapter indicators disabled',
                                                              ),
                                                              duration:
                                                                  const Duration(
                                                                    seconds: 2,
                                                                  ),
                                                            ),
                                                          );
                                                          break;
                                                        case _TopMenuAction
                                                            .cast:
                                                          _showCastingComingSoon(
                                                            context,
                                                          );
                                                          break;
                                                        case _TopMenuAction
                                                            .playHistory:
                                                          _openHistorySheet(
                                                            context,
                                                            playback,
                                                          );
                                                          break;
                                                        case _TopMenuAction
                                                            .bookmarks:
                                                          _openBookmarksSheet(
                                                            context,
                                                            playback,
                                                          );
                                                          break;
                                                      }
                                                    },
                                                    itemBuilder:
                                                        (context) => [
                                                          PopupMenuItem(
                                                            value:
                                                                _TopMenuAction
                                                                    .toggleCompletion,
                                                            child: Row(
                                                              children: [
                                                                Icon(
                                                                  isCompleted
                                                                      ? Icons
                                                                          .undo_rounded
                                                                      : Icons
                                                                          .check_rounded,
                                                                  size: 18,
                                                                  color:
                                                                      cs.primary,
                                                                ),
                                                                const SizedBox(
                                                                  width: 12,
                                                                ),
                                                                Expanded(
                                                                  child: Text(
                                                                    isCompleted
                                                                        ? 'Mark as unfinished'
                                                                        : 'Mark as finished',
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value:
                                                                _TopMenuAction
                                                                    .toggleGradient,
                                                            child: Row(
                                                              children: [
                                                                Icon(
                                                                  gradientEnabled
                                                                      ? Icons
                                                                          .gradient
                                                                      : Icons
                                                                          .gradient_outlined,
                                                                  size: 18,
                                                                  color:
                                                                      cs.primary,
                                                                ),
                                                                const SizedBox(
                                                                  width: 12,
                                                                ),
                                                                Expanded(
                                                                  child: Text(
                                                                    gradientEnabled
                                                                        ? 'Disable gradient background'
                                                                        : 'Enable gradient background',
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value:
                                                                _TopMenuAction
                                                                    .toggleChapterizedProgressBar,
                                                            child: ValueListenableBuilder<
                                                              bool
                                                            >(
                                                              valueListenable:
                                                                  UiPrefs
                                                                      .progressBarChapterized,
                                                              builder: (
                                                                _,
                                                                chapterized,
                                                                __,
                                                              ) {
                                                                return Row(
                                                                  children: [
                                                                    Icon(
                                                                      chapterized
                                                                          ? Icons
                                                                              .linear_scale_rounded
                                                                          : Icons
                                                                              .remove_rounded,
                                                                      size: 18,
                                                                      color:
                                                                          cs.primary,
                                                                    ),
                                                                    const SizedBox(
                                                                      width: 12,
                                                                    ),
                                                                    Expanded(
                                                                      child: Text(
                                                                        chapterized
                                                                            ? 'Progress Bar Chapterized: On'
                                                                            : 'Progress Bar Chapterized: Off',
                                                                      ),
                                                                    ),
                                                                  ],
                                                                );
                                                              },
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value:
                                                                _TopMenuAction
                                                                    .playHistory,
                                                            child: Row(
                                                              children: [
                                                                Icon(
                                                                  Icons
                                                                      .history_rounded,
                                                                  size: 18,
                                                                  color:
                                                                      cs.primary,
                                                                ),
                                                                const SizedBox(
                                                                  width: 12,
                                                                ),
                                                                const Expanded(
                                                                  child: Text(
                                                                    'Play history',
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                          PopupMenuItem(
                                                            value:
                                                                _TopMenuAction
                                                                    .bookmarks,
                                                            child: Row(
                                                              children: [
                                                                Icon(
                                                                  Icons
                                                                      .bookmark_rounded,
                                                                  size: 18,
                                                                  color:
                                                                      cs.primary,
                                                                ),
                                                                const SizedBox(
                                                                  width: 12,
                                                                ),
                                                                const Expanded(
                                                                  child: Text(
                                                                    'Bookmarks',
                                                                  ),
                                                                ),
                                                              ],
                                                            ),
                                                          ),
                                                        ],
                                                  );
                                                },
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 10),
                                        // Large transport controls (Material 3) - single row, auto-sized
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final maxW = constraints.maxWidth;
                                            final tabMode =
                                                UiPrefs
                                                    .fullPlayerAsTab
                                                    .value;
                                            final sizeScale =
                                                tabMode ? 0.85 : 1.0;
                                            double spacing = 8;
                                            double edge = 52 * sizeScale;
                                            double skip = 52 * sizeScale;
                                            double center = 72 * sizeScale;
                                            final needed =
                                                2 * edge +
                                                2 * skip +
                                                center +
                                                4 * spacing;
                                            if (needed > maxW) {
                                              final scale =
                                                  (maxW - 4 * spacing) /
                                                  (2 * edge +
                                                      2 * skip +
                                                      center);
                                              final clamped = scale.clamp(
                                                0.6,
                                                1.0,
                                              );
                                              edge = edge * clamped;
                                              skip = skip * clamped;
                                              center = center * clamped;
                                            }
                                            return Row(
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                _ControlButton(
                                                  tooltip: 'Previous track',
                                                  icon: Symbols.skip_previous,
                                                  size: edge,
                                                  onTap: () async {
                                                    if (playback.hasSmartPrev) {
                                                      await playback
                                                          .smartPrev();
                                                    }
                                                  },
                                                ),
                                                SizedBox(width: spacing),
                                                ValueListenableBuilder<int>(
                                                  valueListenable:
                                                      UiPrefs
                                                          .seekBackwardSeconds,
                                                  builder: (
                                                    context,
                                                    seekSeconds,
                                                    _,
                                                  ) {
                                                    return _ControlButton(
                                                      tooltip:
                                                          'Back ${seekSeconds}s',
                                                      icon: Symbols.replay_30,
                                                      size: skip,
                                                      onTap:
                                                          () => playback
                                                              .nudgeSeconds(
                                                                -seekSeconds,
                                                              ),
                                                    );
                                                  },
                                                ),
                                                SizedBox(width: spacing),
                                                StreamBuilder<bool>(
                                                  stream:
                                                      playback.playingStream,
                                                  initialData:
                                                      playback.player.playing,
                                                  builder: (_, playSnap) {
                                                    final playing =
                                                        playSnap.data ?? false;
                                                    return _ControlButton(
                                                      tooltip:
                                                          playing
                                                              ? 'Pause'
                                                              : 'Play',
                                                      icon:
                                                          playing
                                                              ? Icons.pause_rounded
                                                              : Icons
                                                                  .play_arrow_rounded,
                                                      isPrimary: true,
                                                      size: center,
                                                      highlighted: playing,
                                                      onTap: () async {
                                                        // Check if we have a valid nowPlaying item and it's actually playing
                                                        final hasValidNowPlaying =
                                                            np != null &&
                                                            playing;
                                                        if (hasValidNowPlaying) {
                                                          await playback
                                                              .pause();
                                                        } else {
                                                          // Try to resume first, but if that fails (no current item),
                                                          // warm load the last item and play it
                                                          bool success =
                                                              await playback
                                                                  .resume(
                                                                    context:
                                                                        context,
                                                                  );
                                                          if (!success) {
                                                            try {
                                                              await playback
                                                                  .warmLoadLastItem(
                                                                    playAfterLoad:
                                                                        true,
                                                                  );
                                                            } catch (e) {
                                                              // If warm load fails, show error message
                                                              if (context
                                                                  .mounted) {
                                                                ScaffoldMessenger.of(
                                                                  context,
                                                                ).showSnackBar(
                                                                  const SnackBar(
                                                                    content: Text(
                                                                      'Cannot play: server unavailable and sync progress is required',
                                                                    ),
                                                                    duration:
                                                                        Duration(
                                                                          seconds:
                                                                              4,
                                                                        ),
                                                                  ),
                                                                );
                                                              }
                                                            }
                                                          }
                                                        }
                                                      },
                                                    );
                                                  },
                                                ),
                                                SizedBox(width: spacing),
                                                ValueListenableBuilder<int>(
                                                  valueListenable:
                                                      UiPrefs
                                                          .seekForwardSeconds,
                                                  builder: (
                                                    context,
                                                    seekSeconds,
                                                    _,
                                                  ) {
                                                    return _ControlButton(
                                                      tooltip:
                                                          'Forward ${seekSeconds}s',
                                                      icon: Symbols.forward_30,
                                                      size: skip,
                                                      onTap:
                                                          () => playback
                                                              .nudgeSeconds(
                                                                seekSeconds,
                                                              ),
                                                    );
                                                  },
                                                ),
                                                SizedBox(width: spacing),
                                                _ControlButton(
                                                  tooltip: 'Next track',
                                                  icon: Symbols.skip_next,
                                                  size: edge,
                                                  onTap: () async {
                                                    if (playback.hasSmartNext) {
                                                      await playback
                                                          .smartNext();
                                                    }
                                                  },
                                                ),
                                              ],
                                            );
                                          },
                                        ),

                                        const SizedBox(height: 16),

                                        Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Row(
                                              children: [
                                                Expanded(
                                                  child: _PlayerActionTile(
                                                    icon: _buildChaptersQuickIcon(
                                                      context: context,
                                                      cs: cs,
                                                      totalChapters:
                                                          np.chapters.length,
                                                      currentChapter:
                                                          np.chapters.length > 1
                                                              ? (playback
                                                                          .currentChapterProgress
                                                                          ?.index ??
                                                                      0) +
                                                                  1
                                                              : 1,
                                                    ),
                                                    label: '',
                                                    onTap:
                                                        np.chapters.length > 1
                                                            ? () =>
                                                                _showChaptersSheet(
                                                                  context,
                                                                  playback,
                                                                  np,
                                                                )
                                                            : null,
                                                    tooltip:
                                                        np.chapters.length > 1
                                                            ? 'Open chapters'
                                                            : 'Single chapter – no chapters list',
                                                    enabled:
                                                        np.chapters.length > 1,
                                                    heightScale: 0.58,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child:
                                                      _ChaptersDownloadButton(
                                                        libraryItemId:
                                                            np.libraryItemId,
                                                        episodeId: np.episodeId,
                                                        title: np.title,
                                                        iconOnly: true,
                                                        heightScale: 0.58,
                                                      ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: _SleepQuickAction(
                                                    onTap:
                                                        () =>
                                                            _showSleepTimerSheet(
                                                              context,
                                                              np,
                                                            ),
                                                    heightScale: 0.58,
                                                  ),
                                                ),
                                                const SizedBox(width: 10),
                                                Expanded(
                                                  child: _SpeedQuickAction(
                                                    playback: playback,
                                                    heightScale: 0.58,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ],
                                        ),
                                        // Removed redundant countdown widget (countdown shown on Sleep button only)
                                        ],
                                      ),
                                    ),
                                  ),
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
      },
    );
  }
}

class _CoverIconButton extends StatelessWidget {
  const _CoverIconButton({
    required this.icon,
    required this.onTap,
    required this.tooltip,
    this.iconColor = Colors.white,
    this.label,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String tooltip;
  final Color iconColor;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final hasLabel = label != null && label!.isNotEmpty;
    final child =
        hasLabel
            ? Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 8,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: iconColor),
                  const SizedBox(width: 6),
                  Text(
                    label!,
                    style: TextStyle(
                      color: iconColor,
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.1,
                    ),
                  ),
                ],
              ),
            )
            : SizedBox(
              width: 38,
              height: 38,
              child: Icon(icon, size: 20, color: iconColor),
            );

    final button = ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
        child: Material(
          color: Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: onTap,
            child: child,
          ),
        ),
      ),
    );
    return Tooltip(message: tooltip, child: button);
  }
}

class _GlassPanel extends StatelessWidget {
  const _GlassPanel({
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = 24,
    this.tint,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double borderRadius;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    return AppLiquidGlass(
      blur: 42,
      opacity: isDark ? 0.2 : 0.09,
      borderRadius: BorderRadius.circular(borderRadius),
      tint:
          tint ??
          Color.alphaBlend(
            Colors.black.withValues(alpha: isDark ? 0.0 : 0.05),
            cs.surface,
          ),
      elevation: 16,
      lightenAmount: isDark ? null : 0.08,
      padding: padding,
      child: child,
    );
  }
}

class _InfoPill extends StatelessWidget {
  const _InfoPill({
    required this.icon,
    required this.label,
    this.highlighted = false,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final bool highlighted;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final pill = AppLiquidGlassPill(
      blur: 26,
      opacity:
          highlighted
              ? (isDark ? 0.22 : 0.10)
              : (isDark ? 0.16 : 0.08),
      tint:
          highlighted
              ? Color.alphaBlend(
                cs.primary.withOpacity(isDark ? 0.14 : 0.08),
                cs.surface,
              )
              : Color.alphaBlend(
                Colors.black.withValues(alpha: isDark ? 0.0 : 0.04),
                cs.surface,
              ),
      elevation: highlighted ? 8 : 5,
      lightenAmount: isDark ? null : 0.07,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: 14,
            color: highlighted ? cs.primary : cs.onSurfaceVariant,
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              fontSize: 11.5,
              color: highlighted ? cs.primary : cs.onSurfaceVariant,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.1,
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return pill;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: pill,
      ),
    );
  }
}

/// Button that shows download status for the entire book
class _PlayerActionTile extends StatelessWidget {
  const _PlayerActionTile({
    required this.icon,
    required this.label,
    this.onTap,
    this.tooltip,
    this.enabled = true,
    this.backgroundColor,
    this.foregroundColor,
    this.heightScale = 1.0,
    this.centerLabel,
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool enabled;
  final Color? backgroundColor;
  final Color? foregroundColor;
  final double heightScale;

  /// When non-null, replaces the icon + label column with a single centered
  /// text line (no icon) — used for tiles that show a numeric value only.
  final String? centerLabel;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final clampedScale = heightScale.clamp(0.5, 1.2);
    final radius = BorderRadius.circular(20);
    final tileHeight = 66.0 * clampedScale;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg =
        backgroundColor ??
        Color.alphaBlend(
          cs.surfaceContainerHighest.withOpacity(isDark ? 0.46 : 0.28),
          cs.surface,
        );
    final fg = foregroundColor ?? cs.onSurface;
    final iconColor = enabled ? fg : cs.onSurfaceVariant;

    final tile = SizedBox(
      height: tileHeight,
      child: AppLiquidGlass(
        blur: 28,
        opacity:
            enabled
                ? (isDark ? 0.15 : 0.08)
                : (isDark ? 0.1 : 0.05),
        borderRadius: radius,
        tint: enabled ? bg : bg.withOpacity(0.8),
        elevation: 6,
        lightenAmount: isDark ? null : 0.06,
        padding: EdgeInsets.zero,
        child: Material(
          color: Colors.transparent,
          borderRadius: radius,
          child: InkWell(
            borderRadius: radius,
            onTap: enabled ? onTap : null,
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: 8,
                vertical: 4 * clampedScale,
              ),
              child: centerLabel != null
                  ? Center(
                      child: Text(
                        centerLabel!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: text.titleMedium?.copyWith(
                          color: iconColor,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          fontSize: 16 * clampedScale,
                        ),
                      ),
                    )
                  : Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        SizedBox(
                          width: 24 * clampedScale,
                          height: 24 * clampedScale,
                          child: IconTheme(
                            data: IconThemeData(
                              color: iconColor,
                              size: 20 * clampedScale,
                            ),
                            child: Center(child: icon),
                          ),
                        ),
                        if (label.isNotEmpty) ...[
                          SizedBox(height: 4 * clampedScale),
                          Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: text.labelMedium?.copyWith(
                              color: iconColor,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.1,
                            ),
                          ),
                        ],
                      ],
                    ),
            ),
          ),
        ),
      ),
    );

    final wrapped =
        tooltip != null ? Tooltip(message: tooltip!, child: tile) : tile;
    return Opacity(opacity: enabled ? 1.0 : 0.6, child: wrapped);
  }
}

class _SleepQuickAction extends StatelessWidget {
  const _SleepQuickAction({required this.onTap, this.heightScale = 1.0});

  final VoidCallback onTap;
  final double heightScale;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<Duration?>(
      stream: SleepTimerService.instance.remainingTimeStream,
      initialData: SleepTimerService.instance.remainingTime,
      builder: (ctx, snap) {
        final timer = SleepTimerService.instance;
        final active = timer.isActive;
        final isChapterMode = timer.isChapterMode;
        return _PlayerActionTile(
          icon: Icon(isChapterMode ? Symbols.auto_stories : Symbols.bedtime),
          label: '',
          onTap: onTap,
          tooltip: active ? 'Adjust sleep timer' : 'Set sleep timer',
          backgroundColor: active ? cs.primary : cs.surfaceContainerHighest,
          foregroundColor: active ? cs.onPrimary : cs.onSurface,
          heightScale: heightScale,
        );
      },
    );
  }
}

class _SpeedQuickAction extends StatelessWidget {
  const _SpeedQuickAction({required this.playback, this.heightScale = 1.0});

  final PlaybackRepository playback;
  final double heightScale;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return StreamBuilder<double>(
      stream: playback.player.speedStream,
      initialData: playback.player.speed,
      builder: (_, snap) {
        final cur = snap.data ?? 1.0;
        final isNormal = (cur - 1.0).abs() < 0.001;
        final accentColor = cs.primary;
        return _PlayerActionTile(
          icon: Icon(
            Symbols.speed,
            color: isNormal ? cs.onSurface : accentColor,
          ),
          label: '',
          centerLabel: isNormal ? null : _formatPlaybackSpeedLabel(cur),
          foregroundColor: isNormal ? null : accentColor,
          tooltip: 'Playback speed',
          onTap: () => _showSpeedSheet(context, cur),
          backgroundColor:
              isNormal
                  ? null
                  : Color.alphaBlend(
                    accentColor.withOpacity(0.08),
                    cs.surfaceContainerHighest,
                  ),
          heightScale: heightScale,
        );
      },
    );
  }

  void _showSpeedSheet(BuildContext context, double current) {
    final speeds = PlaybackSpeedService.instance.availableSpeeds;
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      builder: (ctx) {
        return ListView.separated(
          shrinkWrap: true,
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          itemCount: speeds.length,
          separatorBuilder: (_, __) => const SizedBox(height: 4),
          itemBuilder: (_, i) {
            final speed = speeds[i];
            final selected = (current - speed).abs() < 0.001;
            return ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              tileColor:
                  selected ? Theme.of(ctx).colorScheme.primaryContainer : null,
              title: Text('${speed.toStringAsFixed(2)}×'),
              trailing: selected ? const Icon(Icons.check_rounded) : null,
              onTap: () async {
                Navigator.of(ctx).pop();
                await PlaybackSpeedService.instance.setSpeed(speed);
              },
            );
          },
        );
      },
    );
  }
}

class _ChaptersDownloadButton extends StatefulWidget {
  const _ChaptersDownloadButton({
    required this.libraryItemId,
    this.episodeId,
    this.title,
    this.iconOnly = false,
    this.heightScale = 1.0,
  });

  final String libraryItemId;
  final String? episodeId;
  final String? title;
  final bool iconOnly;
  final double heightScale;

  @override
  State<_ChaptersDownloadButton> createState() =>
      _ChaptersDownloadButtonState();
}

class _ChaptersDownloadButtonState extends State<_ChaptersDownloadButton> {
  DownloadsRepository? _downloads;
  StreamSubscription<ItemProgress>? _sub;
  ItemProgress? _snap;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = ServicesScope.of(context).services.downloads;

    if (!identical(repo, _downloads)) {
      _sub?.cancel();
      _downloads = repo;
      _sub = _downloads!
          .watchItemProgress(widget.libraryItemId)
          .listen((p) => setState(() => _snap = p));

      _refreshDownloadStatus();
    }
  }

  Future<void> _refreshDownloadStatus() async {
    if (_downloads == null) return;
    try {
      await _downloads!.refreshItemStatus(widget.libraryItemId);
    } catch (_) {}
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _enqueue() async {
    if (_downloads == null) return;
    try {
      if (_snap != null &&
          (_snap!.status == 'running' || _snap!.status == 'queued')) {
        return;
      }

      final othersActive = await _downloads!.hasActiveOrQueued();
      bool requireCancelOthers = false;
      if (othersActive) {
        try {
          final tracked = await _downloads!.listTrackedItemIds();
          final onlyThis =
              tracked.isNotEmpty &&
              tracked.every((id) => id == widget.libraryItemId);
          if (!onlyThis) requireCancelOthers = true;
        } catch (_) {
          requireCancelOthers = true;
        }
      }

      bool proceed = true;
      bool cancelOthers = false;
      if (requireCancelOthers) {
        if (!mounted) return;
        final ans = await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: const Text('Single download at a time'),
                content: const Text(
                  'Another book is downloading. Cancel it and download this book now?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('No'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Yes, switch downloads'),
                  ),
                ],
              ),
        );
        proceed = ans == true;
        cancelOthers = ans == true;
      }

      if (!proceed) return;

      if (cancelOthers) {
        await _downloads!.cancelAll();
      }

      await _downloads!.enqueueItemDownloads(
        widget.libraryItemId,
        episodeId: widget.episodeId,
        displayTitle: widget.title,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Download started – follow progress from Downloads tab.',
            ),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to start download: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _cancelCurrent() async {
    if (_downloads == null) return;
    try {
      await _downloads!.cancelForItem(widget.libraryItemId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to cancel download: $e'),
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
        );
      }
    }
  }

  Future<void> _removeLocal() async {
    if (_downloads == null) return;
    try {
      await _downloads!.deleteLocal(widget.libraryItemId);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("Couldn't remove local download")),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final snap = _snap;

    Widget iconWidget;
    String label;
    String tooltip;
    Color backgroundColor;
    Color foregroundColor;
    VoidCallback? action;

    if (snap?.status == 'complete') {
      iconWidget = const Icon(Symbols.delete);
      label = 'Offline';
      tooltip = 'Remove download';
      backgroundColor = cs.secondaryContainer;
      foregroundColor = cs.onSecondaryContainer;
      action = () async {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) {
            final dialogCs = Theme.of(dialogContext).colorScheme;
            return AlertDialog(
              title: const Text('Remove Download'),
              content: const Text(
                'Are you sure you want to remove this downloaded book? You will need to download it again to listen offline.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(
                    'Cancel',
                    style: TextStyle(color: dialogCs.onSurfaceVariant),
                  ),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: dialogCs.error,
                    foregroundColor: dialogCs.onError,
                  ),
                  child: const Text('Remove'),
                ),
              ],
            );
          },
        );
        if (confirmed == true && mounted) {
          _removeLocal();
        }
      };
    } else if (snap != null &&
        (snap.status == 'running' || snap.status == 'queued')) {
      iconWidget = SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(
          strokeWidth: 2.5,
          value: snap.status == 'running' ? snap.progress : null,
          valueColor: AlwaysStoppedAnimation<Color>(cs.onPrimary),
          backgroundColor: cs.onPrimary.withOpacity(0.2),
        ),
      );
      label = 'Offline';
      tooltip = snap.status == 'queued' ? 'Download queued' : 'Cancel download';
      backgroundColor = cs.primary;
      foregroundColor = cs.onPrimary;
      action = _cancelCurrent;
    } else {
      iconWidget = const Icon(Symbols.download_for_offline);
      label = 'Offline';
      tooltip = 'Download for offline';
      backgroundColor = cs.surfaceContainerHighest;
      foregroundColor = cs.onSurface;
      action = _enqueue;
    }

    return _PlayerActionTile(
      icon: iconWidget,
      label: widget.iconOnly ? '' : label,
      onTap: action,
      tooltip: tooltip,
      backgroundColor: backgroundColor,
      foregroundColor: foregroundColor,
      heightScale: widget.heightScale,
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
    this.highlighted = false,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  final bool isPrimary;
  final double size;
  final bool isCircular;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final primaryRadius = BorderRadius.circular(22);
    final sideRadius = BorderRadius.circular(16);
    final shape =
        isPrimary
            ? (isCircular
                ? const CircleBorder()
                : RoundedRectangleBorder(borderRadius: primaryRadius))
            : RoundedRectangleBorder(borderRadius: sideRadius);

    final iconSize = isPrimary ? size * 0.52 : size * 0.58;
    final fg = isPrimary ? cs.onPrimary : cs.onSurface;

    final child = SizedBox(
      width: size,
      height: size,
      child: Center(
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 220),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) =>
              ScaleTransition(scale: animation, child: child),
          child: Icon(icon, key: ValueKey(icon), size: iconSize, color: fg),
        ),
      ),
    );

    final Widget button;
    if (isPrimary) {
      button = AnimatedScale(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        scale: highlighted ? 1.04 : 1.0,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: isCircular ? BoxShape.circle : BoxShape.rectangle,
            borderRadius: isCircular ? null : primaryRadius,
            color: cs.primary,
            boxShadow: [
              BoxShadow(
                color: cs.primary.withOpacity(isDark ? 0.45 : 0.32),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            color: Colors.transparent,
            shape: shape,
            child: InkWell(
              customBorder: shape,
              onTap: onTap,
              child: child,
            ),
          ),
        ),
      );
    } else {
      button = Material(
        color: Colors.transparent,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: onTap,
          child: child,
        ),
      );
    }

    return tooltip == null ? button : Tooltip(message: tooltip!, child: button);
  }
}

class _LoopingMarqueeText extends StatefulWidget {
  const _LoopingMarqueeText({
    required this.text,
    required this.style,
    this.gap = 32,
    this.pause = const Duration(milliseconds: 800),
    this.pixelsPerSecond = 36,
  });

  final String text;
  final TextStyle? style;
  final double gap;
  final Duration pause;
  final double pixelsPerSecond;

  @override
  State<_LoopingMarqueeText> createState() => _LoopingMarqueeTextState();
}

class _LoopingMarqueeTextState extends State<_LoopingMarqueeText> {
  final ScrollController _controller = ScrollController();
  bool _shouldScroll = false;
  int _runToken = 0;

  @override
  void initState() {
    super.initState();
    _scheduleMeasureAndStart();
  }

  @override
  void didUpdateWidget(covariant _LoopingMarqueeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text || oldWidget.style != widget.style) {
      _scheduleMeasureAndStart();
    }
  }

  @override
  void dispose() {
    _runToken++;
    _controller.dispose();
    super.dispose();
  }

  void _scheduleMeasureAndStart() {
    _runToken++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final maxExtent = _controller.position.maxScrollExtent;
      final shouldScrollNow = maxExtent > 0.5;
      if (_shouldScroll != shouldScrollNow) {
        setState(() => _shouldScroll = shouldScrollNow);
      }
      if (shouldScrollNow) {
        _startLoop(_runToken);
      } else {
        _controller.jumpTo(0);
      }
    });
  }

  Future<void> _startLoop(int token) async {
    while (mounted && token == _runToken && _controller.hasClients) {
      final maxExtent = _controller.position.maxScrollExtent;
      if (maxExtent <= 0.5) return;

      await Future.delayed(widget.pause);
      if (!mounted || token != _runToken || !_controller.hasClients) return;

      final durationMs = (maxExtent / widget.pixelsPerSecond * 1000)
          .round()
          .clamp(250, 30000);
      await _controller.animateTo(
        maxExtent,
        duration: Duration(milliseconds: durationMs),
        curve: Curves.linear,
      );
      if (!mounted || token != _runToken || !_controller.hasClients) return;
      _controller.jumpTo(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final baseText = Text(
      widget.text,
      style: widget.style,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        return ClipRect(
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            physics: const NeverScrollableScrollPhysics(),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Row(
                children: [
                  baseText,
                  if (_shouldScroll) ...[
                    SizedBox(width: widget.gap),
                    Text(
                      widget.text,
                      style: widget.style,
                      maxLines: 1,
                      softWrap: false,
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ── Sleep-timer arc overlay ──────────────────────────────────────────────────

class _SleepTimerArcPainter extends CustomPainter {
  const _SleepTimerArcPainter({required this.fraction, required this.color});

  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (fraction <= 0) return;

    const strokeWidth = 4.5;
    final center = Offset(size.width / 2, size.height / 2);
    final arcRadius =
        math.min(size.width, size.height) / 2 - strokeWidth / 2 - 1;

    // Faint full-circle track
    canvas.drawCircle(
      center,
      arcRadius,
      Paint()
        ..color = color.withOpacity(0.18)
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth,
    );

    // Remaining arc — starts at top (−π/2), sweeps clockwise
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: arcRadius),
      -math.pi / 2,
      2 * math.pi * fraction,
      false,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SleepTimerArcPainter old) =>
      old.fraction != fraction || old.color != color;
}

/// Shows a circular countdown arc around the album cover art when the sleep
/// timer is active, plus a small badge with the remaining minutes.
class _SleepTimerArcOverlay extends StatelessWidget {
  const _SleepTimerArcOverlay();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Duration?>(
      stream: SleepTimerService.instance.remainingTimeStream,
      initialData: SleepTimerService.instance.remainingTime,
      builder: (ctx, snap) {
        final remaining = snap.data;
        final initial = SleepTimerService.instance.initialDuration;
        if (remaining == null || initial == null || initial == Duration.zero) {
          return const SizedBox.shrink();
        }
        final fraction = (remaining.inMilliseconds / initial.inMilliseconds)
            .clamp(0.0, 1.0);
        final isAlmostDone = remaining.inMinutes < 5 && remaining.inSeconds > 0;
        final arcColor =
            isAlmostDone ? Colors.deepOrange : Colors.orange.shade400;
        final label =
            remaining.inSeconds < 60
                ? '${remaining.inSeconds}s'
                : '${remaining.inMinutes}m';
        return Stack(
          children: [
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SleepTimerArcPainter(
                    fraction: fraction,
                    color: arcColor,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 12,
              left: 12,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: arcColor.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _CoverDims {
  _CoverDims({required this.width, required this.radius});
  final double width;
  final double radius;

  List<BoxShadow> shadows(ColorScheme cs) => [
    BoxShadow(
      color: cs.shadow.withOpacity(0.18),
      blurRadius: 22,
      spreadRadius: 0,
      offset: const Offset(0, 10),
    ),
    BoxShadow(
      color: cs.primary.withOpacity(0.1),
      blurRadius: 30,
      spreadRadius: -2,
      offset: const Offset(0, 12),
    ),
  ];
}
