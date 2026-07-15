package com.bennybar.kitzi.data.net

/**
 * Single-flight token refresh.
 *
 * This exists to stop a refresh stampede. ABS rotates the refresh token on every
 * `/auth/refresh`, so if several requests 401 at once and each refreshes, they
 * invalidate one another's tokens and the user gets logged out. The Flutter app
 * dedupes by sharing one in-flight future (api_client.dart `_refreshInFlight`);
 * OkHttp interceptors are blocking, so the equivalent here is a lock plus a
 * "did someone already rotate while I waited?" check.
 */
class TokenRefresher(
    private val session: SessionStore,
    private val authApi: AuthApi,
) {
    private val lock = Any()

    /**
     * Called after a 401. [tokenUsed] is the access token the failing request
     * carried; if the current token differs, another thread already refreshed
     * and we simply reuse its result rather than rotating again.
     */
    fun refreshAfterUnauthorized(tokenUsed: String?): Boolean = synchronized(lock) {
        val current = session.accessToken
        if (current != null && current != tokenUsed) return true
        authApi.refresh()
    }

    /** Proactive refresh when the access token is at/near its assumed expiry. */
    fun ensureFresh() {
        if (session.accessExpiry == null || session.hasFreshAccessToken()) return
        synchronized(lock) {
            if (session.hasFreshAccessToken()) return
            authApi.refresh()
        }
    }
}
