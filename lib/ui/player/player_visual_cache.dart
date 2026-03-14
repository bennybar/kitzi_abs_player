import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:palette_generator/palette_generator.dart';

class PlayerPaletteData {
  const PlayerPaletteData({
    required this.coverUrl,
    required this.primary,
    required this.secondary,
  });

  final String coverUrl;
  final Color? primary;
  final Color? secondary;
}

class PlayerVisualCache {
  static final Map<String, PlayerPaletteData> _paletteCache =
      <String, PlayerPaletteData>{};
  static final Map<String, Future<PlayerPaletteData>> _palettePending =
      <String, Future<PlayerPaletteData>>{};
  static final Set<String> _prewarmedCovers = <String>{};
  static final Map<String, Future<void>> _prewarmPending =
      <String, Future<void>>{};

  static PlayerPaletteData? paletteFor(String? coverUrl) {
    if (coverUrl == null || coverUrl.isEmpty) return null;
    return _paletteCache[coverUrl];
  }

  static Future<PlayerPaletteData> paletteForCover(
    String coverUrl, {
    Size size = const Size(160, 160),
    int maximumColorCount = 12,
  }) {
    final cached = _paletteCache[coverUrl];
    if (cached != null) return Future<PlayerPaletteData>.value(cached);

    final pending = _palettePending[coverUrl];
    if (pending != null) return pending;

    final future = _computePalette(
      coverUrl,
      size: size,
      maximumColorCount: maximumColorCount,
    );
    _palettePending[coverUrl] = future;
    future.whenComplete(() => _palettePending.remove(coverUrl));
    return future;
  }

  static Future<void> prewarmCover(
    String? coverUrl,
    BuildContext context,
  ) async {
    if (coverUrl == null || coverUrl.isEmpty) return;
    if (_prewarmedCovers.contains(coverUrl)) return;

    final pending = _prewarmPending[coverUrl];
    if (pending != null) {
      await pending;
      return;
    }

    final future = () async {
      try {
        await precacheImage(CachedNetworkImageProvider(coverUrl), context);
        _prewarmedCovers.add(coverUrl);
      } catch (_) {
        // Best effort only.
      }
    }();

    _prewarmPending[coverUrl] = future;
    await future.whenComplete(() => _prewarmPending.remove(coverUrl));
  }

  static Future<PlayerPaletteData> _computePalette(
    String coverUrl, {
    required Size size,
    required int maximumColorCount,
  }) async {
    try {
      final palette = await PaletteGenerator.fromImageProvider(
        CachedNetworkImageProvider(coverUrl),
        size: size,
        maximumColorCount: maximumColorCount,
      );
      final data = PlayerPaletteData(
        coverUrl: coverUrl,
        primary:
            palette.dominantColor?.color ?? palette.darkVibrantColor?.color,
        secondary:
            palette.vibrantColor?.color ??
            palette.lightVibrantColor?.color ??
            palette.mutedColor?.color ??
            palette.dominantColor?.color ??
            palette.darkVibrantColor?.color,
      );
      _paletteCache[coverUrl] = data;
      return data;
    } catch (_) {
      final data = PlayerPaletteData(
        coverUrl: coverUrl,
        primary: null,
        secondary: null,
      );
      _paletteCache[coverUrl] = data;
      return data;
    }
  }
}
