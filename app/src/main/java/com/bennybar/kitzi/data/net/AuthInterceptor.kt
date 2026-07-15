package com.bennybar.kitzi.data.net

import okhttp3.Interceptor
import okhttp3.Response

/**
 * Attaches the identity headers and keeps the access token valid, mirroring
 * `ApiClient.request` in api_client.dart: refresh proactively when the token is
 * about to expire, and treat a real 401 as the authoritative signal to refresh
 * and retry once.
 */
class AuthInterceptor(
    private val session: SessionStore,
    private val refresher: TokenRefresher,
) : Interceptor {

    override fun intercept(chain: Interceptor.Chain): Response {
        refresher.ensureFresh()

        val tokenUsed = session.accessToken
        val response = chain.proceed(chain.request().signed(tokenUsed))
        if (response.code != 401) return response

        // A 401 is the backstop: the assumed expiry was wrong, or the token was
        // revoked. Refresh once (deduped) and replay the request.
        if (!refresher.refreshAfterUnauthorized(tokenUsed)) return response
        val newToken = session.accessToken ?: return response

        response.close()
        return chain.proceed(chain.request().signed(newToken))
    }

    private fun okhttp3.Request.signed(token: String?) = newBuilder().apply {
        header("User-Agent", AuthApi.USER_AGENT)
        session.customHeaders.forEach { (k, v) -> header(k, v) }
        if (token != null) header("Authorization", "Bearer $token")
    }.build()
}
