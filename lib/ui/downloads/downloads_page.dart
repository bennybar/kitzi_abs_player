import 'dart:async';
import 'package:flutter/material.dart';
import 'package:background_downloader/background_downloader.dart';
import '../../core/downloads_repository.dart';

class DownloadsPage extends StatefulWidget {
  const DownloadsPage({super.key, required this.repo});
  final DownloadsRepository repo;

  @override
  State<DownloadsPage> createState() => _DownloadsPageState();
}

class _DownloadsPageState extends State<DownloadsPage> {
  late final Stream<TaskUpdate> _updates;
  StreamSubscription<TaskUpdate>? _sub;

  // latest update by taskId so we can show immediate progress
  final Map<String, TaskUpdate> _latest = {};

  @override
  void initState() {
    super.initState();
    // make sure repo is initialized (no-op if already)
    widget.repo.init();

    _updates = widget.repo.progressStream();
    _sub = _updates.listen((u) {
      _latest[u.task.taskId] = u;
      if (mounted) setState(() {}); // trigger rebuild
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // We rebuild on each stream event via setState above.
    return FutureBuilder<List<TaskRecord>>(
      future: widget.repo.listAll(),
      builder: (context, recs) {
        final items = recs.data ?? const [];
        if (items.isEmpty) {
          return const Center(child: Text('No downloads'));
        }
        return ListView.separated(
          itemCount: items.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (ctx, i) {
            final r = items[i];
            final task = r.task;

            // start with DB snapshot
            double progress = r.progress ?? 0.0;
            String status = r.status.name;

            // prefer latest live update if we have it
            final live = _latest[task.taskId];
            if (live is TaskProgressUpdate) {
              progress = live.progress;
              status = 'running';
            } else if (live is TaskStatusUpdate) {
              status = live.status.name;
            }

            final isTerminal = status == 'complete' || status == 'failed' || status == 'canceled';

            return ListTile(
              title: Text(task.filename),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  LinearProgressIndicator(value: isTerminal ? 1.0 : progress),
                  const SizedBox(height: 4),
                  Text('$status • ${(progress * 100).toStringAsFixed(0)}%'),
                ],
              ),
              trailing: IconButton(
                icon: const Icon(Icons.cancel),
                onPressed: () => FileDownloader().cancelTaskWithId(r.taskId),
              ),
            );
          },
        );
      },
    );
  }
}

