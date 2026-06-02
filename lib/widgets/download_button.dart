// lib/widgets/download_button.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads_repository.dart';
import '../main.dart'; // ServicesScope for DI

enum DownloadButtonProgressStyle { fill, outlineRing }

class _OutlineProgressBorderPainter extends CustomPainter {
  const _OutlineProgressBorderPainter({
    required this.progress,
    required this.trackColor,
    required this.progressColor,
    required this.radius,
    required this.strokeWidth,
  });

  final double progress;
  final Color trackColor;
  final Color progressColor;
  final double radius;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(strokeWidth / 2),
      Radius.circular(radius),
    );
    final trackPaint =
        Paint()
          ..color = trackColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth;
    final progressPaint =
        Paint()
          ..color = progressColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..strokeCap = StrokeCap.round;

    canvas.drawRRect(rrect, trackPaint);

    final clamped = progress.clamp(0.0, 1.0);
    if (clamped <= 0) return;

    final path = Path()..addRRect(rrect);
    final metric = path.computeMetrics().firstOrNull;
    if (metric == null) return;
    final progressPath = metric.extractPath(0, metric.length * clamped);
    canvas.drawPath(progressPath, progressPaint);
  }

  @override
  bool shouldRepaint(covariant _OutlineProgressBorderPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.trackColor != trackColor ||
        oldDelegate.progressColor != progressColor ||
        oldDelegate.radius != radius ||
        oldDelegate.strokeWidth != strokeWidth;
  }
}

/// A smart download action that:
/// - Shows "Download" when nothing is queued
/// - Shows a filling button while queued/running with percent
/// - Shows "Remove" when complete
/// - Offers a cancel option while running
class DownloadButton extends StatefulWidget {
  const DownloadButton({
    super.key,
    required this.libraryItemId,
    this.episodeId,
    this.fullWidth = true,
    this.progressStyle = DownloadButtonProgressStyle.fill,
    this.titleForNotification, // optional label some callers pass in
  });

  final String libraryItemId;
  final String? episodeId;
  final bool fullWidth;
  final DownloadButtonProgressStyle progressStyle;

  /// Optional: a human title for notifications/UI. Not all backends need it,
  /// but we accept it so callers can pass it without compile errors.
  final String? titleForNotification;

  @override
  State<DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<DownloadButton> {
  DownloadsRepository? _downloads;
  StreamSubscription<ItemProgress>? _sub;
  ItemProgress? _snap;
  bool _busy = false;
  bool _mounted = false;
  int? _estimatedTotalBytes;
  bool _loadingEstimatedBytes = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = ServicesScope.of(context).services.downloads;

    if (!identical(repo, _downloads)) {
      // switch subscriptions safely
      _sub?.cancel();
      _downloads = repo;
      // Ensure repo is initialized
      _downloads!.init();
      _sub = _downloads!.watchItemProgress(widget.libraryItemId).listen((p) {
        if (_mounted) {
          setState(() => _snap = p);
        }
        if (p.status == 'running' || p.status == 'queued') {
          unawaited(_ensureEstimatedBytes());
        }
      });
      // Pull a fresh snapshot immediately when attaching to a (possibly new) repo
      _refreshSnap();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _mounted = false;
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _mounted = true;
    // Pull an initial snapshot on first build
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshSnap());
  }

  @override
  void didUpdateWidget(covariant DownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // When navigating back to details, refresh current status
    if (_downloads != null && oldWidget.libraryItemId != widget.libraryItemId) {
      _estimatedTotalBytes = null;
      _loadingEstimatedBytes = false;
      // Re-subscribe to the new item's progress; the old subscription would
      // otherwise keep emitting the previous item's progress into _snap.
      _sub?.cancel();
      _sub = _downloads!.watchItemProgress(widget.libraryItemId).listen((p) {
        if (_mounted) {
          setState(() => _snap = p);
        }
        if (p.status == 'running' || p.status == 'queued') {
          unawaited(_ensureEstimatedBytes());
        }
      });
      _refreshSnap();
    } else {
      _refreshSnap();
    }
  }

  Future<void> _refreshSnap() async {
    if (!_mounted || _downloads == null) return;
    try {
      // Use a quick local snapshot; if that fails, fall back to the stream first value.
      ItemProgress snap;
      try {
        snap = await _downloads!.getQuickProgress(widget.libraryItemId);
      } catch (_) {
        snap = await _downloads!.watchItemProgress(widget.libraryItemId).first;
      }
      if (_mounted) {
        setState(() {
          _snap = snap;
        });
      }
      if (snap.status == 'running' || snap.status == 'queued') {
        unawaited(_ensureEstimatedBytes());
      }
    } catch (_) {}
  }

  Future<void> _ensureEstimatedBytes() async {
    if (_downloads == null ||
        _loadingEstimatedBytes ||
        _estimatedTotalBytes != null) {
      return;
    }
    _loadingEstimatedBytes = true;
    try {
      final total = await _downloads!.estimateTotalBytes(
        widget.libraryItemId,
        episodeId: widget.episodeId,
      );
      if (_mounted && total != null && total > 0) {
        setState(() {
          _estimatedTotalBytes = total;
        });
      }
    } catch (_) {
      // Best-effort only.
    } finally {
      _loadingEstimatedBytes = false;
    }
  }

