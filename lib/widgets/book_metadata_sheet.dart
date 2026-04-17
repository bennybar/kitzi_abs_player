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
      padding: EdgeInsets.fromLTRB(6, 12, 6, bottomInset + 8),
      child: Material(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(28),
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.76,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Column(
                  children: [
                    Container(
                      width: 42,
                      height: 5,
                      decoration: BoxDecoration(
                        color: cs.outlineVariant.withValues(alpha: 0.7),
                        borderRadius: BorderRadius.circular(999),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      'More info',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.2,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: cs.outlineVariant.withValues(alpha: 0.4),
              ),
              if (_loading && _facts == null)
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 24, 20, 28),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (facts.isEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
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
                    child: ListView.separated(
                      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                      itemCount: facts.length,
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      separatorBuilder:
                          (_, __) => Divider(
                            height: 1,
                            indent: 54,
                            color: cs.outlineVariant.withValues(alpha: 0.22),
                          ),
                      itemBuilder:
                          (context, index) => _MetadataRow(fact: facts[index]),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetadataRow extends StatelessWidget {
  const _MetadataRow({required this.fact});

  final BookMetadataFact fact;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: cs.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child:
                fact.icon != null
                    ? Icon(
                      fact.icon,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    )
                    : Icon(
                      Icons.info_outline_rounded,
                      size: 16,
                      color: cs.onSurfaceVariant,
                    ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  fact.label,
                  style: text.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.2,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  fact.value,
                  style: text.bodyLarge?.copyWith(
                    color: cs.onSurface,
                    fontWeight: FontWeight.w700,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
