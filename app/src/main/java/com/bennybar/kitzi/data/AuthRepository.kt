package com.bennybar.kitzi.data

import com.bennybar.kitzi.data.net.AuthApi
import com.bennybar.kitzi.data.net.OidcClient
import com.bennybar.kitzi.data.net.SessionStore
import com.bennybar.kitzi.data.net.TokenRefresher

/**
 * Login, logout and "are we still signed in?", ported from auth_repository.dart.
 */
class AuthRepository(
    private val session: SessionStore,
    private val authApi: AuthApi,
    private val refresher: TokenRefresher,
    val oidc: OidcClient,
) {
    val baseUrl: String? get() = session.baseUrl

    /**
     * Deliberately avoids a network round-trip when the access token is
     * comfortably fresh: this is polled while the app is in the foreground, and
     * hitting /auth/refresh each time would wake the radio and rotate tokens for
     * nothing. A real 401 mid-request is the authoritative backstop.
     */
    fun hasValidSession(): Boolean {
        if (session.baseUrl == null) return false
        if (session.hasFreshAccessToken(leewaySeconds = 300)) return true

        // Through the single-flight refresher, not AuthApi directly: this runs from
        // startup and the background worker, and a concurrent interceptor refresh
        // would rotate the same refresh token twice and log the user out.
        if (refresher.refreshNow()) return true

        // Refresh failed — offline, or no refresh token. Degrade gracefully on a
        // still-valid access token rather than forcing a logout on a blip.
        return session.hasFreshAccessToken(leewaySeconds = 60)
    }

    fun login(baseUrl: String, username: String, password: String): Boolean =
        authApi.login(baseUrl, username, password)

    fun logout() = authApi.logout()

    /** e.g. ["local", "openid"] — the login screen uses this to offer SSO. */
    fun serverAuthMethods(baseUrl: String): List<String> = authApi.authMethods(baseUrl)
}
