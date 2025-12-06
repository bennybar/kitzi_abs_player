import 'dart:async';

import 'package:flutter/foundation.dart';

/// Shared controller so other widgets (like the nav bar) can react when
/// the full player covers the UI. Also tracks an open/close session to mimic
/// the Future returned by showModalBottomSheet.
class FullPlayerOverlay {
  FullPlayerOverlay._();

  static final ValueNotifier<bool> isVisible = ValueNotifier<bool>(false);

  static Completer<void>? _session;

  /// Show the overlay and return a Future that completes when it is hidden.
  static Future<void> showOverlay() {
    if (_session != null && !_session!.isCompleted) {
      isVisible.value = true;
      return _session!.future;
    }
    _session = Completer<void>();
    isVisible.value = true;
    return _session!.future;
  }

  /// Hide the overlay and complete any pending session Future.
  static void hide() {
    if (!isVisible.value && _session == null) return;
    isVisible.value = false;
    _session?.complete();
    _session = null;
  }
}

