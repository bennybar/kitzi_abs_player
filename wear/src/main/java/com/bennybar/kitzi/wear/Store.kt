package com.bennybar.kitzi.wear

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import kotlinx.serialization.json.Json

/** A book on the Continue Listening shelf. */
@Serializable
data class Book(
    val id: String,
    val title: String,
    val author: String? = null,
    val durationSec: Double = 0.0,
    val currentTimeSec: Double = 0.0,
    val lastUpdate: Long = 0L,
)

/** Where this watch last was in a book, and whether the server has it yet. */
data class LocalPosition(val sec: Double, val savedAt: Long, val pending: Boolean, val finished: Boolean)

/**
 * Everything the watch keeps: the sign-in (encrypted), the last shelf (so it shows
 * offline), settings, and the local position per book.
 */
class Store(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("kitzi_wear", Context.MODE_PRIVATE)
    private val secure: SharedPreferences = runCatching {
        EncryptedSharedPreferences.create(
            context,
            "kitzi_wear_secure",
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }.getOrElse {
        // A keystore that can't be opened (restored backup, OS bug) must not crash
        // the app; signing in again is the cost.
        Log.w("Store", "encrypted prefs unavailable", it)
        context.deleteSharedPreferences("kitzi_wear_secure")
        context.getSharedPreferences("kitzi_wear_secure_fallback", Context.MODE_PRIVATE)
    }

    var baseUrl: String?
        get() = secure.getString("base_url", null)
        set(v) = secure.edit { putString("base_url", v) }
    /** Bearer token: the long-lived API token from the phone, or this watch's own access token. */
    var accessToken: String?
        get() = secure.getString("access_token", null)
        set(v) = secure.edit { putString("access_token", v) }
    /** Only when signed in on the watch itself (its own session); null for a phone sign-in. */
    var refreshToken: String?
        get() = secure.getString("refresh_token", null)
        set(v) = secure.edit { putString("refresh_token", v) }
    var username: String?
        get() = secure.getString("username", null)
        set(v) = secure.edit { putString("username", v) }
    var headers: Map<String, String>
        get() = secure.getString("headers", null)
            ?.let { runCatching { json.decodeFromString(HEADERS, it) }.getOrNull() }.orEmpty()
        set(v) = secure.edit { putString("headers", json.encodeToString(HEADERS, v)) }

    val signedIn: Boolean get() = baseUrl != null && accessToken != null

    fun signIn(base: String, access: String, refresh: String?, user: String?, extraHeaders: Map<String, String>) {
        secure.edit {
            clear()
            putString("base_url", base)
            putString("access_token", access)
            putString("refresh_token", refresh)
            putString("username", user)
            putString("headers", json.encodeToString(HEADERS, extraHeaders))
        }
    }

    /** Signing out forgets the account and its positions; downloads stay on the watch. */
    fun signOut() {
        secure.edit { clear() }
        prefs.edit {
            prefs.all.keys.filter { it.startsWith("pos:") || it == "shelf" }.forEach { remove(it) }
        }
    }

    /** Downloads use Wi-Fi only (off: Wi-Fi or cellular). */
    var wifiOnly: Boolean
        get() = prefs.getBoolean("wifi_only", false)
        set(v) = prefs.edit { putBoolean("wifi_only", v) }

    var shelf: List<Book>
        get() = prefs.getString("shelf", null)
            ?.let { runCatching { json.decodeFromString(BOOKS, it) }.getOrNull() }.orEmpty()
        set(v) = prefs.edit { putString("shelf", json.encodeToString(BOOKS, v)) }

    var lastBookId: String?
        get() = prefs.getString("last_book", null)
        set(v) = prefs.edit { putString("last_book", v) }

    fun position(itemId: String): LocalPosition? {
        val raw = prefs.getString("pos:$itemId", null) ?: return null
        val p = raw.split('|')
        if (p.size < 4) return null
        return LocalPosition(p[0].toDouble(), p[1].toLong(), p[2] == "1", p[3] == "1")
    }

    fun savePosition(itemId: String, pos: LocalPosition) = prefs.edit {
        putString("pos:$itemId", "${pos.sec}|${pos.savedAt}|${if (pos.pending) 1 else 0}|${if (pos.finished) 1 else 0}")
    }

    fun pendingIds(): List<String> = prefs.all.keys
        .filter { it.startsWith("pos:") }
        .map { it.removePrefix("pos:") }
        .filter { position(it)?.pending == true }

    companion object {
        val json = Json { ignoreUnknownKeys = true; isLenient = true }
        private val HEADERS = MapSerializer(String.serializer(), String.serializer())
        private val BOOKS = ListSerializer(Book.serializer())
    }
}
