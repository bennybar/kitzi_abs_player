import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UiPrefs {
  static final ValueNotifier<bool> seriesTabVisible = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> collectionsTabVisible = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> authorViewEnabled = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> pinSettings = ValueNotifier<bool>(false);

  static const String _kSeries = 'ui_show_series_tab';
  static const String _kCollections = 'ui_show_collections_tab';
  static const String _kAuthorView = 'ui_author_view_enabled';

  static Future<void> loadFromPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      seriesTabVisible.value = prefs.getBool(_kSeries) ?? false;
      collectionsTabVisible.value = prefs.getBool(_kCollections) ?? false;
      authorViewEnabled.value = prefs.getBool(_kAuthorView) ?? true;
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

  static Future<void> setCollectionsVisible(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kCollections, value);
    } catch (_) {}
    collectionsTabVisible.value = value;
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
}


