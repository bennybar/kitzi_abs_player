package com.bennybar.kitzi.wear

import android.util.Log
import com.bennybar.kitzi.data.Services
import com.google.android.gms.tasks.Tasks
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject
import okhttp3.Request

/**
 * Signs the Kitzi watch app in from the phone. The watch asks over the Wearable
 * Data Layer (only an app with this package name and signing key can); the reply
 * carries the server URL, custom headers and the account's long-lived API token
 * from /api/me.
 *
 * Not the phone's own access/refresh tokens: refresh tokens rotate, so two devices
 * sharing one would keep logging each other out. The /api/me token is separate
 * and doesn't expire. Servers that no longer hand it out get an "unsupported"
 * reply, and the watch offers signing in on the watch instead.
 */
class WatchLoginService : WearableListenerService() {

    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != PATH_REQUEST) return
        Services.init(applicationContext)
        val reply = runCatching { credentials() }
            .onFailure { Log.w(TAG, "couldn't prepare watch login", it) }
            .getOrNull()
            ?: buildJsonObject { put("error", if (Services.session.baseUrl == null) "signed_out" else "unsupported") }
        runCatching {
            Tasks.await(
                Wearable.getMessageClient(this)
                    .sendMessage(event.sourceNodeId, PATH_REPLY, reply.toString().toByteArray())
            )
        }.onFailure { Log.w(TAG, "couldn't reply to the watch", it) }
    }

    private fun credentials(): JsonObject? {
        val base = Services.session.baseUrl ?: return null
        if (!Services.auth.hasValidSession()) return null
        val request = Request.Builder().url("$base/api/me").build()
        val me = Services.httpClient.newCall(request).execute().use { resp ->
            if (!resp.isSuccessful) return null
            Json.parseToJsonElement(resp.body?.string().orEmpty()) as? JsonObject
        } ?: return null
        val token = me["token"]?.jsonPrimitive?.content?.takeIf { it.isNotBlank() } ?: return null
        return buildJsonObject {
            put("baseUrl", base)
            put("token", token)
            me["username"]?.jsonPrimitive?.content?.let { put("username", it) }
            putJsonObject("headers") { Services.session.customHeaders.forEach { (k, v) -> put(k, v) } }
        }
    }

    private companion object {
        const val TAG = "WatchLogin"
        const val PATH_REQUEST = "/kitzi/login-request"
        const val PATH_REPLY = "/kitzi/login"
    }
}
