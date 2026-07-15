package com.bennybar.kitzi.data.net

import android.net.Uri
import android.util.Base64
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.OkHttpClient
import okhttp3.Request
import java.security.MessageDigest
import java.security.SecureRandom
import java.time.Instant

/**
 * OIDC / SSO login, ported from AuthRepository.openIdBegin/openIdFinish.
 *
 * The flow is two-legged and slightly unusual:
 *  1. GET /auth/openid WITHOUT following the redirect, so we can read both the
 *     IdP authorize URL (the Location header) and the session cookies ABS sets.
 *     Following the redirect would consume them and the callback would fail.
 *  2. After the browser returns to `audiobookshelf://oauth`, GET
 *     /auth/openid/callback replaying those cookies, which returns the tokens.
 */
class OidcClient(
    private val session: SessionStore,
    private val authApi: AuthApi,
) {
    // A client that does NOT follow redirects — step 1 depends on seeing the 302.
    private val client = OkHttpClient.Builder()
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

    private val json = Json { ignoreUnknownKeys = true }

    /** PKCE + state, held between [begin] and [finish]. */
    private var verifier: String? = null
    private var state: String? = null
    private var cookies: String? = null

    /** Returns the IdP authorize URL to open in a browser, or null on failure. */
    fun begin(baseUrl: String): String? {
        val base = SessionStore.normalizeBaseUrl(baseUrl)
        val codeVerifier = randomUrlSafe(64)
        val challenge = base64Url(sha256(codeVerifier.toByteArray(Charsets.US_ASCII)))
        val requestState = randomUrlSafe(16)

        val url = Uri.parse("$base/auth/openid").buildUpon()
            .appendQueryParameter("response_type", "code")
            .appendQueryParameter("client_id", CLIENT_ID)
            .appendQueryParameter("redirect_uri", REDIRECT_URI)
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("code_challenge_method", "S256")
            .appendQueryParameter("state", requestState)
            .build()
            .toString()

        val request = Request.Builder().url(url)
            .header("User-Agent", AuthApi.USER_AGENT)
            .apply { session.customHeaders.forEach { (k, v) -> header(k, v) } }
            .get()
            .build()

        return runCatching {
            client.newCall(request).execute().use { resp ->
                val location = resp.header("Location")?.takeIf { it.isNotEmpty() } ?: return null
                verifier = codeVerifier
                state = requestState
                cookies = resp.headers("Set-Cookie")
                    .mapNotNull { it.substringBefore(';').takeIf { c -> c.isNotBlank() } }
                    .joinToString("; ")
                location
            }
        }.getOrNull()
    }

    /** Completes SSO from the `audiobookshelf://oauth?...` callback. */
    fun finish(baseUrl: String, callbackUrl: String): Boolean {
        val codeVerifier = verifier
        val expectedState = state
        val sessionCookies = cookies.orEmpty()
        try {
            if (codeVerifier == null || expectedState == null) return false

            val callback = Uri.parse(callbackUrl)
            val code = callback.getQueryParameter("code") ?: return false
            // Guards against a forged/replayed callback.
            if (callback.getQueryParameter("state") != expectedState) return false

            val base = SessionStore.normalizeBaseUrl(baseUrl)
            val url = Uri.parse("$base/auth/openid/callback").buildUpon()
                .appendQueryParameter("state", expectedState)
                .appendQueryParameter("code", code)
                .appendQueryParameter("code_verifier", codeVerifier)
                .build()
                .toString()

            val request = Request.Builder().url(url)
                .header("User-Agent", AuthApi.USER_AGENT)
                .header("x-return-tokens", "true")
                .apply {
                    if (sessionCookies.isNotEmpty()) header("cookie", sessionCookies)
                    session.customHeaders.forEach { (k, v) -> header(k, v) }
                }
                .get()
                .build()

            val body = runCatching {
                client.newCall(request).execute().use { resp ->
                    if (!resp.isSuccessful) return false
                    resp.body?.string()
                }
            }.getOrNull() ?: return false

            val root = runCatching { json.parseToJsonElement(body).jsonObject }.getOrNull() ?: return false
            val user = root["user"] as? JsonObject
            val access = listOf("accessToken", "token")
                .firstNotNullOfOrNull { (user?.get(it) ?: root[it])?.jsonPrimitive?.content?.takeIf(String::isNotEmpty) }
                ?: return false
            val refresh = (user?.get("refreshToken") ?: root["refreshToken"])?.jsonPrimitive?.content

            session.baseUrl = base
            val ttlHours = if (refresh.isNullOrEmpty()) 1L else 12L
            session.setAccess(access, Instant.now().plusSeconds(ttlHours * 3600))
            if (!refresh.isNullOrEmpty()) session.refreshToken = refresh
            return true
        } finally {
            verifier = null
            state = null
            cookies = null
        }
    }

    private fun sha256(bytes: ByteArray): ByteArray =
        MessageDigest.getInstance("SHA-256").digest(bytes)

    private fun base64Url(bytes: ByteArray): String =
        Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    private fun randomUrlSafe(bytes: Int): String =
        base64Url(ByteArray(bytes).also { SecureRandom().nextBytes(it) })

    companion object {
        const val CLIENT_ID = "Audiobookshelf"
        const val REDIRECT_URI = "audiobookshelf://oauth"
        const val SCHEME = "audiobookshelf"
    }
}
