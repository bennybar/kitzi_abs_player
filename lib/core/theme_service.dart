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

  ThemeService();

  /// Initialize and load preferences. Call this after creating ThemeService.
  Future<void> init() => _loadPreferences();

  Future<void> _loadPreferences() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      
      // Load theme mode
      final themeModeString = prefs.getString('ui_theme_mode');
      if (themeModeString != null) {
        final loadedMode = switch (themeModeString) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          'system' => ThemeMode.system,
          _ => ThemeMode.system,
        };
        mode.value = loadedMode;
      }
      
      // Load surface tint level
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

  Future<void> set(ThemeMode next) async {
    mode.value = next;
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeString = switch (next) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
      await prefs.setString('ui_theme_mode', modeString);
    } catch (_) {
      // Ignore save errors
    }
  }

  Future<void> toggle() async {
    final nextMode = (mode.value == ThemeMode.dark) ? ThemeMode.light : ThemeMode.dark;
    await set(nextMode);
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
