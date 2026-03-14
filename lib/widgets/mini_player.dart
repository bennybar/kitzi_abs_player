import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/playback_repository.dart';
import '../core/ui_prefs.dart';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';
import '../ui/player/player_visual_cache.dart';
import 'audio_waveform.dart';

class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, this.height = 60});

  final double height;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  Color? _palettePrimary;
  Color? _paletteSecondary;
  String? _paletteCoverUrl;
  bool _paletteLoading = false;
  bool _paletteScheduled = false;

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;
    final brightness = Theme.of(context).brightness;

    return ValueListenableBuilder<bool>(
      valueListenable: UiPrefs.playerGradientBackground,
      builder: (_, gradientEnabled, __) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
              child: DecoratedBox(
                decoration: _miniBackgroundDecoration(
                  gradientEnabled,
                  cs,
                  brightness,
                ),
                child: _buildContent(
                  context,
                  playback,
                  cs,
                  showTopBorder: false,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildContent(
    BuildContext context,
    PlaybackRepository playback,
    ColorScheme cs, {
    bool showTopBorder = true,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () async {
          await FullPlayerPage.openOnce(context);
        },
        child: Container(
          height: widget.height,
          decoration:
              showTopBorder
                  ? BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: cs.outlineVariant.withOpacity(0.3),
                        width: 0.5,
                      ),
                    ),
                  )
                  : null,
          child: StreamBuilder<NowPlaying?>(
            stream: playback.nowPlayingStream,
            initialData: playback.nowPlaying,
            builder: (context, snap) {
              final np = snap.data;
              // Return empty when no content - parent AnimatedSize will collapse this
              if (np == null) {
                return const SizedBox.shrink();
              }

              _schedulePaletteUpdate(np.coverUrl);

              return Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    // Album art with PixelPlay-inspired rounded corners and shadow
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: cs.shadow.withOpacity(0.12),
                            blurRadius: 10,
                            spreadRadius: 0,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Transform.scale(
                          scale: 1.024,
                          child: _MiniCover(
                            url: np.coverUrl,
                            size: widget.height - 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 14),

                    // Title/author with progress (YouTube Music style)
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            np.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(
                              context,
                            ).textTheme.bodyMedium?.copyWith(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: [
                              if (np.author != null && np.author!.isNotEmpty)
                                Expanded(
                                  child: Text(
                                    np.author!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall?.copyWith(
                                      fontSize: 11.5,
                                      color: cs.onSurfaceVariant,
                                    ),
                                  ),
                                ),
                              StreamBuilder<Duration>(
                                stream: playback.positionStream,
                                initialData: playback.player.position,
                                builder: (_, posSnap) {
                                  // Use total book progress instead of current track
                                  final globalTotal =
                                      playback.totalBookDuration;
                                  final globalPos = playback.globalBookPosition;

                                  // Prefer global book progress if available, otherwise use current track
                                  final position =
                                      globalPos ??
                                      (posSnap.data ?? Duration.zero);
                                  final duration = globalTotal;

                                  if (duration == null ||
                                      duration == Duration.zero) {
                                    // Fallback to current track duration if global not available
                                    final trackDuration =
                                        playback.player.duration;
                                    if (trackDuration == null ||
                                        trackDuration == Duration.zero) {
                                      return const SizedBox.shrink();
                                    }
                                    final posStr = _formatTime(
                                      posSnap.data ?? Duration.zero,
                                    );
                                    final durStr = _formatTime(trackDuration);
                                    return Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (np.author != null &&
                                            np.author!.isNotEmpty)
                                          const SizedBox(width: 8),
                                        Text(
                                          '$posStr / $durStr',
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall?.copyWith(
                                            fontSize: 11.5,
                                            color: cs.onSurfaceVariant,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        ValueListenableBuilder<
                                          ProgressSyncStatus
                                        >(
                                          valueListenable:
                                              playback.progressSyncStatus,
                                          builder: (_, status, __) {
                                            final pending = status.pending;
                                            final icon =
                                                pending
                                                    ? Icons.cloud_upload_rounded
                                                    : (status.hasEverSynced
                                                        ? Icons
                                                            .cloud_done_rounded
                                                        : Icons
                                                            .cloud_off_rounded);
                                            final color =
                                                pending
                                                    ? cs.tertiary
                                                    : cs.onSurfaceVariant;
                                            final tooltip =
                                                pending
                                                    ? 'Progress pending sync'
                                                    : (status.hasEverSynced
                                                        ? 'Progress synced'
                                                        : 'Progress not synced yet');
                                            return Tooltip(
                                              message: tooltip,
                                              child: Icon(
                                                icon,
                                                size: 12,
                                                color: color,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    );
                                  }

                                  final posStr = _formatTime(position);
                                  final durStr = _formatTime(duration);

                                  return Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (np.author != null &&
                                          np.author!.isNotEmpty)
                                        const SizedBox(width: 8),
                                      Text(
                                        '$posStr / $durStr',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.bodySmall?.copyWith(
                                          fontSize: 11.5,
                                          color: cs.onSurfaceVariant,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      ValueListenableBuilder<
                                        ProgressSyncStatus
                                      >(
                                        valueListenable:
                                            playback.progressSyncStatus,
                                        builder: (_, status, __) {
                                          final pending = status.pending;
                                          final icon =
                                              pending
                                                  ? Icons.cloud_upload_rounded
                                                  : (status.hasEverSynced
                                                      ? Icons.cloud_done_rounded
                                                      : Icons
                                                          .cloud_off_rounded);
                                          final color =
                                              pending
                                                  ? cs.tertiary
                                                  : cs.onSurfaceVariant;
                                          final tooltip =
                                              pending
                                                  ? 'Progress pending sync'
                                                  : (status.hasEverSynced
                                                      ? 'Progress synced'
                                                      : 'Progress not synced yet');
                                          return Tooltip(
                                            message: tooltip,
                                            child: Icon(
                                              icon,
                                              size: 12,
                                              color: color,
                                            ),
                                          );
                                        },
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
                    const SizedBox(width: 10),

                    // 10 seconds rewind button - PixelPlay-inspired Material 3 style
                    Material(
                      color: cs.surfaceContainerHighest.withOpacity(0.42),
                      borderRadius: BorderRadius.circular(18),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(18),
                        onTap: () async {
                          await playback.nudgeSeconds(-10);
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
                          child: Icon(
                            Icons.replay_10,
                            size: 20,
                            color: cs.onSurface,
                          ),
                        ),
                      ),
                    ),

                    const SizedBox(width: 10),

                    // Play/Pause button - PixelPlay-inspired with primary color
                    StreamBuilder<bool>(
                      stream: playback.playingStream,
                      initialData: playback.player.playing,
                      builder: (_, playSnap) {
                        final playing = playSnap.data ?? false;
                        // Ensure we have a valid nowPlaying item and it's actually playing
                        final hasValidNowPlaying = np != null && playing;
                        return AnimatedScale(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOutCubic,
                          scale: hasValidNowPlaying ? 1.02 : 1.0,
                          child: Material(
                            color:
                                hasValidNowPlaying
                                    ? Color.alphaBlend(
                                      cs.primary.withOpacity(0.92),
                                      cs.surface,
                                    )
                                    : cs.surfaceContainerHighest.withOpacity(
                                      0.5,
                                    ),
                            borderRadius: BorderRadius.circular(22),
                            elevation: hasValidNowPlaying ? 3 : 0,
                            shadowColor:
                                hasValidNowPlaying
                                    ? cs.primary.withOpacity(0.22)
                                    : Colors.transparent,
                            child: InkWell(
                              borderRadius: BorderRadius.circular(22),
                              onTap: () async {
                                // Button pressed
                                if (hasValidNowPlaying) {
                                  // Pausing playback
                                  await playback.pause();
                                  // Don't open full player on pause
                                } else {
                                  // Attempting to resume/play
                                  // Try to resume first, but if that fails (no current item),
                                  // warm load the last item and play it
                                  bool success = await playback.resume(
                                    context: context,
                                  );
                                  // Resume result
                                  if (!success) {
                                    try {
                                      // Resume failed, trying warmLoadLastItem
                                      await playback.warmLoadLastItem(
                                        playAfterLoad: true,
                                      );
                                      success =
                                          true; // Consider warm load a success
                                      // WarmLoadLastItem succeeded
                                    } catch (e) {
                                      // WarmLoadLastItem failed
                                      success = false;
                                    }
                                  }

                                  if (!success && context.mounted) {
                                    // Both resume and warmLoad failed, showing error
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(
                                        content: Text(
                                          'Cannot play: server unavailable and sync progress is required',
                                        ),
                                        duration: Duration(seconds: 4),
                                      ),
                                    );
                                  } else if (success && context.mounted) {
                                    // Success, opening full player
                                    // Open the full player page when resuming, like the book detail page does
                                    await FullPlayerPage.openOnce(context);
                                  }
                                }
                              },
                              child: Container(
                                width: 44,
                                height: 44,
                                alignment: Alignment.center,
                                child: Icon(
                                  hasValidNowPlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 26,
                                  color:
                                      hasValidNowPlaying
                                          ? cs.onPrimary
                                          : cs.onSurface,
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
    );
  }

  void _schedulePaletteUpdate(String? coverUrl) {
    if (_paletteScheduled || _paletteLoading) return;
    _paletteScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _paletteScheduled = false;
        return;
      }
      try {
        await _maybeUpdatePalette(coverUrl);
      } finally {
        _paletteScheduled = false;
      }
    });
  }

  Future<void> _maybeUpdatePalette(String? coverUrl) async {
    if (coverUrl == null || coverUrl.isEmpty) {
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

    if (_paletteCoverUrl == coverUrl || _paletteLoading) return;

    _paletteLoading = true;
    try {
      final palette = await PlayerVisualCache.paletteForCover(
        coverUrl,
        size: const Size(120, 120),
        maximumColorCount: 10,
      );
      if (!mounted) return;
      setState(() {
        _paletteCoverUrl = coverUrl;
        _palettePrimary = palette.primary;
        _paletteSecondary = palette.secondary ?? palette.primary;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _paletteCoverUrl = coverUrl;
        _palettePrimary = null;
        _paletteSecondary = null;
      });
    } finally {
      _paletteLoading = false;
    }
  }

  BoxDecoration _miniBackgroundDecoration(
    bool gradientEnabled,
    ColorScheme cs,
    Brightness brightness,
  ) {
    if (!gradientEnabled) {
      return BoxDecoration(
        color: cs.surface.withOpacity(
          brightness == Brightness.dark ? 0.8 : 0.88,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: Colors.white.withOpacity(
            brightness == Brightness.dark ? 0.1 : 0.22,
          ),
          width: 0.8,
        ),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.12),
            blurRadius: 18,
            offset: const Offset(0, 8),
          ),
        ],
      );
    }
    final primary = _palettePrimary ?? cs.primary;
    final secondary = _paletteSecondary ?? cs.secondary;
    final colors =
        brightness == Brightness.dark
            ? [
              Color.alphaBlend(
                primary.withOpacity(0.2),
                cs.surface.withOpacity(0.85),
              ),
              Color.alphaBlend(
                secondary.withOpacity(0.16),
                cs.surface.withOpacity(0.8),
              ),
              cs.surface.withOpacity(0.72),
            ]
            : [
              Color.alphaBlend(
                primary.withOpacity(0.18),
                cs.surface.withOpacity(0.94),
              ),
              Color.alphaBlend(
                secondary.withOpacity(0.14),
                cs.surface.withOpacity(0.9),
              ),
              cs.surface.withOpacity(0.82),
            ];
    return BoxDecoration(
      borderRadius: BorderRadius.circular(24),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: colors,
      ),
      border: Border.all(
        color: Colors.white.withOpacity(
          brightness == Brightness.dark ? 0.1 : 0.22,
        ),
        width: 0.8,
      ),
      boxShadow: [
        BoxShadow(
          color: cs.shadow.withOpacity(0.12),
          blurRadius: 18,
          offset: const Offset(0, 8),
        ),
      ],
    );
  }
}

String _formatTime(Duration duration) {
  final hours = duration.inHours;
  final minutes = duration.inMinutes.remainder(60);
  final seconds = duration.inSeconds.remainder(60);

  if (hours > 0) {
    return '${hours}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  } else {
    return '${minutes}:${seconds.toString().padLeft(2, '0')}';
  }
}

class _MiniCover extends StatelessWidget {
  const _MiniCover({required this.url, required this.size});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // PixelPlay-inspired: more rounded corners (12px) for modern look
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.menu_book_outlined,
        color: cs.onSurfaceVariant,
        size: size * 0.45,
      ),
    );

    final src = url ?? '';
    if (src.startsWith('file://')) {
      final file = File(Uri.parse(src).toFilePath());
      if (file.existsSync()) {
        return Image.file(file, width: size, height: size, fit: BoxFit.cover);
      }
      return placeholder;
    }

    if (src.isEmpty) return placeholder;

    return CachedNetworkImage(
      imageUrl: src,
      width: size,
      height: size,
      fit: BoxFit.cover,
      placeholder: (_, __) => placeholder,
      errorWidget: (_, __, ___) => placeholder,
    );
  }
}