  String _formatBytes(int bytes) {
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

  Future<void> _enqueue() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      // If this item is already active, ignore duplicate enqueue taps
      if (_snap != null &&
          (_snap!.status == 'running' || _snap!.status == 'queued')) {
        return;
      }

      // Check wifi-only setting and connectivity
      final prefs = await SharedPreferences.getInstance();
      final wifiOnly = prefs.getBool('downloads_wifi_only') ?? false;

      if (wifiOnly) {
        final connectivity = await Connectivity().checkConnectivity();
        final isOnCellular =
            connectivity.contains(ConnectivityResult.mobile) &&
            !connectivity.contains(ConnectivityResult.wifi) &&
            !connectivity.contains(ConnectivityResult.ethernet);

        if (isOnCellular) {
          final changeSetting = await showDialog<bool>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: const Text('Wi‑Fi only downloads enabled'),
                  content: const Text(
                    'Downloads are restricted to Wi‑Fi only. You are currently on cellular data. Would you like to allow downloads on cellular data?',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('No'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Yes, allow cellular'),
                    ),
                  ],
                ),
          );

          if (changeSetting == true) {
            await prefs.setBool('downloads_wifi_only', false);
          } else {
            return; // User declined, do nothing
          }
        }
      }

      // Check whether other items are active/queued
      final othersActive = await _downloads!.hasActiveOrQueued();
      bool requireCancelOthers = false;
      if (othersActive) {
        // If only this item is tracked or active, allow enqueue directly
        try {
          final tracked = await _downloads!.listTrackedItemIds();
          final onlyThis =
              tracked.isNotEmpty &&
              tracked.every((id) => id == widget.libraryItemId);
          if (!onlyThis) requireCancelOthers = true;
        } catch (_) {
          requireCancelOthers = true; // be conservative if unknown
        }
      }

      bool proceed = true;
      bool cancelOthers = false;
      if (requireCancelOthers) {
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

      // Proceed to enqueue this item
      await _downloads!.enqueueItemDownloads(
        widget.libraryItemId,
        episodeId: widget.episodeId,
        displayTitle: widget.titleForNotification,
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
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelCurrent() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      // Strong cancel: cancel all tasks first, then remove this item's local files
      await _downloads!.cancelForItem(widget.libraryItemId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _removeLocal() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      await _downloads!.deleteLocal(widget.libraryItemId);
    } catch (_) {
      // Best-effort: surface a gentle message
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Couldn’t remove local download')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;

    Widget child;

    // 1) Completed -> "Remove"
    if (snap?.status == 'complete') {
      child = FilledButton.tonalIcon(
        onPressed: _busy ? null : _removeLocal,
        icon: const Icon(Icons.delete_outline),
        label: const Text('Remove'),
      );
    }
    // 2) Running/Queued -> progress button + cancel
    else if (snap != null &&
        (snap.status == 'running' || snap.status == 'queued')) {
      final pctRaw = (snap.progress * 100).clamp(0, 100);
      final pct = pctRaw.toStringAsFixed(pctRaw >= 10 ? 0 : 1);
      final totalBytes = _estimatedTotalBytes;
      final downloadedBytes =
          totalBytes != null
              ? (totalBytes * snap.progress).round().clamp(0, totalBytes)
              : null;
      final amountLabel =
          (downloadedBytes != null && totalBytes != null)
              ? _formatBytes(totalBytes)
              : 'Calculating size…';
      if (widget.progressStyle == DownloadButtonProgressStyle.outlineRing) {
        const borderRadius = 16.0;
        const strokeWidth = 4.0;
        child = SizedBox(
          height: 54,
          child: CustomPaint(
            painter: _OutlineProgressBorderPainter(
              progress: snap.progress,
              trackColor: cs.outlineVariant.withOpacity(0.35),
              progressColor: cs.primary,
              radius: borderRadius,
              strokeWidth: strokeWidth,
            ),
            child: Material(
              color: cs.surfaceContainerHighest.withOpacity(0.45),
              borderRadius: BorderRadius.circular(borderRadius),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '$pct%',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.titleMedium?.copyWith(
                              color: cs.onSurface,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            amountLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    IconButton(
                      onPressed: _busy ? null : _cancelCurrent,
                      icon: const Icon(Icons.close, size: 20),
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        foregroundColor: cs.onSurfaceVariant,
                        backgroundColor: cs.surface.withOpacity(0.6),
                        minimumSize: const Size(36, 36),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      } else {
        child = SizedBox(
          height: 44,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Container(color: cs.primaryContainer),
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: snap.progress.clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              cs.primary,
                              cs.primary.withOpacity(0.82),
                            ],
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, right: 56),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              amountLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: cs.onPrimary,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            '$pct%',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 48,
                child: Material(
                  color: Colors.transparent,
                  child: Ink(
                    decoration: BoxDecoration(
                      color: cs.error,
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                    ),
                    child: InkWell(
                      borderRadius: const BorderRadius.only(
                        topRight: Radius.circular(12),
                        bottomRight: Radius.circular(12),
                      ),
                      onTap: _busy ? null : _cancelCurrent,
                      child: Icon(
                        Icons.close,
                        size: 20,
                        color: cs.onError,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      }
    }
    // 3) Default -> "Download"
    else {
      child = FilledButton.icon(
        onPressed: _busy ? null : _enqueue,
        icon:
            _busy
                ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
                : const Icon(Icons.download),
        label: Text(_busy ? 'Adding…' : 'Download'),
      );
    }

    if (widget.fullWidth) {
      return SizedBox(width: double.infinity, child: child);
    }
    return child;
  }
}
