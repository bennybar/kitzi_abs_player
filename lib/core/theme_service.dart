// lib/core/theme_service.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Surface tint strength levels for light mode
enum SurfaceTintLevel {
  none('Pure White', 0),
  light('Light Tint', 1),
  medium('Medium Tint', 2),
  strong('Strong Tint', 3),
  veryStrong('Very Strong Tint', 4);

  final String label;
  final int value;
  const SurfaceTintLevel(this.label, this.value);

  static SurfaceTintLevel fromValue(int value) {
    return SurfaceTintLevel.values.firstWhere(
      (level) => level.value == value,
      orElse: () => SurfaceTintLevel.medium,
    );
  }
}

/// Minimal theme controller used by settings_page.dart via ServicesScope.
/// Access current mode with [mode.value], update with [set] or [toggle].
/// Also manages light mode surface tint strength.
class ThemeService {
  final ValueNotifier<ThemeMode> mode = ValueNotifier<ThemeMode>(ThemeMode.system);
  final ValueNotifier<SurfaceTintLevel> surfaceTintLevel = ValueNotifier<SurfaceTintLevel>(SurfaceTintLevel.medium);

  ThemeService() {
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final storedValue = prefs.getInt('ui_surface_tint_level');
      if (storedValue != null) {
        surfaceTintLevel.value = SurfaceTintLevel.fromValue(storedValue);
      } else {
        // Migrate from old boolean setting if it exists
        final oldBoolValue = prefs.getBool('ui_tinted_surfaces');
        if (oldBoolValue != null) {
          surfaceTintLevel.value = oldBoolValue ? SurfaceTintLevel.medium : SurfaceTintLevel.none;
        }
      }
    } catch (_) {
      // Ignore errors, use defaults
    }
  }

  void set(ThemeMode next) => mode.value = next;

  void toggle() {
    mode.value = (mode.value == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
  }

  Future<void> setSurfaceTintLevel(SurfaceTintLevel level) async {
    surfaceTintLevel.value = level;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('ui_surface_tint_level', level.value);
    } catch (_) {
      // Ignore save errors
    }
  }
}
