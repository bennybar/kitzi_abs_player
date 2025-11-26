import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UiPrefs {
  static final ValueNotifier<bool> seriesTabVisible = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> authorViewEnabled = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> pinSettings = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> waveformAnimationEnabled = ValueNotifier<bool>(false); // Default to false, will be set based on device size
  static final ValueNotifier<bool> letterScrollEnabled = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> letterScrollBooksAlpha = ValueNotifier<bool>(false);

  static const String _kSeries = 'ui_show_series_tab';
  static const String _kAuthorView = 'ui_author_view_enabled';
  static const String _kWaveformAnimation = 'ui_waveform_animation_enabled';
  static const String _kLetterScroll = 'ui_letter_scroll_enabled';
  static const String _kLetterScrollBooksAlpha = 'ui_letter_scroll_books_alpha';

  /// Calculate screen diagonal size in inches
  static double getScreenDiagonalInches(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;
    
    // Calculate diagonal in logical pixels
    final diagonalLogicalPixels = sqrt(pow(size.width, 2) + pow(size.height, 2));
    
    // Convert to physical pixels
    final diagonalPhysicalPixels = diagonalLogicalPixels * devicePixelRatio;
    
    // Assume standard DPI (160 for Android baseline)
    const baseDPI = 160.0;
    
    // Calculate inches
    return diagonalPhysicalPixels / baseDPI;
  }

  static Future<void> loadFromPrefs({BuildContext? context}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      seriesTabVisible.value = prefs.getBool(_kSeries) ?? false;
      authorViewEnabled.value = prefs.getBool(_kAuthorView) ?? true;
      
      // For waveform animation, use device size to determine default if not set
      if (prefs.containsKey(_kWaveformAnimation)) {
        waveformAnimationEnabled.value = prefs.getBool(_kWaveformAnimation)!;
      } else if (context != null) {
        // Default based on device size: disabled for screens < 6.2 inches
        final screenSize = getScreenDiagonalInches(context);
        final defaultValue = screenSize >= 6.2;
        waveformAnimationEnabled.value = defaultValue;
        // Save the default for future use
        await prefs.setBool(_kWaveformAnimation, defaultValue);
        // Waveform animation default set
      }
      // If context not available and key doesn't exist, keep current value (default is true from initialization)
    } catch (_) {}
  }
  
  /// Initialize waveform animation with device-based default if not already set
  static Future<void> ensureWaveformDefault(BuildContext context) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_kWaveformAnimation)) {
        final screenSize = getScreenDiagonalInches(context);
        final defaultValue = screenSize >= 6.2;
        waveformAnimationEnabled.value = defaultValue;
        await prefs.setBool(_kWaveformAnimation, defaultValue);
        // Waveform animation default initialized
      }
      letterScrollEnabled.value = prefs.getBool(_kLetterScroll) ?? false;
      letterScrollBooksAlpha.value = prefs.getBool(_kLetterScrollBooksAlpha) ?? false;
    } catch (_) {}
  }

  static Future<void> setSeriesVisible(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kSeries, value);
    } catch (_) {}
    seriesTabVisible.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }


  static Future<void> setAuthorViewEnabled(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kAuthorView, value);
    } catch (_) {}
    authorViewEnabled.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setWaveformAnimationEnabled(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kWaveformAnimation, value);
    } catch (_) {}
    waveformAnimationEnabled.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setLetterScrollEnabled(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLetterScroll, value);
    } catch (_) {}
    letterScrollEnabled.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setLetterScrollBooksAlpha(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kLetterScrollBooksAlpha, value);
    } catch (_) {}
    letterScrollBooksAlpha.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }
}


