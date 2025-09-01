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
      await _downloads!.enqueueItemDownloads(
        widget.libraryItemId,
        episodeId: widget.episodeId,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _cancelAll() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      await _downloads!.cancelForItem(widget.libraryItemId);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Try to remove local downloads even if the repository method name differs
  /// across branches (removeLocalDownloads / removeLocal / removeLocalItem).
  Future<void> _removeLocal() async {
    if (_downloads == null) return;
    setState(() => _busy = true);
    try {
      // Use dynamic to avoid static compile errors if the exact method name differs.
      final dyn = _downloads as dynamic;
      final id = widget.libraryItemId;

      // Try common method names in order:
      if (dyn.removeLocalDownloads is Function) {
        await dyn.removeLocalDownloads(id);
      } else if (dyn.removeLocal is Function) {
        await dyn.removeLocal(id);
      } else if (dyn.removeLocalItem is Function) {
        await dyn.removeLocalItem(id);
      } else {
        // Fallback: cancel tasks; user may need to delete files manually
        await _downloads!.cancelForItem(id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Removed from queue. Local files unchanged.')),
          );
        }
      }
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
      final pct = (snap.progress * 100).clamp(0, 100).toStringAsFixed(0);
      child = Stack(
        children: [
          // Background progress bar that fills the button
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(20),
              child: LinearProgressIndicator(
                value: snap.progress,
                backgroundColor: Colors.transparent,
              ),
            ),
          ),
          FilledButton.icon(
            onPressed: null, // disabled while running
            icon: const Icon(Icons.download),
            label: Text('Downloading… $pct%'),
          ),
          // Cancel hotspot on the right
          Positioned.fill(
            child: Align(
              alignment: Alignment.centerRight,
              child: IconButton(
                tooltip: 'Cancel',
                onPressed: _busy ? null : _cancelAll,
                icon: const Icon(Icons.close),
              ),
            ),
          ),
        ],
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

