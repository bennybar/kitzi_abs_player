// lib/widgets/download_button.dart
import 'dart:async';

import 'package:flutter/material.dart';

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final repo = ServicesScope.of(context).services.downloads;

    if (!identical(repo, _downloads)) {
      // switch subscriptions safely
      _sub?.cancel();
      _downloads = repo;
      _sub = _downloads!
          .watchItemProgress(widget.libraryItemId)
          .listen((p) => setState(() => _snap = p));
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _enqueue() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      // If this item is already active, ignore duplicate enqueue taps
      if (_snap != null && (_snap!.status == 'running' || _snap!.status == 'queued')) {
        return;
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

      final confirm = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Single download at a time'),
          content: const Text(
              'Only one download is supported at a time.\n\nCancel all other downloads and download this book now?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('No'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Yes, download this'),
            ),
          ],
        ),
      );
      // Regardless of answer to legacy dialog, if we reached here without cancelling others
      // proceed to enqueue this item. Keep dialog for compatibility but avoid additional cancelAll.
      if (confirm == true || !requireCancelOthers) {
        await _downloads!.enqueueItemDownloads(
          widget.libraryItemId,
          episodeId: widget.episodeId,
          displayTitle: widget.titleForNotification,
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
      final pct = (snap.progress * 100).clamp(0, 100).toStringAsFixed(snap.totalTasks >= 50 ? 1 : 0);
      final frac = '${snap.completed}/${snap.totalTasks}';
      child = SizedBox(
        height: 40, // lock height to avoid layout jump
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background progress bar that fills the button
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: LinearProgressIndicator(
                value: snap.progress,
                backgroundColor: Colors.transparent,
              ),
            ),
            FilledButton.icon(
              onPressed: null, // disabled while running
              icon: const Icon(Icons.download),
              label: Text('Downloading… $frac ($pct%)'),
            ),
            // Cancel hotspot on the right (per-book cancel)
            Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Cancel download',
                onPressed: _busy ? null : _cancelCurrent,
                icon: const Icon(Icons.close),
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

