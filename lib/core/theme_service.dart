// lib/core/theme_service.dart
import 'package:flutter/material.dart';

/// Minimal theme controller used by settings_page.dart via ServicesScope.
/// Access current mode with [mode.value], update with [set] or [toggle].
class ThemeService {
  final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(ThemeMode.system);

  void set(ThemeMode next) => mode.value = next;

  void toggle() {
    mode.value = (mode.value == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
  }
}
