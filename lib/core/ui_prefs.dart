import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ProgressPrimary {
  book,
  chapter,
}

enum PlayerCoverSize { small, medium, large, extraLarge }

class UiPrefs {
  static final ValueNotifier<bool> seriesTabVisible = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> authorViewEnabled = ValueNotifier<bool>(true);
  static final ValueNotifier<bool> pinSettings = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> letterScrollEnabled = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> letterScrollBooksAlpha = ValueNotifier<bool>(false);
  static final ValueNotifier<ProgressPrimary> progressPrimary = ValueNotifier<ProgressPrimary>(ProgressPrimary.book);
  static final ValueNotifier<bool> playerGradientBackground = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> miniPlayerCollapsed = ValueNotifier<bool>(false);
  static final ValueNotifier<bool> progressBarChapterized = ValueNotifier<bool>(true); // Default to true
  static final ValueNotifier<PlayerCoverSize> playerCoverSize =
      ValueNotifier<PlayerCoverSize>(PlayerCoverSize.large);
  static final ValueNotifier<bool> hideSeriesWhenSameAsAuthor = ValueNotifier<bool>(true); // Default to true
  static final ValueNotifier<int> seriesItemsPerRow = ValueNotifier<int>(2); // Default to 2
  static final ValueNotifier<int> seekBackwardSeconds = ValueNotifier<int>(30); // Default to 30 seconds
  static final ValueNotifier<int> seekForwardSeconds = ValueNotifier<int>(30); // Default to 30 seconds
  static final ValueNotifier<bool> playerScrollingSingleLineTitle = ValueNotifier<bool>(false); // Default to false
  static final ValueNotifier<bool> fullPlayerAsTab = ValueNotifier<bool>(true);

  static const String _kSeries = 'ui_show_series_tab';
  static const String _kAuthorView = 'ui_author_view_enabled';
  static const String _kLetterScroll = 'ui_letter_scroll_enabled';
  static const String _kLetterScrollBooksAlpha = 'ui_letter_scroll_books_alpha';
  static const String _kProgressPrimary = 'ui_progress_primary';
  static const String _kPlayerGradient = 'ui_player_gradient_background';
  static const String _kMiniCollapsed = 'ui_mini_player_collapsed';
  static const String _kProgressBarChapterized = 'ui_progress_bar_chapterized';
  static const String _kPlayerCoverSize = 'ui_player_cover_size';
  static const String _kHideSeriesWhenSameAsAuthor = 'ui_hide_series_when_same_as_author';
  static const String _kSeriesItemsPerRow = 'ui_series_items_per_row';
  static const String _kSeekBackwardSeconds = 'ui_seek_backward_seconds';
  static const String _kSeekForwardSeconds = 'ui_seek_forward_seconds';
  static const String _kPlayerScrollingSingleLineTitle = 'ui_player_scrolling_single_line_title';
  static const String _kFullPlayerAsTab = 'ui_full_player_as_tab';

  static Future<void> loadFromPrefs({BuildContext? context}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      seriesTabVisible.value = prefs.getBool(_kSeries) ?? false;
      authorViewEnabled.value = prefs.getBool(_kAuthorView) ?? true;
      letterScrollEnabled.value = prefs.getBool(_kLetterScroll) ?? false;
      letterScrollBooksAlpha.value = prefs.getBool(_kLetterScrollBooksAlpha) ?? false;
      progressPrimary.value = _parseProgressPrimary(prefs.getString(_kProgressPrimary));
      playerGradientBackground.value = prefs.getBool(_kPlayerGradient) ?? true;
      miniPlayerCollapsed.value = prefs.getBool(_kMiniCollapsed) ?? false;
      progressBarChapterized.value = prefs.getBool(_kProgressBarChapterized) ?? true;
      playerCoverSize.value = _parseCoverSize(prefs.getString(_kPlayerCoverSize));
      hideSeriesWhenSameAsAuthor.value = prefs.getBool(_kHideSeriesWhenSameAsAuthor) ?? true;
      seriesItemsPerRow.value = prefs.getInt(_kSeriesItemsPerRow) ?? 2;
      seekBackwardSeconds.value = prefs.getInt(_kSeekBackwardSeconds) ?? 30;
      seekForwardSeconds.value = prefs.getInt(_kSeekForwardSeconds) ?? 30;
      playerScrollingSingleLineTitle.value =
          prefs.getBool(_kPlayerScrollingSingleLineTitle) ?? false;
      fullPlayerAsTab.value = prefs.getBool(_kFullPlayerAsTab) ?? true;
    } catch (_) {}
  }

  static Future<void> setFullPlayerAsTab(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kFullPlayerAsTab, value);
    } catch (_) {}
    fullPlayerAsTab.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setMiniPlayerCollapsed(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kMiniCollapsed, value);
    } catch (_) {}
    miniPlayerCollapsed.value = value;
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

  static Future<void> setProgressPrimary(ProgressPrimary value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kProgressPrimary, value.name);
    } catch (_) {}
    progressPrimary.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setPlayerGradientBackground(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPlayerGradient, value);
    } catch (_) {}
    playerGradientBackground.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setProgressBarChapterized(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kProgressBarChapterized, value);
    } catch (_) {}
    progressBarChapterized.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setPlayerCoverSize(PlayerCoverSize value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kPlayerCoverSize, value.name);
    } catch (_) {}
    playerCoverSize.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setHideSeriesWhenSameAsAuthor(bool value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kHideSeriesWhenSameAsAuthor, value);
    } catch (_) {}
    hideSeriesWhenSameAsAuthor.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setSeriesItemsPerRow(int value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSeriesItemsPerRow, value);
    } catch (_) {}
    seriesItemsPerRow.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setSeekBackwardSeconds(int value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSeekBackwardSeconds, value);
    } catch (_) {}
    seekBackwardSeconds.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setSeekForwardSeconds(int value, {bool pinToSettingsOnChange = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_kSeekForwardSeconds, value);
    } catch (_) {}
    seekForwardSeconds.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static Future<void> setPlayerScrollingSingleLineTitle(
    bool value, {
    bool pinToSettingsOnChange = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_kPlayerScrollingSingleLineTitle, value);
    } catch (_) {}
    playerScrollingSingleLineTitle.value = value;
    if (pinToSettingsOnChange) pinSettings.value = true;
  }

  static ProgressPrimary _parseProgressPrimary(String? raw) {
    if (raw == ProgressPrimary.chapter.name) return ProgressPrimary.chapter;
    return ProgressPrimary.book;
  }

  static PlayerCoverSize _parseCoverSize(String? raw) {
    switch (raw) {
      case 'small':
        return PlayerCoverSize.small;
      case 'medium':
        return PlayerCoverSize.medium;
      case 'extraLarge':
        return PlayerCoverSize.extraLarge;
      case 'large':
      default:
        return PlayerCoverSize.large;
    }
  }
}


