// lib/ui/player/full_player_page.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/playback_repository.dart';
import '../../core/playback_speed_service.dart';
import '../../core/sleep_timer_service.dart';
import '../../core/ui_prefs.dart';
import '../../core/downloads_repository.dart';
import '../../main.dart'; // ServicesScope
import '../../widgets/audio_waveform.dart';
import '../../widgets/download_button.dart';
import 'dart:async';

enum _TopMenuAction { toggleCompletion, toggleGradient }

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
          // Material Design 3 emphasized easing - optimized for 120Hz displays
          const emphasizedDecelerate = Cubic(0.05, 0.7, 0.1, 1.0);
          const emphasizedAccelerate = Cubic(0.3, 0.0, 0.8, 0.15);
          
          final curve = CurvedAnimation(
            parent: animation,
            curve: emphasizedDecelerate,
            reverseCurve: emphasizedAccelerate,
          );

          // Calculate mini player position (128px from bottom: 60px nav + 68px mini)
          final screenHeight = MediaQuery.of(context).size.height;
          final miniPlayerOffset = 128 / screenHeight;

          return SlideTransition(
            position: Tween<Offset>(
              begin: Offset(0, 1.0 - miniPlayerOffset), // Start from mini player position
              end: Offset.zero,
            ).animate(curve),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 350),
        reverseTransitionDuration: const Duration(milliseconds: 250),
        opaque: true,
        fullscreenDialog: false,
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
  ProgressPrimary _progressPrimary = UiPrefs.progressPrimary.value;
  VoidCallback? _progressPrefListener;
  late AnimationController _contentAnimationController;
  late Animation<double> _coverAnimation;
  late Animation<double> _titleAnimation;
  late Animation<double> _controlsAnimation;

  @override
  void initState() {
    super.initState();
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
  }

  void _setupContentAnimations() {
    _contentAnimationController = AnimationController(
      duration: const Duration(milliseconds: 350),
      vsync: this,
    );

    _coverAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: Curves.easeOut,
    ));

    _titleAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: Curves.easeInOut,
    ));

    _controlsAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(
      parent: _contentAnimationController,
      curve: Curves.easeInOut,
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
    if (_progressPrefListener != null) {
      UiPrefs.progressPrimary.removeListener(_progressPrefListener!);
    }
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
        size: 24,
      );
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: cs.primary.withOpacity(0.3),
          width: 1.5,
        ),
      ),
      child: Text(
        '${current.toStringAsFixed(2)}×',
        style: text.labelLarge?.copyWith(
          color: cs.onPrimaryContainer,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildBookProgressSection({
    required BuildContext context,
    required TextTheme text,
    required ColorScheme cs,
    required PlaybackRepository playback,
    required Duration position,
    required Duration total,
    required bool isPrimary,
  }) {
    final max = total.inMilliseconds.toDouble();
    final sliderMax = max > 0 ? max : 1.0;
    final value = position.inMilliseconds.toDouble().clamp(0.0, sliderMax);
    final remaining = (total - position).isNegative ? Duration.zero : total - position;


    final sliderTheme = SliderTheme.of(context).copyWith(
      trackHeight: isPrimary ? 6 : 4,
      thumbShape: RoundSliderThumbShape(enabledThumbRadius: isPrimary ? 12 : 9),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
      activeTrackColor: cs.primary,
      inactiveTrackColor: cs.surfaceContainerHighest,
      thumbColor: cs.primary,
      overlayColor: cs.primary.withOpacity(isPrimary ? 0.16 : 0.12),
      trackShape: const RoundedRectSliderTrackShape(),
      valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
      valueIndicatorColor: cs.primary,
      valueIndicatorTextStyle: text.labelMedium?.copyWith(
        color: cs.onPrimary,
        fontWeight: FontWeight.w600,
      ),
      showValueIndicator: isPrimary ? ShowValueIndicator.onlyForDiscrete : ShowValueIndicator.never,
    );

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SliderTheme(
            data: sliderTheme,
            child: Slider(
              min: 0.0,
              max: sliderMax,
              value: value,
              onChanged: (v) async {
                await playback.seekGlobal(Duration(milliseconds: v.round()), reportNow: false);
              },
              onChangeEnd: (v) async {
                await playback.seekGlobal(Duration(milliseconds: v.round()), reportNow: true);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(position),
                  style: (isPrimary ? text.labelLarge : text.bodyMedium)?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                StreamBuilder<double>(
                  stream: playback.player.speedStream,
                  initialData: playback.player.speed,
                  builder: (_, speedSnap) {
                    final speed = speedSnap.data ?? 1.0;
                    final adjustedRemaining = speed != 1.0
                        ? Duration(milliseconds: (remaining.inMilliseconds / speed).round())
                        : remaining;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '-${_fmt(adjustedRemaining)}',
                          style: (isPrimary ? text.labelLarge : text.bodyMedium)?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (speed != 1.0 && isPrimary) ...[
                          const SizedBox(height: 2),
                          Text(
                            'at ${speed.toStringAsFixed(2)}× speed',
                            style: text.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
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

    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              'Chapter progress',
              style: text.bodyMedium?.copyWith(
                color: cs.onSurfaceVariant,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 12,
                elevation: 6,
                pressedElevation: 8,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
              overlayColor: cs.primary.withOpacity(0.16),
              trackShape: const RoundedRectSliderTrackShape(),
            ),
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
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  _fmt(metrics.elapsed),
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '-${_fmt(remaining)}',
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
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
                        style: text.labelMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                          fontWeight: FontWeight.w700,
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

  Widget _buildChapterSummaryRow({
    required TextTheme text,
    required ColorScheme cs,
    required ChapterProgressMetrics metrics,
  }) {
    final duration = metrics.duration;
    final elapsed = metrics.elapsed;

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            _chapterDescriptor(metrics),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${_fmt(elapsed)} / ${_fmt(duration)}',
          style: text.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildBookSummaryRow({
    required TextTheme text,
    required ColorScheme cs,
    required Duration position,
    required Duration total,
  }) {
    final max = total.inMilliseconds.toDouble();
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Text(
            'Full book progress',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: text.bodyMedium?.copyWith(
              color: cs.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          '${_fmt(position)} / ${_fmt(total)}',
          style: text.bodyMedium?.copyWith(
            color: cs.onSurfaceVariant,
            fontWeight: FontWeight.w600,
          ),
        ),
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
    final value = position.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0);

    return RepaintBoundary(
      child: Column(
        children: [
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              thumbShape: const RoundSliderThumbShape(
                enabledThumbRadius: 12,
                elevation: 6,
                pressedElevation: 8,
              ),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 24),
              activeTrackColor: cs.primary,
              inactiveTrackColor: cs.surfaceContainerHighest,
              thumbColor: cs.primary,
              overlayColor: cs.primary.withOpacity(0.16),
              trackShape: const RoundedRectSliderTrackShape(),
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
                  _fmt(position),
                  style: text.labelLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                StreamBuilder<double>(
                  stream: playback.player.speedStream,
                  initialData: playback.player.speed,
                  builder: (_, speedSnap) {
                    final speed = speedSnap.data ?? 1.0;
                    final remaining = total - position;
                    if (total == Duration.zero) return const SizedBox.shrink();
                    final adjustedRemaining = speed != 1.0
                        ? Duration(milliseconds: (remaining.inMilliseconds / speed).round())
                        : remaining;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '-${_fmt(adjustedRemaining)}',
                          style: text.labelLarge?.copyWith(
                            color: cs.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (speed != 1.0) ...[
                          const SizedBox(height: 2),
                          Text(
                            'at ${speed.toStringAsFixed(2)}× speed',
                            style: text.labelSmall?.copyWith(
                              color: cs.onSurfaceVariant.withOpacity(0.7),
                              fontWeight: FontWeight.w400,
                            ),
                          ),
                        ],
                      ],
                    );
                  },
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

  Widget _buildPercentCompleteLabel({
    required PlaybackRepository playback,
    required TextTheme text,
    required ColorScheme cs,
  }) {
    return StreamBuilder<Duration>(
      stream: playback.positionStream,
      initialData: playback.player.position,
      builder: (_, __) {
        final total = playback.totalBookDuration;
        final global = playback.globalBookPosition;
        String headline;
        if (total != null && total > Duration.zero && global != null) {
          final percent = (global.inMilliseconds / total.inMilliseconds * 100).clamp(0.0, 100.0);
          headline = '${percent.toStringAsFixed(1)}% complete';
        } else {
          headline = 'Syncing progress…';
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: cs.surfaceContainerHighest.withOpacity(0.85),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: cs.outline.withOpacity(0.08)),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: cs.primary.withOpacity(0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.auto_graph_rounded, size: 18, color: cs.primary),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  headline,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: cs.onSurface,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  BoxDecoration _playerBackgroundDecoration(bool gradientEnabled, ColorScheme cs, Brightness brightness) {
    if (!gradientEnabled) {
      return BoxDecoration(color: cs.surface);
    }
    final colors = brightness == Brightness.dark
        ? [
            Color.alphaBlend(cs.primary.withOpacity(0.15), cs.surface),
            Color.alphaBlend(cs.secondary.withOpacity(0.12), cs.surfaceContainerHighest),
            Colors.black,
          ]
        : [
            Color.alphaBlend(cs.primaryContainer.withOpacity(0.4), Colors.white),
            cs.surface,
            Color.alphaBlend(cs.secondaryContainer.withOpacity(0.25), Colors.white),
          ];
    return BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomRight,
        colors: colors,
      ),
    );
  }

  void _showCastingComingSoon(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Casting support is coming soon.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Widget _buildChaptersQuickIcon(Color fg, Color accent) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(Icons.library_books_rounded, size: 30, color: fg),
        Positioned(
          right: -2,
          bottom: -2,
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: accent,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.list_rounded, size: 12, color: Colors.white),
          ),
        ),
      ],
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

  Future<void> _toggleBookCompletion(BuildContext context, bool isCurrentlyCompleted) async {
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
      await _markBookAsFinished(np.libraryItemId, newCompletionStatus, overrideCurrentTimeSeconds: overrideSeconds);
      
      // Update the global completion status cache and notify all listeners
      await playback.updateBookCompletionStatus(np.libraryItemId, newCompletionStatus);
      
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
        
        // Navigate back to book details page
        if (mounted) {
          Navigator.of(context).pop(); // Close the full player
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
            if (wasPlaying) {
              // Temporarily disable sync to avoid overriding our preserved position
              await playback.resume(skipSync: true, context: context);
              // Resumed playback at saved position
            }

            // Push the position to server after a delay to ensure it's preserved
            Future.delayed(const Duration(seconds: 1), () async {
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

  Future<bool> _showMarkAsFinishedDialog(BuildContext context) async {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
    final currentPositionSeconds = await playback.fetchServerProgress(np.libraryItemId);
    final currentPosition = currentPositionSeconds != null 
        ? Duration(seconds: currentPositionSeconds.round())
        : playback.player.position;
    final positionText = _formatDuration(currentPosition);
    
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
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
              style: text.bodySmall?.copyWith(
                color: cs.onSurfaceVariant,
              ),
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

    // Second choice: resume or restart
    final choice = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
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

  Future<void> _markBookAsFinished(String libraryItemId, bool finished, {double? overrideCurrentTimeSeconds}) async {
    final playback = ServicesScope.of(context).services.playback;
    final api = ServicesScope.of(context).services.auth.api;
    
    // Prepare the request body
    Map<String, dynamic> requestBody = {'isFinished': finished};
    
         // If unfinishing, include current progress to preserve position
         if (!finished) {
           // Get position from server (more reliable than local player position)
           double? currentPositionSeconds = await playback.fetchServerProgress(libraryItemId);
           if (overrideCurrentTimeSeconds != null) {
             currentPositionSeconds = overrideCurrentTimeSeconds;
           }
           final currentTimeSeconds = currentPositionSeconds ?? playback.player.position.inSeconds.toDouble();

           if (currentTimeSeconds > 0) {
             requestBody['currentTime'] = currentTimeSeconds;
             
             // Include duration and progress like regular progress updates
             final totalDuration = playback.totalBookDuration;
             if (totalDuration != null && totalDuration.inSeconds > 0) {
               final totalSeconds = totalDuration.inSeconds.toDouble();
               requestBody['duration'] = totalSeconds;
               requestBody['progress'] = (currentTimeSeconds / totalSeconds).clamp(0.0, 1.0);
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
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No chapters available')),
      );
      return;
    }

    // Determine the current chapter index once when opening
    final globalTotal = playback.totalBookDuration;
    final useGlobal = _dualProgressEnabled && globalTotal != null && globalTotal > Duration.zero;
    final globalPos = useGlobal ? (playback.globalBookPosition ?? Duration.zero) : playback.player.position;
    
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
              targetOffset.clamp(0.0, scrollController.position.maxScrollExtent),
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
                    child: StreamBuilder<Duration>(
                      stream: ServicesScope.of(context).services.playback.positionStream,
                      initialData: ServicesScope.of(context).services.playback.player.position,
                      builder: (_, posSnap) {
                        final pos = posSnap.data ?? Duration.zero;
                        final currentGlobalPos = useGlobal ? (playback.globalBookPosition ?? Duration.zero) : pos;
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
                                // Chapter tap
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
                                SleepTimerService.instance.cancelChapterSleepIfActive();
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
                labelPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                      if (supportsChapterSleep)
                        ChoiceChip(
                          label: Text(
                            'Chapter end',
                            style: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          labelPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
                        style: text.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                      ),
                    ),
                  const SizedBox(height: 8),
                  StreamBuilder<Duration?>(
                    stream: timer.remainingTimeStream,
                    initialData: timer.remainingTime,
                    builder: (ctx, snap) {
                      final rem = snap.data;
                      if (!timer.isActive || rem == null) return const SizedBox.shrink();
                      final modeLabel = timer.isChapterMode ? 'Until chapter ends' : 'Time remaining';
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
                          onPressed: (selected == null && !eoc)
                              ? null
                              : () async {
                                  var started = true;
                                  if (eoc) {
                                    started = timer.startSleepUntilChapterEnd();
                                    if (!started) {
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        const SnackBar(content: Text('Unable to start chapter sleep. Try again later.')),
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
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final text = theme.textTheme;
    final brightness = theme.brightness;

    return ValueListenableBuilder<bool>(
      valueListenable: UiPrefs.playerGradientBackground,
      builder: (_, gradientEnabled, __) {
        return DecoratedBox(
          decoration: _playerBackgroundDecoration(gradientEnabled, cs, brightness),
          child: Scaffold(
            backgroundColor: Colors.transparent,
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
          duration: const Duration(milliseconds: 300), // Buttery snap-back
          curve: const Cubic(0.05, 0.7, 0.1, 1.0), // Material Design 3 emphasized - ultra smooth
          transform: Matrix4.translationValues(0, _dragY, 0)
            ..scale(1.0 - (_dragY * 0.00015).clamp(0.0, 0.06)), // Very subtle scale - premium feel
          child: SafeArea(
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
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text(
                          'Loading...',
                          style: text.titleMedium?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    // Custom App Bar
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          IconButton.filledTonal(
                            onPressed: () => Navigator.of(context).pop(),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                            style: IconButton.styleFrom(
                              backgroundColor: cs.surfaceContainerHighest,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildPercentCompleteLabel(
                              playback: playback,
                              text: text,
                              cs: cs,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                height: 44,
                                child: StreamBuilder<double>(
                                  stream: playback.player.speedStream,
                                  initialData: playback.player.speed,
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
                              ),
                              const SizedBox(width: 4),
                              StreamBuilder<bool>(
                                stream: _getBookCompletionStream(),
                                initialData: false,
                                builder: (_, completionSnap) {
                                  final isCompleted = completionSnap.data ?? false;
                                  return PopupMenuButton<_TopMenuAction>(
                                    tooltip: 'More options',
                                    icon: const Icon(Icons.more_vert_rounded),
                                    onSelected: (action) {
                                      switch (action) {
                                        case _TopMenuAction.toggleCompletion:
                                          _toggleBookCompletion(context, isCompleted);
                                          break;
                                        case _TopMenuAction.toggleGradient:
                                          final next = !gradientEnabled;
                                          UiPrefs.setPlayerGradientBackground(next);
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(
                                              content: Text(
                                                next
                                                    ? 'Gradient background enabled'
                                                    : 'Gradient background disabled',
                                              ),
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                          break;
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      PopupMenuItem(
                                        value: _TopMenuAction.toggleCompletion,
                                        child: Text(
                                          isCompleted ? 'Mark as unfinished' : 'Mark as finished',
                                        ),
                                      ),
                                      PopupMenuItem(
                                        value: _TopMenuAction.toggleGradient,
                                        child: Text(
                                          gradientEnabled
                                              ? 'Disable gradient background'
                                              : 'Enable gradient background',
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // ARTWORK + TITLE
                    Expanded(
                      child: RepaintBoundary(
                        child: SingleChildScrollView(
                          physics: const BouncingScrollPhysics(),
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
                          child: Column(
                            children: [
                            // Cover with enhanced shadow and border - compact size
                            AnimatedBuilder(
                              animation: _coverAnimation,
                              builder: (context, child) {
                                return Transform.translate(
                                  offset: Offset(0, 20 * (1 - _coverAnimation.value)),
                                  child: Opacity(
                                    opacity: _coverAnimation.value,
                                    child: Center(
                                      child: SizedBox(
                                        width: MediaQuery.of(context).size.width * 0.62, // slightly larger cover for visual emphasis
                                        child: Hero(
                                          tag: 'mini-cover-${np.libraryItemId}',
                                          child: Container(
                                            decoration: BoxDecoration(
                                              borderRadius: BorderRadius.circular(24),
                                              boxShadow: [
                                                BoxShadow(
                                                  color: cs.shadow.withOpacity(0.25),
                                                  blurRadius: 24,
                                                  spreadRadius: 2,
                                                  offset: const Offset(0, 8),
                                                ),
                                                BoxShadow(
                                                  color: cs.primary.withOpacity(0.1),
                                                  blurRadius: 40,
                                                  spreadRadius: -4,
                                                  offset: const Offset(0, 12),
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
                                );
                              },
                            ),
                            const SizedBox(height: 16),

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
                                          style: text.headlineMedium?.copyWith(
                                            fontWeight: FontWeight.w800,
                                            height: 1.15,
                                            letterSpacing: -0.5,
                                          ),
                                          maxLines: 3,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (np.author != null && np.author!.isNotEmpty) ...[
                                          const SizedBox(height: 12),
                                          Text(
                                            np.author!,
                                            textAlign: TextAlign.center,
                                            style: text.titleLarge?.copyWith(
                                              color: cs.onSurfaceVariant,
                                              fontWeight: FontWeight.w600,
                                              letterSpacing: 0.15,
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
                              const SizedBox(height: 8),
                              Text(
                                'Narrated by ${np.narrator!}',
                                textAlign: TextAlign.center,
                                style: text.bodyLarge?.copyWith(
                                  color: cs.onSurfaceVariant.withOpacity(0.85),
                                  fontWeight: FontWeight.w500,
                                  fontStyle: FontStyle.italic,
                                  letterSpacing: 0.25,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                            const SizedBox(height: 4), // Reduced padding
                          ],
                          ),
                        ),
                      ),
                    ),

                    // Waveform visualization (only visible when playing and enabled in settings)
                    ValueListenableBuilder<bool>(
                      valueListenable: UiPrefs.waveformAnimationEnabled,
                      builder: (_, waveformEnabled, __) {
                        if (!waveformEnabled) {
                          return const SizedBox(height: 4);
                        }
                        
                        return StreamBuilder<bool>(
                          stream: playback.playingStream,
                          initialData: playback.player.playing,
                          builder: (_, playSnap) {
                            final playing = playSnap.data ?? false;
                            return AnimatedSize(
                              duration: const Duration(milliseconds: 350),
                              curve: Curves.easeInOut,
                              child: playing
                                  ? Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 12),
                                      child: Center(
                                        child: AudioWaveform(
                                          isPlaying: playing,
                                          barCount: 7,
                                          height: 28,
                                          spacing: 3.5,
                                          color: cs.primary.withOpacity(0.8),
                                          animationSpeed: const Duration(milliseconds: 300),
                                        ),
                                      ),
                                    )
                                  : const SizedBox(height: 4),
                            );
                          },
                        );
                      },
                    ),

                    // POSITION + SLIDER - Material Design 3 Enhanced
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: StreamBuilder<Duration>(
                        stream: playback.positionStream,
                        initialData: playback.player.position,
                        builder: (_, posSnap) {
                          final globalTotal = playback.totalBookDuration;
                          final hasGlobal = _dualProgressEnabled && globalTotal != null && globalTotal > Duration.zero;
                          final chapterMetrics = hasGlobal ? playback.currentChapterProgress : null;
                          final preferChapter =
                              hasGlobal && chapterMetrics != null && _progressPrimary == ProgressPrimary.chapter;

                          if (preferChapter) {
                            final globalPos = playback.globalBookPosition ?? Duration.zero;
                            return Column(
                              children: [
                                _buildChapterProgressPrimary(
                                  context: context,
                                  text: text,
                                  cs: cs,
                                  playback: playback,
                                  metrics: chapterMetrics!,
                                ),
                                if (globalTotal != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 12),
                                    child: _buildBookSummaryRow(
                                      text: text,
                                      cs: cs,
                                      position: globalPos,
                                      total: globalTotal,
                                    ),
                                  ),
                              ],
                            );
                          }

                          if (hasGlobal) {
                            final globalPos = playback.globalBookPosition ?? Duration.zero;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _buildBookProgressSection(
                                  context: context,
                                  text: text,
                                  cs: cs,
                                  playback: playback,
                                  position: globalPos,
                                  total: globalTotal!,
                                  isPrimary: true,
                                ),
                                if (chapterMetrics != null)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 8),
                                    child: _buildChapterSummaryRow(
                                      text: text,
                                      cs: cs,
                                      metrics: chapterMetrics,
                                    ),
                                  ),
                              ],
                            );
                          }

                          final total = playback.player.duration ?? Duration.zero;
                          final pos = posSnap.data ?? Duration.zero;
                          return _buildTrackProgressFallback(
                            context: context,
                            cs: cs,
                            text: text,
                            playback: playback,
                            total: total,
                            position: pos,
                          );
                        },
                      ),
                    ),

                    const SizedBox(height: 12),

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
                                                    // Check if we have a valid nowPlaying item and it's actually playing
                                                    final hasValidNowPlaying = np != null && playing;
                                                    if (hasValidNowPlaying) {
                                                      await playback.pause();
                                                    } else {
                                                      // Try to resume first, but if that fails (no current item), 
                                                      // warm load the last item and play it
                                                      bool success = await playback.resume(context: context);
                                                      if (!success) {
                                                        try {
                                                          await playback.warmLoadLastItem(playAfterLoad: true);
                                                        } catch (e) {
                                                          // If warm load fails, show error message
                                                          if (context.mounted) {
                                                            ScaffoldMessenger.of(context).showSnackBar(
                                                              const SnackBar(
                                                                content: Text('Cannot play: server unavailable and sync progress is required'),
                                                                duration: Duration(seconds: 4),
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

                                    const SizedBox(height: 44),

                                    // Quick access controls - four rounded buttons
                                    Row(
                                      children: [
                                        Expanded(
                                          child: _PlayerActionTile(
                                            icon: _buildChaptersQuickIcon(
                                              cs.onPrimaryContainer,
                                              cs.primary,
                                            ),
                                            label: '',
                                            onTap: np.chapters.isEmpty
                                                ? null
                                                : () => _showChaptersSheet(context, playback, np),
                                            tooltip: np.chapters.isEmpty
                                                ? 'No chapters available'
                                                : 'Open chapters',
                                            enabled: np.chapters.isNotEmpty,
                                            backgroundColor: cs.primaryContainer,
                                            foregroundColor: cs.onPrimaryContainer,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _ChaptersDownloadButton(
                                            libraryItemId: np.libraryItemId,
                                            episodeId: np.episodeId,
                                            title: np.title,
                                            iconOnly: true,
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _SleepQuickAction(
                                            onTap: () => _showSleepTimerSheet(context, np),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
                                        Expanded(
                                          child: _PlayerActionTile(
                                            icon: const Icon(Icons.cast_rounded),
                                            label: '',
                                            onTap: () => _showCastingComingSoon(context),
                                            tooltip: 'Casting',
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
                              ),
                            );
                          },
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
  });

  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final String? tooltip;
  final bool enabled;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bg = backgroundColor ?? cs.surfaceContainerHighest;
    final fg = foregroundColor ?? cs.onSurface;
    final radius = BorderRadius.circular(22);

    final tile = Container(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          colors: [
            (backgroundColor ?? cs.secondaryContainer).withOpacity(enabled ? 1.0 : 0.5),
            (backgroundColor ?? cs.primaryContainer).withOpacity(enabled ? 0.85 : 0.4),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.1),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: enabled ? onTap : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconTheme(
                  data: IconThemeData(
                    color: enabled ? fg : cs.onSurfaceVariant,
                    size: 28,
                  ),
                  child: icon,
                ),
                const SizedBox(height: 8),
                if (label.isNotEmpty)
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: text.labelSmall?.copyWith(
                      color: enabled ? fg : cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );

    final wrapped = tooltip != null ? Tooltip(message: tooltip!, child: tile) : tile;
    return Opacity(opacity: enabled ? 1.0 : 0.6, child: wrapped);
  }
}

class _SleepQuickAction extends StatelessWidget {
  const _SleepQuickAction({required this.onTap});

  final VoidCallback onTap;

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
          icon: Icon(isChapterMode ? Icons.menu_book_rounded : Icons.nights_stay_rounded),
          label: '',
          onTap: onTap,
          tooltip: active ? 'Adjust sleep timer' : 'Set sleep timer',
          backgroundColor: active ? cs.primary : cs.surfaceContainerHighest,
          foregroundColor: active ? cs.onPrimary : cs.onSurface,
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
  });

  final String libraryItemId;
  final String? episodeId;
  final String? title;
  final bool iconOnly;

  @override
  State<_ChaptersDownloadButton> createState() => _ChaptersDownloadButtonState();
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
      if (_snap != null && (_snap!.status == 'running' || _snap!.status == 'queued')) {
        return;
      }

      final othersActive = await _downloads!.hasActiveOrQueued();
      bool requireCancelOthers = false;
      if (othersActive) {
        try {
          final tracked = await _downloads!.listTrackedItemIds();
          final onlyThis = tracked.isNotEmpty && tracked.every((id) => id == widget.libraryItemId);
          if (!onlyThis) requireCancelOthers = true;
        } catch (_) {
          requireCancelOthers = true;
        }
      }

      bool proceed = true;
      bool cancelOthers = false;
      if (requireCancelOthers) {
        final ans = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Single download at a time'),
            content: const Text('Another book is downloading. Cancel it and download this book now?'),
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
            content: Text('Download started – follow progress from Downloads tab.'),
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
      iconWidget = const Icon(Icons.delete_outline);
      label = 'Remove';
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
              content: const Text('Are you sure you want to remove this downloaded book? You will need to download it again to listen offline.'),
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
    } else if (snap != null && (snap.status == 'running' || snap.status == 'queued')) {
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
      label = snap.status == 'queued' ? 'Queued' : 'Cancel';
      tooltip = snap.status == 'queued' ? 'Download queued' : 'Cancel download';
      backgroundColor = cs.primary;
      foregroundColor = cs.onPrimary;
      action = _cancelCurrent;
    } else {
      iconWidget = const Icon(Icons.download_rounded);
      label = 'Download';
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
