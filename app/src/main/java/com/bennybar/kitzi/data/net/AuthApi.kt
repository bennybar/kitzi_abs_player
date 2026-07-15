package com.bennybar.kitzi.data.net

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Headers
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import java.time.Instant

/**
 * The Audiobookshelf auth endpoints. Note these are NOT under `/api` — it is
 * `/login`, `/auth/refresh`, `/logout`, `/status` (see api_client.dart).
 *
 * Kept on raw OkHttp rather than Retrofit because two of them need behaviour
 * Retrofit hides: the OIDC start must NOT follow its redirect (we need the
 * Location header and the Set-Cookie values), and login/refresh accept tokens at
 * either `user.accessToken` or the top level depending on server version.
 */
class AuthApi(
    private val client: OkHttpClient,
    private val session: SessionStore,
) {
    private val json = Json { ignoreUnknownKeys = true }

    /** Tokens as returned by /login, /auth/refresh and the OIDC callback. */
    data class Tokens(val access: String, val refresh: String?)

    fun login(baseUrl: String, username: String, password: String): Boolean {
        val base = SessionStore.normalizeBaseUrl(baseUrl)
        session.baseUrl = base

        val body = json.encodeToString(mapOf("username" to username, "password" to password))
            .toRequestBody(JSON_MEDIA)

        val request = Request.Builder()
            .url("$base/login")
            .headers(baseHeaders())
            .header("x-return-tokens", "true")
            .post(body)
            .build()

        val tokens = client.newCall(request).execute().use { resp ->
            if (!resp.isSuccessful) return false
            parseTokens(resp.body?.string()) ?: return false
        }
        storeTokens(tokens)
        return true
    }

    /**
     * Exchanges the refresh token for a new access token. Callers must go
     * through [TokenRefresher] rather than calling this directly, so that
     * concurrent 401s don't each rotate the refresh token.
     */
    fun refresh(): Boolean {
        val base = session.baseUrl ?: return false
        val refresh = session.refreshToken ?: return false

        val request = Request.Builder()
            .url("$base/auth/refresh")
            .headers(baseHeaders())
            .header("x-refresh-token", refresh)
            .post(ByteArray(0).toRequestBody())
            .build()

        val tokens = runCatching {
            client.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return false
                parseTokens(resp.body?.string())
            }
        }.getOrNull() ?: return false

        storeTokens(tokens)
        return true
    }

    fun logout() {
        val base = session.baseUrl
        val refresh = session.refreshToken
        try {
            if (base != null && refresh != null) {
                val request = Request.Builder()
                    .url("$base/logout")
                    .headers(baseHeaders())
                    .header("x-refresh-token", refresh)
                    .post(ByteArray(0).toRequestBody())
                    .build()
                runCatching { client.newCall(request).execute().close() }
            }
        } finally {
            session.clearTokens()
        }
    }

    /** Unauthenticated status; `authMethods` tells the login screen whether to offer SSO. */
    fun publicStatus(baseUrl: String): JsonObject? {
        val base = SessionStore.normalizeBaseUrl(baseUrl)
        val request = Request.Builder().url("$base/status").headers(baseHeaders()).get().build()
        return runCatching {
            client.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val body = resp.body?.string().orEmpty()
                if (body.isEmpty()) null else json.parseToJsonElement(body).jsonObject
            }
        }.getOrNull()
    }

    fun authMethods(baseUrl: String): List<String> =
        publicStatus(baseUrl)
            ?.get("authMethods")
            ?.let { it as? kotlinx.serialization.json.JsonArray }
            ?.map { it.jsonPrimitive.content }
            ?: emptyList()

    /**
     * Both login and refresh may return the tokens nested under `user` or at the
     * top level, depending on the server version — accept either.
     */
    private fun parseTokens(body: String?): Tokens? {
        if (body.isNullOrEmpty()) return null
        val root = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return null
        val user = root["user"]?.let { it as? JsonObject }

        fun pick(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
            (user?.get(key) ?: root[key])?.jsonPrimitive?.content?.takeIf { it.isNotEmpty() }
        }

        val access = pick("accessToken", "token") ?: return null
        return Tokens(access, pick("refreshToken"))
    }

    /**
     * ABS does not report expiry, so we assume one. A server that gave us no
     * refresh token can't be re-upped, so we assume much less of it.
     */
    private fun storeTokens(tokens: Tokens) {
        val ttlHours = if (tokens.refresh.isNullOrEmpty()) 1L else 12L
        session.setAccess(tokens.access, Instant.now().plusSeconds(ttlHours * 3600))
        if (!tokens.refresh.isNullOrEmpty()) session.refreshToken = tokens.refresh
    }

    private fun baseHeaders(): Headers = Headers.Builder().apply {
        set("User-Agent", USER_AGENT)
        session.customHeaders.forEach { (k, v) -> set(k, v) }
    }.build()

    companion object {
        /**
         * Deliberately unchanged from the Flutter app: the server sees the same
         * client string it always has, so any server-side rules keyed on it keep
         * working. (Yes, it still says Flutter.)
         */
        const val USER_AGENT = "Kitzi-ABS-Player/1.0 (Flutter)"
        private val JSON_MEDIA = "application/json".toMediaType()
    }
}
