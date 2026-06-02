import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/playback_repository.dart';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';
import '../ui/player/player_visual_cache.dart';

/// Compact mini-player: small cover, title + author, a thin progress hairline
/// at the bottom edge, a subtle rewind and a filled play/pause control. The
/// background is tinted from the cover art's palette so each book feels
/// distinct (never flat grey); it falls back to the brand accent.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, this.height = 64});

  final double height;

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  String? _loadingUrl;

  @override
  Widget build(BuildContext context) {
    final playback = ServicesScope.of(context).services.playback;
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = Theme.of(context).textTheme;

    return StreamBuilder<NowPlaying?>(
      stream: playback.nowPlayingStream,
      initialData: playback.nowPlaying,
      builder: (context, snap) {
        final np = snap.data;
        // Parent AnimatedSize collapses this when there's nothing playing.
        if (np == null) return const SizedBox.shrink();

        // Cover-derived tint (cached; warmed by the full player). Kick a
        // one-shot compute if we don't have it yet for this cover.
        final url = np.coverUrl;
        final pd = PlayerVisualCache.paletteFor(url);
        if (pd == null && url != null && url.isNotEmpty && _loadingUrl != url) {
          _loadingUrl = url;
          PlayerVisualCache.paletteForCover(url).then((_) {
            if (mounted) setState(() {});
          });
        }
        final seed = pd?.primary ?? pd?.secondary ?? cs.primary;
        final tintA = Color.alphaBlend(
            seed.withOpacity(dark ? 0.34 : 0.20), cs.surfaceContainerHigh);
        final tintB = Color.alphaBlend(
            seed.withOpacity(dark ? 0.16 : 0.06), cs.surfaceContainerHigh);

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [tintA, tintB],
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () => FullPlayerPage.openOnce(context),
              child: SizedBox(
                height: widget.height,
                child: Column(
                  children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(18, 10, 16, 6),
                        child: Row(
                          children: [
                            _cover(np, cs),
                            const SizedBox(width: 12),
                            Expanded(child: _meta(np, playback, cs, text)),
                            const SizedBox(width: 8),
                            _rewind(playback, cs),
                            const SizedBox(width: 6),
                            _playButton(context, playback, np, cs),
                          ],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 0, 18, 10),
                      child: _hairline(playback, cs),
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

  Widget _cover(NowPlaying np, ColorScheme cs) {
    const size = 44.0;
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(11),
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(11),
        child: _MiniCover(url: np.coverUrl, size: size),
      ),
    );
  }

  Widget _meta(NowPlaying np, PlaybackRepository playback, ColorScheme cs,
      TextTheme text) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          np.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: text.bodyMedium?.copyWith(
            fontSize: 14.5,
            fontWeight: FontWeight.w700,
            color: cs.onSurface,
            letterSpacing: -0.2,
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            if (np.author != null && np.author!.isNotEmpty)
              Flexible(
                child: Text(
                  np.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.bodySmall?.copyWith(
                    fontSize: 12,
                    color: cs.onSurfaceVariant,
                  ),
                ),
              ),
            // Only surface the sync state when something is actually pending —
            // keeps the bar clean the rest of the time.
            ValueListenableBuilder<ProgressSyncStatus>(
              valueListenable: playback.progressSyncStatus,
              builder: (_, status, __) {
                if (!status.pending) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: 'Progress pending sync',
                    child: Icon(LucideIcons.uploadCloud,
                        size: 12, color: cs.tertiary),
                  ),
                );
              },
            ),
          ],
        ),
      ],
    );
  }

  Widget _rewind(PlaybackRepository playback, ColorScheme cs) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () => playback.nudgeSeconds(-10),
        child: SizedBox(
          width: 34,
          height: 34,
          child: Icon(LucideIcons.rotateCcw, size: 19, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _hairline(PlaybackRepository playback, ColorScheme cs) {
    return ValueListenableBuilder<Duration>(
      valueListenable: playback.currentPosition,
      builder: (_, currentPos, __) {
        final pos = playback.globalBookPosition ?? currentPos;
        final dur = playback.totalBookDuration;
        if (dur == null || dur == Duration.zero) {
          return const SizedBox.shrink();
        }
        final fraction =
            (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0);
        return ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: fraction,
            minHeight: 2.5,
            backgroundColor: cs.onSurface.withOpacity(0.12),
            valueColor: AlwaysStoppedAnimation<Color>(cs.primary),
          ),
        );
      },
    );
  }

  Widget _playButton(BuildContext context, PlaybackRepository playback,
      NowPlaying np, ColorScheme cs) {
    return StreamBuilder<bool>(
      stream: playback.playingStream,
      initialData: playback.player.playing,
      builder: (_, playSnap) {
        final playing = playSnap.data ?? false;
        final isPlaying = playing;
        return Material(
          color: isPlaying ? cs.primary : cs.primary.withOpacity(0.16),
          shape: const CircleBorder(),
          elevation: isPlaying ? 2 : 0,
          shadowColor: cs.primary.withOpacity(0.3),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: () async {
              if (isPlaying) {
                await playback.pause();
                return;
              }
              bool success = await playback.resume(context: context);
              if (!success) {
                try {
                  await playback.warmLoadLastItem(playAfterLoad: true);
                  success = true;
                } catch (_) {
                  success = false;
                }
              }
              if (!success && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                        'Cannot play: server unavailable and sync progress is required'),
                    duration: Duration(seconds: 4),
                  ),
                );
              } else if (success && context.mounted) {
                await FullPlayerPage.openOnce(context);
              }
            },
            child: SizedBox(
              width: 44,
              height: 44,
              child: Icon(
                isPlaying ? LucideIcons.pause : LucideIcons.play,
                size: 24,
                color: isPlaying ? cs.onPrimary : cs.primary,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MiniCover extends StatelessWidget {
  const _MiniCover({required this.url, required this.size});
  final String? url;
  final double size;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: cs.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(11),
      ),
      child: Icon(
        LucideIcons.bookOpen,
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
