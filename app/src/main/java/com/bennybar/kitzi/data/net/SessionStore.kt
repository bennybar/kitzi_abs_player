package com.bennybar.kitzi.data.net

import android.content.Context
import android.content.SharedPreferences
import androidx.core.content.edit
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import com.bennybar.kitzi.data.legacy.FlutterSecureStorage
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonPrimitive
import java.time.Instant

/**
 * Server URL, tokens and custom headers.
 *
 * Mirrors how the Flutter app split these (api_client.dart): the base URL,
 * access token, its assumed expiry and the custom headers all sit in plain
 * prefs; only the refresh token is kept encrypted. Reusing the same plain keys
 * means an updated user is already logged in with nothing to migrate.
 *
 * The refresh token is the one thing that moves stores: it is read once out of
 * the Flutter `flutter_secure_storage` blob and re-homed into
 * EncryptedSharedPreferences, which is where we keep it from then on.
 */
class SessionStore(context: Context) {

    private val prefs = FlutterPrefs(context)
    private val legacySecure = FlutterSecureStorage(context)

    private val secure: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        SECURE_PREFS,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    var baseUrl: String?
        get() = prefs.getString(FlutterPrefs.KEY_BASE_URL)
        set(value) {
            if (value == null) prefs.remove(FlutterPrefs.KEY_BASE_URL)
            else prefs.putString(FlutterPrefs.KEY_BASE_URL, normalizeBaseUrl(value))
        }

    var accessToken: String?
        get() = prefs.getString(FlutterPrefs.KEY_ACCESS_TOKEN)
        set(value) {
            if (value == null) prefs.remove(FlutterPrefs.KEY_ACCESS_TOKEN)
            else prefs.putString(FlutterPrefs.KEY_ACCESS_TOKEN, value)
        }

    var accessExpiry: Instant?
        get() = prefs.getString(FlutterPrefs.KEY_ACCESS_EXPIRY)?.let {
            runCatching { Instant.parse(it) }.getOrNull()
        }
        set(value) {
            if (value == null) prefs.remove(FlutterPrefs.KEY_ACCESS_EXPIRY)
            else prefs.putString(FlutterPrefs.KEY_ACCESS_EXPIRY, value.toString())
        }

    /**
     * Reads from our own encrypted store, falling back once to the token the
     * Flutter app left behind (which is what keeps users logged in across the
     * update). If the old blob can't be decrypted the user simply logs in again.
     */
    var refreshToken: String?
        get() {
            secure.getString(KEY_REFRESH, null)?.let { return it }
            val adopted = legacySecure.read(FlutterSecureStorage.KEY_REFRESH_TOKEN) ?: return null
            secure.edit { putString(KEY_REFRESH, adopted) }
            return adopted
        }
        set(value) = secure.edit {
            if (value == null) remove(KEY_REFRESH) else putString(KEY_REFRESH, value)
        }

    /** For Zero-Trust tunnels / service tokens; sent on every request. */
    var customHeaders: Map<String, String>
        get() {
            val raw = prefs.getString(FlutterPrefs.KEY_CUSTOM_HEADERS) ?: return emptyMap()
            return runCatching {
                Json.parseToJsonElement(raw).let { el ->
                    el.let { it as? kotlinx.serialization.json.JsonObject }
                        ?.mapValues { (_, v) -> v.jsonPrimitive.content }
                        ?.filterKeys { it.isNotBlank() }
                        ?.filterValues { it.isNotBlank() }
                        .orEmpty()
                }
            }.getOrElse { emptyMap() }
        }
        set(value) {
            val sanitized = value
                .mapKeys { it.key.trim() }
                .mapValues { it.value.trim() }
                .filterKeys { it.isNotEmpty() }
                .filterValues { it.isNotEmpty() }
            if (sanitized.isEmpty()) prefs.remove(FlutterPrefs.KEY_CUSTOM_HEADERS)
            else prefs.putString(FlutterPrefs.KEY_CUSTOM_HEADERS, Json.encodeToString(sanitized))
        }

    /**
     * ABS never reports token expiry, so this is only a hint used to refresh
     * proactively. A real 401 is the authoritative backstop.
     */
    fun hasFreshAccessToken(leewaySeconds: Long = 60): Boolean {
        val exp = accessExpiry ?: return false
        return exp.isAfter(Instant.now().plusSeconds(leewaySeconds))
    }

    fun setAccess(token: String, expiry: Instant) {
        accessToken = token
        accessExpiry = expiry
    }

    fun clearTokens() {
        accessToken = null
        accessExpiry = null
        refreshToken = null
    }

    companion object {
        private const val SECURE_PREFS = "kitzi_secure"
        private const val KEY_REFRESH = "abs_refresh"

        /** Same rules as api_client.dart setBaseUrl: default to https, no trailing slash. */
        fun normalizeBaseUrl(input: String): String {
            var url = input.trim()
            if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://$url"
            return url.trimEnd('/')
        }
    }
}
