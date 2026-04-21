import 'package:flutter/foundation.dart';

/// Shared visibility flag so other widgets (like the nav bar) can react when
/// the full player covers the UI.
class FullPlayerOverlay {
  FullPlayerOverlay._();

  static final ValueNotifier<bool> isVisible = ValueNotifier<bool>(false);

  /// Increments whenever a caller wants to bring the full player into view.
  /// When `UiPrefs.fullPlayerAsTab` is on, the main scaffold listens to this
  /// counter and switches to the Player tab instead of opening a modal.
  static final ValueNotifier<int> openRequests = ValueNotifier<int>(0);

  static void requestOpen() {
    openRequests.value++;
  }
}
