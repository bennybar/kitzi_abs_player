package com.bennybar.kitzi.data.net

import okhttp3.OkHttpClient
import java.util.concurrent.TimeUnit

/**
 * Two clients, deliberately:
 *
 *  - [auth] is plain. The auth endpoints must not carry an Authorization header
 *    or trigger the refresh logic — a 401 from /auth/refresh means the refresh
 *    token is dead, and retrying it through the refresher would recurse.
 *  - [api] carries [AuthInterceptor], so every /api call is signed and gets the
 *    proactive-refresh + refresh-on-401 behaviour.
 */
object Http {

    fun authClient(): OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    fun apiClient(session: SessionStore, refresher: TokenRefresher): OkHttpClient =
        OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .addInterceptor(AuthInterceptor(session, refresher))
            .build()
}
