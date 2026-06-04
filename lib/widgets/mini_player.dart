import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import 'package:lucide_icons_flutter/lucide_icons.dart';
import '../core/playback_repository.dart';
import '../core/ui_prefs.dart';
import '../main.dart'; // ServicesScope
import '../ui/player/full_player_page.dart';
import '../ui/player/player_visual_cache.dart';

/// Compact mini-player with a waveform scrubber: small cover, title above a
/// slim audio-style waveform that doubles as the seek bar (played portion in
/// the accent, the rest muted), and a play/pause control. The background is
/// tinted from the cover art's palette so each book feels distinct.
class MiniPlayer extends StatefulWidget {
  const MiniPlayer({super.key, this.height = 74});

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
        if (np == null) return const SizedBox.shrink();

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
                child: Padding(
                  // Wide bar, with a little breathing room at the edges.
                  padding: const EdgeInsets.fromLTRB(13, 8, 12, 8),
                  child: Row(
                    children: [
                      _cover(np, cs),
                      const SizedBox(width: 12),
                      Expanded(child: _titleAndWave(np, playback, cs, text)),
                      const SizedBox(width: 4),
                      _backButton(playback, cs),
                      const SizedBox(width: 2),
                      _playButton(context, playback, np, cs),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _cover(NowPlaying np, ColorScheme cs) {
    const size = 50.0;
    return Container(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: cs.shadow.withOpacity(0.18),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipOval(
        child: _MiniCover(url: np.coverUrl, size: size),
      ),
    );
  }

  Widget _titleAndWave(NowPlaying np, PlaybackRepository playback,
      ColorScheme cs, TextTheme text) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
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
            ),
            // Surface the sync state only when a write is pending.
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
        const SizedBox(height: 7),
        SizedBox(
          height: 20,
          child: ValueListenableBuilder<Duration>(
            valueListenable: playback.currentPosition,
            builder: (_, curPos, __) {
              final pos = playback.globalBookPosition ?? curPos;
              final total = playback.totalBookDuration;
              final frac = (total != null && total.inMilliseconds > 0)
                  ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
                  : 0.0;
              // Display-only: no scrubbing here (a stray tap would jump the
              // book) and it lets taps fall through to open the full player.
              return IgnorePointer(
                child: _Waveform(
                  fraction: frac,
                  seed: np.libraryItemId.hashCode,
                  played: cs.primary,
                  unplayed: cs.onSurface.withOpacity(0.22),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _backButton(PlaybackRepository playback, ColorScheme cs) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: () =>
            playback.nudgeSeconds(-UiPrefs.seekBackwardSeconds.value),
        child: SizedBox(
          width: 40,
          height: 40,
          child: Icon(LucideIcons.rotateCcw,
              size: 20, color: cs.onSurfaceVariant),
        ),
      ),
    );
  }

  Widget _playButton(BuildContext context, PlaybackRepository playback,
      NowPlaying np, ColorScheme cs) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return StreamBuilder<bool>(
      stream: playback.playingStream,
      initialData: playback.player.playing,
      builder: (_, playSnap) {
        final isPlaying = playSnap.data ?? false;
        return Material(
          color: isPlaying ? cs.primary : cs.primary.withOpacity(0.16),
          shape: const CircleBorder(),
          elevation: (isPlaying && !dark) ? 2 : 0,
          shadowColor: dark ? Colors.transparent : cs.primary.withOpacity(0.3),
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
              width: 46,
              height: 46,
              child: Icon(
                isPlaying ? LucideIcons.pause : LucideIcons.play,
                size: 25,
                color: isPlaying ? cs.onPrimary : cs.primary,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A slim audio waveform used purely as a progress indicator (not a scrubber).
/// The bar heights are deterministic per [seed] (so a given book always shows
/// the same shape); the played fraction is drawn in [played], the remainder in
/// [unplayed].
class _Waveform extends StatelessWidget {
  const _Waveform({
    required this.fraction,
    required this.seed,
    required this.played,
    required this.unplayed,
  });

  final double fraction;
  final int seed;
  final Color played;
  final Color unplayed;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size.infinite,
      painter: _WavePainter(
        fraction: fraction,
        seed: seed,
        played: played,
        unplayed: unplayed,
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  _WavePainter({
    required this.fraction,
    required this.seed,
    required this.played,
    required this.unplayed,
  });

  final double fraction;
  final int seed;
  final Color played;
  final Color unplayed;

  @override
  void paint(Canvas canvas, Size size) {
    const barW = 3.0;
    const gap = 2.0;
    final step = barW + gap;
    final n = (size.width / step).floor().clamp(1, 200);
    // Deterministic pseudo-random heights from the seed (stable per book).
    var s = seed & 0x7fffffff;
    int next() {
      s = (s * 1103515245 + 12345) & 0x7fffffff;
      return s;
    }

    final playedX = size.width * fraction;
    final paint = Paint()..isAntiAlias = true;
    final mid = size.height / 2;
    for (var i = 0; i < n; i++) {
      final r = (next() % 1000) / 1000.0; // 0..1
      // bias toward mid heights with occasional tall bars
      final hFrac = 0.22 + r * r * 0.78;
      final h = (size.height * hFrac).clamp(2.0, size.height);
      final x = i * step;
      paint.color = (x + barW / 2) <= playedX ? played : unplayed;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, mid - h / 2, barW, h),
        const Radius.circular(1.5),
      );
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _WavePainter old) =>
      old.fraction != fraction ||
      old.seed != seed ||
      old.played != played ||
      old.unplayed != unplayed;
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
        shape: BoxShape.circle,
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
