// lib/ui/player/full_player_page.dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/playback_repository.dart';
import '../../core/playback_speed_service.dart';
import '../../core/sleep_timer_service.dart';
import '../../core/ui_prefs.dart';
import '../../main.dart'; // ServicesScope
import '../../widgets/audio_waveform.dart';

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

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
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
      debugPrint('[MARK_FINISHED] Saved position: ${savedPosition.inSeconds}s, wasPlaying: $wasPlaying');
    }

    try {
      // Log the request for troubleshooting
      debugPrint('[MARK_FINISHED] Toggling book completion: ${np.libraryItemId} -> $newCompletionStatus');
      
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
        debugPrint('[MARK_FINISHED] Book marked as finished, stopping playback and navigating to book details');
        
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
          debugPrint('[MARK_FINISHED] Seeking to chosen position: ${unfinishChoice.inSeconds}s');
          try {
            // Wait a bit for the API call to complete
            await Future.delayed(const Duration(milliseconds: 500));

            // Seek to the saved position (the one we actually sent to the server)
            // Use seekGlobal for multi-track books to properly map position across tracks
            await playback.seekGlobal(unfinishChoice, reportNow: true);

            // Resume playback if it was playing before
            if (wasPlaying) {
              // Temporarily disable sync to avoid overriding our preserved position
              await playback.resume(skipSync: true);
              debugPrint('[MARK_FINISHED] Resumed playback at saved position (sync disabled)');
            }

            // Push the position to server after a delay to ensure it's preserved
            Future.delayed(const Duration(seconds: 1), () async {
              try {
                debugPrint('[MARK_FINISHED] Pushing position to server after unfinish: ${savedPosition?.inSeconds}s');
                await playback.reportProgressNow();
              } catch (e) {
                debugPrint('[MARK_FINISHED] Error pushing position to server: $e');
              }
            });
          } catch (e) {
            debugPrint('[MARK_FINISHED] Error seeking to saved position: $e');
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
      debugPrint('[MARK_FINISHED] Error toggling completion: $e');
      
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
               debugPrint('[MARK_FINISHED] Including full progress: currentTime=${currentTimeSeconds}s, duration=${totalSeconds}s, progress=${requestBody['progress']}');
             } else {
               debugPrint('[MARK_FINISHED] Including currentTime: ${currentTimeSeconds}s to preserve position (no duration available)');
             }
           }
         }
    
    // Log the API request for troubleshooting
    debugPrint('[MARK_FINISHED] API Request: PATCH /api/me/progress/$libraryItemId');
    debugPrint('[MARK_FINISHED] Request body: $requestBody');
    
    try {
      final response = await api.request(
        'PATCH',
        '/api/me/progress/$libraryItemId',
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestBody),
      );
      
      debugPrint('[MARK_FINISHED] API Response: ${response.statusCode} ${response.body}');
      
      if (response.statusCode == 200 || response.statusCode == 204) {
        debugPrint('[MARK_FINISHED] Successfully updated book completion status');
      } else {
        throw Exception('Server returned ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      debugPrint('[MARK_FINISHED] API Error: $e');
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
                          // Mark as finished/unfinished button
                          StreamBuilder<bool>(
                            stream: _getBookCompletionStream(),
                            initialData: false,
                            builder: (_, completionSnap) {
                              final isCompleted = completionSnap.data ?? false;
                              
                              return IconButton.filledTonal(
                                onPressed: () => _toggleBookCompletion(context, isCompleted),
                                icon: Icon(isCompleted 
                                    ? Icons.undo_rounded 
                                    : Icons.check_circle_outline_rounded),
                                tooltip: isCompleted ? 'Mark as unfinished' : 'Mark as finished',
                                style: IconButton.styleFrom(
                                  backgroundColor: isCompleted 
                                      ? cs.errorContainer 
                                      : cs.surfaceContainerHighest,
                                  foregroundColor: isCompleted 
                                      ? cs.onErrorContainer 
                                      : cs.onSurface,
                                ),
                              );
                            },
                          ),
                          const SizedBox(width: 8),
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
                                        width: MediaQuery.of(context).size.width * 0.56, // 56% of screen width - balanced size
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
                          // Prefer global book progress when enabled and available; otherwise fall back to per-track
                          final globalTotal = playback.totalBookDuration;
                          final useGlobal = _dualProgressEnabled && globalTotal != null && globalTotal > Duration.zero;

                          if (useGlobal) {
                            final globalPos = playback.globalBookPosition ?? Duration.zero;
                            final max = globalTotal.inMilliseconds.toDouble();
                            final value = globalPos.inMilliseconds.toDouble().clamp(0.0, max > 0 ? max : 1.0);
                            final progressPercent = max > 0 ? (value / max * 100).clamp(0.0, 100.0) : 0.0;

                            // Determine chapter info for display
                            final np = playback.nowPlaying;
                            int chapterIdx = 0;
                            Duration? chapterStart;
                            Duration? chapterEnd;
                            String? currentChapterTitle;
                            if (np != null && np.chapters.isNotEmpty) {
                              for (int i = 0; i < np.chapters.length; i++) {
                                if (globalPos >= np.chapters[i].start) {
                                  chapterIdx = i;
                                } else {
                                  break;
                                }
                              }
                              final chapter = np.chapters[chapterIdx];
                              currentChapterTitle = chapter.title.isEmpty ? null : chapter.title;
                              chapterStart = chapter.start;
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
                                  // Material Design 3 progress indicator - balanced size
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: Row(
                                      mainAxisAlignment: MainAxisAlignment.center,
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: cs.primaryContainer,
                                            borderRadius: BorderRadius.circular(12),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(
                                                Icons.auto_stories_rounded,
                                                size: 14,
                                                color: cs.onPrimaryContainer,
                                              ),
                                              const SizedBox(width: 6),
                                              Text(
                                                '${progressPercent.toStringAsFixed(1)}% Complete',
                                                style: text.labelMedium?.copyWith(
                                                  color: cs.onPrimaryContainer,
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  // Slider with enhanced Material Design 3 styling
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
                                      valueIndicatorShape: const PaddleSliderValueIndicatorShape(),
                                      valueIndicatorColor: cs.primary,
                                      valueIndicatorTextStyle: text.labelMedium?.copyWith(
                                        color: cs.onPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                      showValueIndicator: ShowValueIndicator.onlyForDiscrete,
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
                                            color: cs.onSurface,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        StreamBuilder<double>(
                                          stream: playback.player.speedStream,
                                          initialData: playback.player.speed,
                                          builder: (_, speedSnap) {
                                            final speed = speedSnap.data ?? 1.0;
                                            final remaining = globalTotal - globalPos;
                                            
                                            // Calculate speed-adjusted time remaining
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
                          final progressPercent = max > 0 ? (value / max * 100).clamp(0.0, 100.0) : 0.0;

                          return RepaintBoundary(
                            child: Column(
                              children: [
                                // Material Design 3 progress indicator - balanced size
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                                        decoration: BoxDecoration(
                                          color: cs.primaryContainer,
                                          borderRadius: BorderRadius.circular(12),
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Icon(
                                              Icons.auto_stories_rounded,
                                              size: 14,
                                              color: cs.onPrimaryContainer,
                                            ),
                                            const SizedBox(width: 6),
                                            Text(
                                              '${progressPercent.toStringAsFixed(1)}% Complete',
                                              style: text.labelMedium?.copyWith(
                                                color: cs.onPrimaryContainer,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
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
                                        color: cs.onSurface,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    StreamBuilder<double>(
                                      stream: playback.player.speedStream,
                                      initialData: playback.player.speed,
                                      builder: (_, speedSnap) {
                                        final speed = speedSnap.data ?? 1.0;
                                        final remaining = total - pos;
                                        
                                        if (total == Duration.zero) {
                                          return const SizedBox.shrink();
                                        }
                                        
                                        // Calculate speed-adjusted time remaining
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
                        },
                      ),
                    ),

                    const SizedBox(height: 12),

                    // Material Design 3 Chapter Name (if available)
                    StreamBuilder<Duration>(
                      stream: playback.positionStream,
                      initialData: playback.player.position,
                      builder: (_, posSnap) {
                        final globalTotal = playback.totalBookDuration;
                        final useGlobal = _dualProgressEnabled && globalTotal != null && globalTotal > Duration.zero;
                        final globalPos = useGlobal ? (playback.globalBookPosition ?? Duration.zero) : (posSnap.data ?? Duration.zero);
                        
                        final np = playback.nowPlaying;
                        if (np == null || np.chapters.isEmpty) {
                          return const SizedBox.shrink();
                        }

                        // Find current chapter
                        int chapterIdx = 0;
                        for (int i = 0; i < np.chapters.length; i++) {
                          if (globalPos >= np.chapters[i].start) {
                            chapterIdx = i;
                          } else {
                            break;
                          }
                        }
                        
                        final currentChapter = np.chapters[chapterIdx];
                        final chapterTitle = currentChapter.title.isEmpty 
                            ? 'Chapter ${chapterIdx + 1}' 
                            : currentChapter.title;

                        return Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: cs.surfaceContainerHighest,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: cs.outlineVariant.withOpacity(0.5),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  Icons.bookmark_rounded,
                                  size: 18,
                                  color: cs.primary,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    chapterTitle,
                                    style: text.bodyMedium?.copyWith(
                                      color: cs.onSurface,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),

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

                                    // Chapters + Sleep controls - compact design
                                    Row(
                                      children: [
                                        Expanded(
                                          child: FilledButton.tonalIcon(
                                            icon: const Icon(Icons.list_alt_rounded, size: 20),
                                            label: const Text('Chapters'),
                                            onPressed: () => _showChaptersSheet(context, playback, np),
                                            style: FilledButton.styleFrom(
                                              padding: const EdgeInsets.symmetric(vertical: 14),
                                              elevation: 1,
                                              shape: RoundedRectangleBorder(
                                                borderRadius: BorderRadius.circular(16),
                                              ),
                                              textStyle: text.labelMedium?.copyWith(
                                                fontWeight: FontWeight.w600,
                                                letterSpacing: 0.3,
                                              ),
                                            ),
                                          ),
                                        ),
                                        const SizedBox(width: 12),
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
                                                icon: Icon(
                                                  active ? Icons.nightlight : Icons.nightlight_round,
                                                  size: 20,
                                                ),
                                                label: Text(label),
                                                onPressed: () => _showSleepTimerSheet(context, np),
                                                style: FilledButton.styleFrom(
                                                  padding: const EdgeInsets.symmetric(vertical: 14),
                                                  elevation: 1,
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius: BorderRadius.circular(16),
                                                  ),
                                                  textStyle: text.labelMedium?.copyWith(
                                                    fontWeight: FontWeight.w600,
                                                    letterSpacing: 0.3,
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
