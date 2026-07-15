package com.bennybar.kitzi.ui

import androidx.compose.runtime.mutableStateOf
import com.bennybar.kitzi.data.legacy.FlutterPrefs

/**
 * The subset of `ui_*` settings that change what the UI shows and therefore must
 * be observable, so toggling them on the Settings screen updates the rest of the
 * app live (nav tabs, player affordances, list rows) instead of only after a
 * relaunch.
 *
 * Behaviour-only settings (smart rewind, pause-cancels-timer, bluetooth auto-play)
 * are NOT here — they're read from prefs at the moment they matter.
 */
object UiPrefsState {

    val showAuthorsTab = mutableStateOf(true)
    val showSeriesTab = mutableStateOf(false)
    val fullPlayerAsTab = mutableStateOf(true)
    val resumeFromHistory = mutableStateOf(true)
    val dualProgress = mutableStateOf(true)
    val hideSeriesWhenSameAsAuthor = mutableStateOf(true)
    val letterScrollEnabled = mutableStateOf(false)
    val letterScrollBooksAlpha = mutableStateOf(false)
    /** Screen-transition duration multiplier: "fast"=0.6, "normal"=1, "smooth"=1.8. */
    val animationSpeed = mutableStateOf("normal")

    val animationScale: Float
        get() = when (animationSpeed.value) {
            "fast" -> 0.55f
            "smooth" -> 1.8f
            else -> 1f
        }

    fun load(prefs: FlutterPrefs) {
        showAuthorsTab.value = prefs.getBoolean(K_AUTHORS, true)
        showSeriesTab.value = prefs.getBoolean(K_SERIES, false)
        fullPlayerAsTab.value = prefs.getBoolean(K_FULL_PLAYER, true)
        resumeFromHistory.value = prefs.getBoolean(K_RESUME_HISTORY, true)
        dualProgress.value = prefs.getBoolean(K_DUAL_PROGRESS, true)
        hideSeriesWhenSameAsAuthor.value = prefs.getBoolean(K_HIDE_SERIES, true)
        letterScrollEnabled.value = prefs.getBoolean(K_LETTER, false)
        letterScrollBooksAlpha.value = prefs.getBoolean(K_LETTER_ALPHA, false)
        animationSpeed.value = prefs.getString(K_ANIM_SPEED) ?: "normal"
    }

    fun setAnimationSpeed(prefs: FlutterPrefs, value: String) {
        prefs.putString(K_ANIM_SPEED, value)
        animationSpeed.value = value
    }

    /** Called by the Settings toggles: updates both the live state and the pref. */
    fun set(prefs: FlutterPrefs, key: String, value: Boolean) {
        prefs.putBoolean(key, value)
        when (key) {
            K_AUTHORS -> showAuthorsTab.value = value
            K_SERIES -> showSeriesTab.value = value
            K_FULL_PLAYER -> fullPlayerAsTab.value = value
            K_RESUME_HISTORY -> resumeFromHistory.value = value
            K_DUAL_PROGRESS -> dualProgress.value = value
            K_HIDE_SERIES -> hideSeriesWhenSameAsAuthor.value = value
            K_LETTER -> letterScrollEnabled.value = value
            K_LETTER_ALPHA -> letterScrollBooksAlpha.value = value
        }
    }

    /** The keys this holder owns, so Settings can route them here. */
    val ownedKeys = setOf(
        K_AUTHORS, K_SERIES, K_FULL_PLAYER, K_RESUME_HISTORY,
        K_DUAL_PROGRESS, K_HIDE_SERIES, K_LETTER, K_LETTER_ALPHA,
    )

    const val K_AUTHORS = "ui_author_view_enabled"
    const val K_SERIES = "ui_show_series_tab"
    const val K_FULL_PLAYER = "ui_full_player_as_tab"
    const val K_RESUME_HISTORY = "ui_resume_from_history_enabled"
    const val K_DUAL_PROGRESS = "ui_dual_progress_enabled"
    const val K_HIDE_SERIES = "ui_hide_series_when_same_as_author"
    const val K_LETTER = "ui_letter_scroll_enabled"
    const val K_LETTER_ALPHA = "ui_letter_scroll_books_alpha"
    const val K_ANIM_SPEED = "ui_animation_speed"
}
