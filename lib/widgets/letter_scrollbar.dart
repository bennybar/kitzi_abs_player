import 'package:flutter/material.dart';

class LetterScrollbar extends StatefulWidget {
  const LetterScrollbar({
    super.key,
    required this.letters,
    required this.onLetterSelected,
    required this.visible,
  });

  final List<String> letters;
  final ValueChanged<String> onLetterSelected;
  final bool visible;

  @override
  State<LetterScrollbar> createState() => _LetterScrollbarState();
}

class _LetterScrollbarState extends State<LetterScrollbar> {
  int? _activeIndex;

  void _handlePointer(double dy, double height) {
    if (widget.letters.isEmpty) return;
    final letterHeight = height / widget.letters.length;
    if (letterHeight <= 0) return;
    final index = (dy / letterHeight).floor().clamp(0, widget.letters.length - 1);
    _triggerSelection(index);
  }

  void _triggerSelection(int index) {
    if (_activeIndex == index) return;
    _activeIndex = index;
    widget.onLetterSelected(widget.letters[index]);
    setState(() {});
  }

  void _clearSelection() {
    if (_activeIndex != null) {
      setState(() {
        _activeIndex = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return IgnorePointer(
      ignoring: !widget.visible || widget.letters.isEmpty,
      child: AnimatedOpacity(
        opacity: widget.visible && widget.letters.isNotEmpty ? 1 : 0,
        duration: const Duration(milliseconds: 200),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final height = constraints.maxHeight > 0 ? constraints.maxHeight : 1;
            return Listener(
              onPointerDown: (event) => _handlePointer(event.localPosition.dy.toDouble(), height.toDouble()),
              onPointerMove: (event) => _handlePointer(event.localPosition.dy.toDouble(), height.toDouble()),
              onPointerUp: (_) => _clearSelection(),
              onPointerCancel: (_) => _clearSelection(),
              behavior: HitTestBehavior.opaque,
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHigh.withOpacity(0.9),
                  borderRadius: BorderRadius.circular(24),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.08),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    for (int i = 0; i < widget.letters.length; i++)
                      Expanded(
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 150),
                            style: theme.textTheme.bodySmall?.copyWith(
                                  fontWeight: i == _activeIndex ? FontWeight.w700 : FontWeight.w500,
                                  color: i == _activeIndex
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.onSurfaceVariant,
                                ) ??
                                TextStyle(
                                  fontSize: 12,
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                            child: Text(widget.letters[i]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

