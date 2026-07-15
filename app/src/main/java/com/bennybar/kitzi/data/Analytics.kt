package com.bennybar.kitzi.data

import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Build
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.UUID
import java.util.concurrent.TimeUnit

/**
 * Privacy-friendly usage analytics via Aptabase, matching the Flutter app.
 *
 * Anonymous: no user id, no device fingerprint. Ported from
 * analytics_service.dart — same app key and event names. As in Flutter, only
 * `app_open` is actually fired; the other event helpers exist for parity.
 */
object Analytics {
    private const val APP_KEY = "A-US-4608344463"
    // Region is the middle segment of the key (US) -> the US ingest host.
    private const val ENDPOINT = "https://us.aptabase.com/api/v0/event"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client by lazy { OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).build() }
    private val sessionId = UUID.randomUUID().toString()
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US)
        .apply { timeZone = TimeZone.getTimeZone("UTC") }

    private var ready = false
    private var appVersion = ""
    private var buildNumber = ""
    private var isDebug = false

    fun init(context: Context) {
        runCatching {
            val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
            appVersion = pkg.versionName ?: ""
            buildNumber = if (Build.VERSION.SDK_INT >= 28) pkg.longVersionCode.toString()
            else @Suppress("DEPRECATION") pkg.versionCode.toString()
            isDebug = (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0
            ready = true
        }
    }

    /** Daily-active-user ping. */
    fun logAppOpen() = track("app_open", null)

    fun logScreenView(screen: String) = track("screen_view", mapOf("screen" to screen))

    fun logBookPlay(bookId: String, bookTitle: String) =
        track("book_play", mapOf("book_id" to bookId, "book_title" to bookTitle))

    fun logBookDownload(bookId: String) = track("book_download", mapOf("book_id" to bookId))

    private fun track(name: String, props: Map<String, String>?) {
        if (!ready) return
        scope.launch {
            runCatching {
                val body = JSONObject().apply {
                    put("timestamp", iso.format(System.currentTimeMillis()))
                    put("sessionId", sessionId)
                    put("eventName", name)
                    put("systemProps", JSONObject().apply {
                        put("isDebug", isDebug)
                        put("locale", Locale.getDefault().toString())
                        put("osName", "Android")
                        put("osVersion", Build.VERSION.RELEASE ?: "")
                        put("appVersion", appVersion)
                        put("appBuildNumber", buildNumber)
                        put("sdkVersion", "kitzi-kotlin@1.0")
                    })
                    if (props != null) put("props", JSONObject(props as Map<*, *>))
                }
                val req = Request.Builder()
                    .url(ENDPOINT)
                    .header("App-Key", APP_KEY)
                    .post(body.toString().toRequestBody("application/json".toMediaType()))
                    .build()
                client.newCall(req).execute().close()
            }
        }
    }
}
