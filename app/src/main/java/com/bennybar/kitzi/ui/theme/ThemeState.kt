package com.bennybar.kitzi.ui.theme

import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import com.bennybar.kitzi.data.legacy.FlutterPrefs

enum class ThemeMode { LIGHT, DARK, SYSTEM }

/**
 * Theme + text-scale state, all read from and written to the same pref keys the
 * Flutter app used, so the user's choices survive the update.
 *
 * Defaults match the Flutter app: dark theme, 100% font scale.
 */
object ThemeState {

    val mode = mutableStateOf(ThemeMode.DARK)

    /** Percent, 80..120 in steps of 5 (ui_font_scale_percent_v2). 100 = default. */
    val fontScalePercent = mutableIntStateOf(100)

    /**
     * The multiplier applied to text sizes. The base is set so that 100% renders
     * at what used to read as ~90% — the previous base (0.987) was a touch large.
     */
    val fontScale: Float get() = 0.888f * (fontScalePercent.intValue / 100f)

    fun load(prefs: FlutterPrefs) {
        mode.value = when (prefs.getString(KEY_MODE)) {
            "light" -> ThemeMode.LIGHT
            "system" -> ThemeMode.SYSTEM
            else -> ThemeMode.DARK
        }
        fontScalePercent.intValue = normalizeFont(prefs.getInt(KEY_FONT, 100))
    }

    fun set(next: ThemeMode, prefs: FlutterPrefs) {
        mode.value = next
        prefs.putString(KEY_MODE, next.name.lowercase())
    }

    fun setFontScale(percent: Int, prefs: FlutterPrefs) {
        val n = normalizeFont(percent)
        fontScalePercent.intValue = n
        prefs.putInt(KEY_FONT, n)
    }

    private fun normalizeFont(percent: Int): Int {
        val clamped = percent.coerceIn(80, 120)
        val step = ((clamped - 80) / 5.0).toInt()
        return 80 + step * 5
    }

    private const val KEY_MODE = "ui_theme_mode"
    private const val KEY_FONT = "ui_font_scale_percent_v2"
}
