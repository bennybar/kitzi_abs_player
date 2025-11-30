import 'package:flutter/foundation.dart';

/// Shared visibility flag so other widgets (like the nav bar) can react when
/// the full player covers the UI.
class FullPlayerOverlay {
  FullPlayerOverlay._();

  static final ValueNotifier<bool> isVisible = ValueNotifier<bool>(false);
}

