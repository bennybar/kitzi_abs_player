import 'package:flutter/material.dart';

class BookMetadataFact {
  const BookMetadataFact({
    required this.label,
    required this.value,
    this.icon,
  });

  final String label;
  final String value;
  final IconData? icon;
}

// Persists across sheet open/close within the app session.
final Map<String, List<BookMetadataFact>> _metadataCache = {};

Future<void> showBookMetadataSheet({
  required BuildContext context,
  required String title,
  String? subtitle,
  String? cacheKey,
  required Future<List<BookMetadataFact>> Function() loadFacts,
}) {
  final cs = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: false,
    useSafeArea: true,
    backgroundColor: cs.surfaceContainerHigh,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (context) => _BookMetadataSheet(
      title: title,
      subtitle: subtitle,
      cacheKey: cacheKey ?? title,
      loadFacts: loadFacts,
    ),
  );
}

class _BookMetadataSheet extends StatefulWidget {
  const _BookMetadataSheet({
    required this.title,
    required this.cacheKey,
    required this.loadFacts,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final String cacheKey;
  final Future<List<BookMetadataFact>> Function() loadFacts;

  @override
  State<_BookMetadataSheet> createState() => _BookMetadataSheetState();
}

class _BookMetadataSheetState extends State<_BookMetadataSheet> {
  List<BookMetadataFact>? _facts;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    final cached = _metadataCache[widget.cacheKey];
    if (cached != null) _facts = cached;
    _refresh();
  }

  Future<void> _refresh() async {
    if (_facts == null && mounted) setState(() => _loading = true);
    try {
      final result = await widget.loadFacts();
      _metadataCache[widget.cacheKey] = result;
      if (mounted) setState(() { _facts = result; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final facts = _facts ?? const <BookMetadataFact>[];

    return Padding(
      padding: EdgeInsets.fromLTRB(18, 24, 18, bottomInset + 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.72,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              'More info',
              style: text.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: text.bodyLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (widget.subtitle != null && widget.subtitle!.trim().isNotEmpty) ...[
              const SizedBox(height: 2),
              Text(
                widget.subtitle!,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 20),
            if (_loading && _facts == null)
              const Expanded(
                child: Center(child: CircularProgressIndicator()),
              )
            else if (facts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  'No metadata available yet.',
                  style: text.bodyMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                  ),
                ),
              )
            else
              Flexible(
                child: SingleChildScrollView(
                  child: Wrap(
                    alignment: WrapAlignment.start,
                    spacing: 8,
                    runSpacing: 8,
                    children:
                        facts
                            .map((fact) => _MetadataPill(fact: fact))
                            .toList(growable: false),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _MetadataPill extends StatelessWidget {
  const _MetadataPill({required this.fact});

  final BookMetadataFact fact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Material(
      color: cs.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 138, maxWidth: 178),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (fact.icon != null) ...[
                    Icon(
                      fact.icon,
                      size: 13,
                      color: cs.onSurfaceVariant.withValues(alpha: 0.72),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      fact.label,
                      style: text.labelSmall?.copyWith(
                        color: cs.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.2,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 5),
              Text(
                fact.value,
                style: text.bodySmall?.copyWith(
                  color: cs.onSurface,
                  fontWeight: FontWeight.w700,
                  height: 1.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
