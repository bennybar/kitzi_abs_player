// lib/core/theme_service.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal theme controller used by settings_page.dart via ServicesScope.
/// Access current mode with [mode.value], update with [set] or [toggle].
/// Also manages light mode surface style (pure white vs Material 3 tinted surfaces).
class ThemeService {
  final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final ValueNotifier<bool> useTintedSurfaces = ValueNotifier<bool>(true);

  ThemeService() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      useTintedSurfaces.value = prefs.getBool('ui_tinted_surfaces') ?? true;
    } catch (_) {
      // Ignore errors, use defaults
    }
  }

  void set(ThemeMode next) => mode.value = next;

  void toggle() {
    mode.value = (mode.value == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
  }

  Future<void> setTintedSurfaces(bool enabled) async {
    useTintedSurfaces.value = enabled;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('ui_tinted_surfaces', enabled);
    } catch (_) {
      // Ignore save errors
    }
  }
}
