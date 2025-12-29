// lib/widgets/download_button.dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../core/downloads_repository.dart';
import '../main.dart'; // ServicesScope for DI

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
    this.titleForNotification, // optional label some callers pass in
  });

  final String libraryItemId;
  final String? episodeId;
  final bool fullWidth;

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
      _sub = _downloads!
          .watchItemProgress(widget.libraryItemId)
          .listen((p) {
            if (_mounted) {
              setState(() => _snap = p);
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
    } catch (_) {}
  }

  Future<void> _enqueue() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      // If this item is already active, ignore duplicate enqueue taps
      if (_snap != null && (_snap!.status == 'running' || _snap!.status == 'queued')) {
        return;
      }

      // Check wifi-only setting and connectivity
      final prefs = await SharedPreferences.getInstance();
      final wifiOnly = prefs.getBool('downloads_wifi_only') ?? false;
      
      if (wifiOnly) {
        final connectivity = await Connectivity().checkConnectivity();
        final isOnCellular = connectivity.contains(ConnectivityResult.mobile) &&
            !connectivity.contains(ConnectivityResult.wifi) &&
            !connectivity.contains(ConnectivityResult.ethernet);
        
        if (isOnCellular) {
          final changeSetting = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Wi‑Fi only downloads enabled'),
              content: const Text(
                  'Downloads are restricted to Wi‑Fi only. You are currently on cellular data. Would you like to allow downloads on cellular data?'),
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
          final onlyThis = tracked.isNotEmpty && tracked.every((id) => id == widget.libraryItemId);
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
          builder: (context) => AlertDialog(
            title: const Text('Single download at a time'),
            content: const Text(
                'Another book is downloading. Cancel it and download this book now?'),
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
            content: Text('Download started – follow progress from Downloads tab.'),
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
      final pct = pctRaw >= 1
          ? pctRaw.toStringAsFixed(pctRaw >= 10 ? 0 : 1)
          : '';
      final frac = (snap.completed > 0 || snap.totalTasks > 0)
          ? '${snap.completed}/${snap.totalTasks}'
          : '';
      child = SizedBox(
        height: 40, // keep aligned with play button
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Main button content (no long text to avoid overlap)
            Padding(
              padding: EdgeInsets.zero,
              child: FilledButton(
                onPressed: null, // disabled while running
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: Theme.of(context).colorScheme.primary,
                  disabledForegroundColor: Theme.of(context).colorScheme.onPrimary,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(left: 12, right: 48),
                  child: Row(
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            if (frac.isNotEmpty)
                              Flexible(
                                child: Text(
                                  frac,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: Theme.of(context).colorScheme.onPrimary,
                                        fontWeight: FontWeight.w600,
                                      ),
                                ),
                              ),
                            if (frac.isNotEmpty) const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                pct.isNotEmpty ? '$pct%' : 'Downloading…',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Theme.of(context).colorScheme.onPrimary,
                                      fontFeatures: const [FontFeature.tabularFigures()],
                                      fontWeight: FontWeight.w700,
                                    ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Slim bottom progress bar for an elegant Material feel
            Positioned(
              left: 12,
              right: 56, // stop before the cancel segment so the end is visible
              bottom: 6,
              height: 6,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Track
                    Container(
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.onPrimary.withOpacity(0.16),
                      ),
                    ),
                    // Filled bar with subtle Material-ish gradient
                    FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: (snap.progress).clamp(0.0, 1.0),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(999),
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [
                              Theme.of(context).colorScheme.onPrimary.withOpacity(0.9),
                              Theme.of(context).colorScheme.onPrimary,
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Removed overlay progress text; information is now inside the button content
            // Integrated cancel segment on the right (per-book cancel), flush with main button
            Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              width: 48,
              child: Material(
                color: Colors.transparent,
                child: Ink(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.error,
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
                      color: Theme.of(context).colorScheme.onError,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    }
    // 3) Default -> "Download"
    else {
      child = FilledButton.icon(
        onPressed: _busy ? null : _enqueue,
        icon: _busy
            ? const SizedBox(
            width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
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

