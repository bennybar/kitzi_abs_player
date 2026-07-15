package com.bennybar.kitzi.ui.settings

import com.bennybar.kitzi.data.legacy.FlutterPrefs
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put

/**
 * Export/import of the user's preferences as JSON.
 *
 * Deliberately covers only the `ui_*` / behaviour settings — never the server
 * URL or the tokens. A settings backup is something people paste into chats and
 * issue trackers, and it must not be a credential leak.
 */
object SettingsBackup {

    private val json = Json { prettyPrint = true; ignoreUnknownKeys = true }

    private val booleanKeys = listOf(
        "ui_show_series_tab",
        "ui_author_view_enabled",
        "ui_letter_scroll_enabled",
        "ui_letter_scroll_books_alpha",
        "ui_player_gradient_background",
        "ui_mini_player_collapsed",
        "ui_progress_bar_chapterized",
        "ui_hide_series_when_same_as_author",
        "ui_player_scrolling_single_line_title",
        "ui_full_player_as_tab",
        "downloads_wifi_only",
        "downloads_auto_delete_on_finish",
        "smart_rewind_enabled",
    )

    private val intKeys = listOf(
        "ui_series_items_per_row",
        "ui_series_min_books",
        "ui_seek_backward_seconds",
        "ui_seek_forward_seconds",
        "ui_surface_tint_level",
        "ui_font_scale_percent_v2",
    )

    private val stringKeys = listOf(
        "ui_theme_mode",
        "ui_progress_primary",
        "ui_player_cover_size",
        "downloads_base_subfolder",
    )

    fun export(prefs: FlutterPrefs): String = json.encodeToString(
        JsonObject.serializer(),
        buildJsonObject {
            booleanKeys.forEach { if (prefs.contains(it)) put(it, prefs.getBoolean(it, false)) }
            intKeys.forEach { if (prefs.contains(it)) put(it, prefs.getInt(it, 0)) }
            stringKeys.forEach { prefs.getString(it)?.let { v -> put(it, v) } }
        },
    )

    /** Returns false if the text isn't valid settings JSON, leaving prefs untouched. */
    fun import(prefs: FlutterPrefs, text: String): Boolean {
        val root = runCatching { json.parseToJsonElement(text).jsonObject }.getOrNull() ?: return false

        root.forEach { (key, value) ->
            val primitive = value as? JsonPrimitive ?: return@forEach
            when (key) {
                in booleanKeys -> primitive.booleanOrNull?.let { prefs.putBoolean(key, it) }
                in intKeys -> primitive.intOrNull?.let { prefs.putInt(key, it) }
                in stringKeys -> prefs.putString(key, primitive.content)
                // Anything else in the file is ignored rather than blindly written.
            }
        }
        return true
    }
}
