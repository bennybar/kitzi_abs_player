package com.bennybar.kitzi.data.legacy

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit

/**
 * The settings store, which is deliberately the *same* file the Flutter app
 * wrote: `FlutterSharedPreferences.xml`, every key prefixed `flutter.`.
 *
 * Reusing it rather than migrating into DataStore means settings survive the
 * update with no migration step at all (nothing to get wrong, nothing to run
 * once and hope), and a user who rolls back to the Flutter APK still has their
 * settings. The cost is living with Flutter's value encoding, which this class
 * exists to hide:
 *
 *  - Dart `int` is 64-bit and is written with `putLong` — reading it with
 *    `getInt` throws ClassCastException. This is the one that bites.
 *  - Dart `double` is written as a String behind [DOUBLE_PREFIX].
 *  - Dart `List<String>` is written as a String behind [LIST_PREFIX].
 *  - `bool` and `String` are stored natively.
 *
 * See shared_preferences_android's LegacySharedPreferencesPlugin.
 */
class FlutterPrefs(context: Context) {

    private val prefs: SharedPreferences =
        context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)

    private fun k(key: String) = KEY_PREFIX + key

    fun getString(key: String): String? = prefs.getString(k(key), null)

    fun putString(key: String, value: String) = prefs.edit { putString(k(key), value) }

    fun getBoolean(key: String, default: Boolean): Boolean =
        if (prefs.contains(k(key))) prefs.getBoolean(k(key), default) else default

    fun putBoolean(key: String, value: Boolean) = prefs.edit { putBoolean(k(key), value) }

    /** Dart ints are 64-bit and land in the XML as `<long>`. */
    fun getInt(key: String, default: Int): Int =
        if (prefs.contains(k(key))) prefs.getLong(k(key), default.toLong()).toInt() else default

    fun putInt(key: String, value: Int) = prefs.edit { putLong(k(key), value.toLong()) }

    fun getDouble(key: String, default: Double): Double {
        val raw = prefs.getString(k(key), null) ?: return default
        if (!raw.startsWith(DOUBLE_PREFIX)) return default
        return raw.removePrefix(DOUBLE_PREFIX).toDoubleOrNull() ?: default
    }

    fun putDouble(key: String, value: Double) =
        prefs.edit { putString(k(key), DOUBLE_PREFIX + value.toString()) }

    fun remove(key: String) = prefs.edit { remove(k(key)) }

    fun contains(key: String): Boolean = prefs.contains(k(key))

    companion object {
        const val FILE_NAME = "FlutterSharedPreferences"
        const val KEY_PREFIX = "flutter."

        // Value-type markers from shared_preferences_android.
        const val DOUBLE_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBEb3VibGUu"
        const val LIST_PREFIX = "VGhpcyBpcyB0aGUgcHJlZml4IGZvciBhIGxpc3Qu"

        // Session (all plain — only the refresh token is encrypted; see FlutterSecureStorage).
        const val KEY_BASE_URL = "abs_base_url"
        const val KEY_ACCESS_TOKEN = "abs_access"
        const val KEY_ACCESS_EXPIRY = "abs_access_exp"
        const val KEY_CUSTOM_HEADERS = "abs_custom_headers"

        // Library + downloads.
        const val KEY_LIBRARY_ID = "books_library_id"
        const val KEY_DOWNLOADS_SUBFOLDER = "downloads_base_subfolder"
    }
}
