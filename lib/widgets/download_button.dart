// lib/widgets/download_button.dart
import 'package:flutter/material.dart';
import '../core/downloads_repository.dart';

/// A single “Download” button that:
/// - shows a filling progress overlay while downloading
/// - displays %
/// - turns into a “Cancel” button during download
/// - shows “Downloaded” when complete
///
/// Usage:
/// DownloadButton(
///   libraryItemId: item.id,
///   downloads: context.read<DownloadsRepository>(),
///   onStart: () => context.read<DownloadsRepository>().enqueueItemDownloads(item.id),
///   onCancel: () => context.read<DownloadsRepository>().cancelForItem(item.id),
/// )
class DownloadButton extends StatelessWidget {
  final String libraryItemId;
  final DownloadsRepository downloads;
  final VoidCallback onStart;
  final VoidCallback onCancel;

  const DownloadButton({
    super.key,
    required this.libraryItemId,
    required this.downloads,
    required this.onStart,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<ItemProgress>(
      stream: downloads.watchItemProgress(libraryItemId),
      builder: (context, snap) {
        final p = snap.data;
        final status = p?.status ?? 'none';
        final frac = (p?.progress ?? 0).clamp(0.0, 1.0);

        // Completed state
        if (status == 'complete') {
          return FilledButton.icon(
            onPressed: null,
            icon: const Icon(Icons.check),
            label: const Text('Downloaded'),
          );
        }

        // Running / queued -> show filled progress with Cancel
        if (status == 'running' || status == 'queued') {
          return _ProgressCancelButton(
            fraction: frac,
            onCancel: onCancel,
          );
        }

        // Default: not downloading yet
        return FilledButton.icon(
          onPressed: onStart,
          icon: const Icon(Icons.download),
          label: const Text('Download'),
        );
      },
    );
  }
}

class _ProgressCancelButton extends StatelessWidget {
  final double fraction;
  final VoidCallback onCancel;

  const _ProgressCancelButton({
    required this.fraction,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final textStyle = Theme.of(context).textTheme.labelLarge;
    final bg = Theme.of(context).colorScheme.surfaceVariant;
    final fill = Theme.of(context).colorScheme.primary.withOpacity(0.28);

    return Stack(
      alignment: Alignment.center,
      children: [
        // Base button (acts as "Cancel")
        FilledButton(
          onPressed: onCancel,
          style: FilledButton.styleFrom(
            backgroundColor: bg,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: const Text('Cancel'),
        ),

        // Progress fill overlay
        Positioned.fill(
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: fraction,
            child: Container(
              decoration: BoxDecoration(
                color: fill,
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
        ),

        // Foreground % text
        IgnorePointer(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text('${(fraction * 100).toStringAsFixed(0)}%', style: textStyle),
          ),
        ),
      ],
    );
  }
}
