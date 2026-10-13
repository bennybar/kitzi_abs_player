package com.bennybar.kitzi.wear

import android.net.Network
import android.util.Log
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

/** A play session as the server opens it (streaming). */
data class StreamSession(val id: String, val tracks: List<TrackFile>, val chapters: List<Chapter>, val durationSec: Double?)

@kotlinx.serialization.Serializable
data class TrackFile(val index: Int, val url: String, val mimeType: String, val durationSec: Double)

@kotlinx.serialization.Serializable
data class Chapter(val title: String, val startSec: Double)

data class Report(
    val itemId: String,
    val currentSec: Double,
    val durationSec: Double?,
    val finished: Boolean,
    val paused: Boolean,
    val listenedSec: Double?,
)

/** The few Audiobookshelf endpoints the watch needs. */
class Api(private val store: Store) {

    enum class LoginResult { OK, WRONG_CREDENTIALS, UNREACHABLE, NOT_ABS }

    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .addInterceptor { chain ->
            val req = chain.request()
            val b = req.newBuilder().header("User-Agent", USER_AGENT)
            store.headers.forEach { (k, v) -> b.header(k, v) }
            val base = store.baseUrl
            if (base != null && req.url.toString().startsWith(base) && req.header("Authorization") == null) {
                store.accessToken?.let { b.header("Authorization", "Bearer $it") }
            }
            chain.proceed(b.build())
        }
        // A watch sign-in has its own refresh token: renew once on a 401. (A phone
        // sign-in uses the account's API token, which doesn't expire.)
        .authenticator { _, response ->
            if (response.request.header("X-Kitzi-Retried") != null) return@authenticator null
            if (!refresh()) return@authenticator null
            response.request.newBuilder()
                .header("Authorization", "Bearer ${store.accessToken}")
                .header("X-Kitzi-Retried", "1")
                .build()
        }
        .build()

    /** The same client, but its traffic forced onto [network] (Wi-Fi / cellular, not Bluetooth). */
    fun clientOn(network: Network): OkHttpClient = client.newBuilder()
        .socketFactory(network.socketFactory)
        .dns(object : okhttp3.Dns { override fun lookup(hostname: String) = network.getAllByName(hostname).toList() })
        .build()

    private fun base() = store.baseUrl ?: error("not signed in")

    // ---- sign-in -------------------------------------------------------------------

    fun login(baseInput: String, username: String, password: String): LoginResult {
        val base = normalizeBaseUrl(baseInput)
        val body = buildJsonObject { put("username", username); put("password", password) }
            .toString().toRequestBody(JSON)
        val request = Request.Builder().url("$base/login")
            .header("User-Agent", USER_AGENT)
            .header("x-return-tokens", "true")
            .post(body).build()
        val root = try {
            OkHttpClient().newCall(request).execute().use { resp ->
                when {
                    resp.code == 401 || resp.code == 403 -> return LoginResult.WRONG_CREDENTIALS
                    !resp.isSuccessful -> return LoginResult.NOT_ABS
                }
                parse(resp.body?.string()) as? JsonObject ?: return LoginResult.NOT_ABS
            }
        } catch (e: Exception) {
            Log.w(TAG, "login failed", e)
            return LoginResult.UNREACHABLE
        }
        val user = root["user"] as? JsonObject ?: return LoginResult.NOT_ABS
        val access = user.str("accessToken") ?: user.str("token") ?: return LoginResult.NOT_ABS
        store.signIn(base, access, user.str("refreshToken"), user.str("username") ?: username, emptyMap())
        return LoginResult.OK
    }

    @Synchronized
    fun refresh(): Boolean {
        val base = store.baseUrl ?: return false
        val refresh = store.refreshToken ?: return false
        val request = Request.Builder().url("$base/auth/refresh")
            .header("User-Agent", USER_AGENT)
            .header("x-refresh-token", refresh)
            .post(ByteArray(0).toRequestBody()).build()
        return runCatching {
            OkHttpClient().newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return false
                val user = (parse(resp.body?.string()) as? JsonObject)?.get("user") as? JsonObject ?: return false
                store.accessToken = user.str("accessToken") ?: return false
                user.str("refreshToken")?.let { store.refreshToken = it }
                true
            }
        }.getOrDefault(false)
    }

    // ---- library -------------------------------------------------------------------

    /**
     * Continue Listening: the books in progress, most recent first, with their
     * positions, plus the ids of every finished book. Null when the server can't
     * be reached.
     */
    fun continueListening(): Pair<List<Book>, Set<String>>? {
        val items = get("/api/me/items-in-progress?limit=25") as? JsonObject ?: return null
        val me = get("/api/me") as? JsonObject ?: return null
        val progress = (me["mediaProgress"] as? JsonArray).orEmpty()
            .mapNotNull { it as? JsonObject }
            .filter { it.str("episodeId") == null }
            .associateBy { it.str("libraryItemId") }
        val finished = progress.filterValues { (it["isFinished"] as? JsonPrimitive)?.contentOrNull == "true" }
            .keys.filterNotNull().toSet()
        val books = (items["libraryItems"] as? JsonArray).orEmpty().mapNotNull { el ->
            val item = el as? JsonObject ?: return@mapNotNull null
            if (item.str("mediaType") != "book") return@mapNotNull null
            val id = item.str("id") ?: return@mapNotNull null
            val p = progress[id]
            if (p?.get("isFinished")?.let { (it as? JsonPrimitive)?.contentOrNull } == "true") return@mapNotNull null
            val media = item["media"] as? JsonObject
            val meta = media?.get("metadata") as? JsonObject
            Book(
                id = id,
                title = meta?.str("title") ?: return@mapNotNull null,
                author = meta.str("authorName"),
                durationSec = media.num("duration") ?: p?.num("duration") ?: 0.0,
                currentTimeSec = p?.num("currentTime") ?: 0.0,
                lastUpdate = p?.num("lastUpdate")?.toLong() ?: 0L,
            )
        }
            // Like the phone's Continue Listening: only books actually started.
            .filter { it.currentTimeSec > 0 }
        return books to finished
    }

    /** The server's position for one book: (seconds, lastUpdate), or null if it has none. */
    fun progress(itemId: String): Pair<Double, Long>? {
        val p = get("/api/me/progress/$itemId", allow404 = true) as? JsonObject ?: return null
        return (p.num("currentTime") ?: 0.0) to (p.num("lastUpdate")?.toLong() ?: 0L)
    }

    /** The book with its audio files and chapters (for downloading). */
    fun item(itemId: String, on: OkHttpClient = client): JsonObject? =
        get("/api/items/$itemId?expanded=1", http = on) as? JsonObject

    fun coverUrl(itemId: String) = "${base()}/api/items/$itemId/cover?width=240"

    // ---- playback ------------------------------------------------------------------

    fun openSession(itemId: String): StreamSession? {
        val body = buildJsonObject {
            put("deviceInfo", buildJsonObject {
                put("clientVersion", "kitzi-wear-${BuildConfig.VERSION_NAME}")
                put("deviceName", "Wear OS watch")
            })
            put("supportedMimeTypes", buildJsonArray { MIME_TYPES.forEach { add(it) } })
        }
        val root = post("/api/items/$itemId/play", body) as? JsonObject ?: return null
        val id = root.str("id") ?: return null
        val tracks = (root["audioTracks"] as? JsonArray).orEmpty().mapNotNull { el ->
            val t = el as? JsonObject ?: return@mapNotNull null
            val url = t.str("contentUrl") ?: return@mapNotNull null
            TrackFile(
                index = t.num("index")?.toInt() ?: 0,
                url = if (url.startsWith("http")) url else base() + url,
                mimeType = t.str("mimeType") ?: "audio/mpeg",
                durationSec = t.num("duration") ?: 0.0,
            )
        }.sortedBy { it.index }
        return StreamSession(id, tracks, chapters(root["chapters"]), root.num("duration"))
    }

    /** true = saved, false = rejected, null = unreachable. */
    fun syncSession(sessionId: String, r: Report): Boolean? {
        val body = buildJsonObject {
            put("currentTime", r.currentSec)
            put("isFinished", r.finished)
            r.durationSec?.takeIf { it > 0 }?.let { put("duration", it) }
            r.listenedSec?.takeIf { it > 0 }?.let { put("timeListened", it) }
        }
        return send("POST", "/api/session/$sessionId/sync", body)
    }

    fun closeSession(sessionId: String) {
        send("POST", "/api/session/$sessionId/close", buildJsonObject { })
    }

    /** Saves the position (not listening time) without a session. */
    fun saveProgress(r: Report): Boolean = send(
        "PATCH", "/api/me/progress/${r.itemId}",
        buildJsonObject {
            put("currentTime", r.currentSec)
            put("isFinished", r.finished)
            put("lastUpdate", System.currentTimeMillis())
            r.durationSec?.takeIf { it > 0 }?.let {
                put("duration", it)
                put("progress", (r.currentSec / it).coerceIn(0.0, 1.0))
            }
        },
    ) == true

    /**
     * Listening time for a downloaded book, as a "local" session (the only way the
     * server counts listening without a streaming session). [totalListenedSec] is
     * the session's cumulative total.
     */
    fun syncLocalSession(
        sessionId: String, book: Book, startedAt: Long, startSec: Double, r: Report, totalListenedSec: Double,
    ): Boolean {
        val now = System.currentTimeMillis()
        val day = java.time.LocalDate.now()
        return send("POST", "/api/session/local", buildJsonObject {
            put("id", sessionId)
            put("libraryItemId", book.id)
            put("mediaType", "book")
            put("displayTitle", book.title)
            book.author?.let { put("displayAuthor", it) }
            r.durationSec?.takeIf { it > 0 }?.let { put("duration", it) }
            put("playMethod", 3)
            put("startTime", startSec)
            put("currentTime", r.currentSec)
            put("timeListening", totalListenedSec)
            put("startedAt", startedAt)
            put("updatedAt", now)
            put("date", day.toString())
            put("dayOfWeek", day.dayOfWeek.getDisplayName(java.time.format.TextStyle.FULL, java.util.Locale.US))
            put("deviceInfo", buildJsonObject { put("clientVersion", "kitzi-wear-${BuildConfig.VERSION_NAME}") })
        }) == true
    }

    // ---- plumbing ------------------------------------------------------------------

    private fun get(path: String, allow404: Boolean = false, http: OkHttpClient = client): JsonElement? =
        runCatching {
            http.newCall(Request.Builder().url(base() + path).build()).execute().use { resp ->
                if (allow404 && resp.code == 404) return null
                if (!resp.isSuccessful) return null
                parse(resp.body?.string())
            }
        }.onFailure { Log.w(TAG, "GET $path failed: $it") }.getOrNull()

    private fun post(path: String, body: JsonObject): JsonElement? = runCatching {
        val req = Request.Builder().url(base() + path).post(body.toString().toRequestBody(JSON)).build()
        client.newCall(req).execute().use { resp -> if (resp.isSuccessful) parse(resp.body?.string()) else null }
    }.onFailure { Log.w(TAG, "POST $path failed: $it") }.getOrNull()

    /** true = 2xx, false = an error answer, null = unreachable. */
    private fun send(method: String, path: String, body: JsonObject): Boolean? = runCatching {
        val req = Request.Builder().url(base() + path).method(method, body.toString().toRequestBody(JSON)).build()
        client.newCall(req).execute().use { it.isSuccessful }
    }.onFailure { Log.w(TAG, "$method $path failed: $it") }.getOrNull()

    companion object {
        private const val TAG = "KitziApi"
        const val USER_AGENT = "Kitzi-ABS-Player/1.0 (Wear OS)"
        private val JSON = "application/json".toMediaType()
        private val MIME_TYPES = listOf(
            "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac", "audio/ogg", "audio/opus", "audio/webm",
        )

        fun normalizeBaseUrl(input: String): String {
            var url = input.trim()
            if (!url.startsWith("http://") && !url.startsWith("https://")) url = "https://$url"
            return url.trimEnd('/')
        }

        fun parse(body: String?): JsonElement? =
            body?.takeIf { it.isNotBlank() }?.let { runCatching { Store.json.parseToJsonElement(it) }.getOrNull() }

        fun chapters(el: JsonElement?): List<Chapter> = (el as? JsonArray).orEmpty().mapNotNull { c ->
            val o = c as? JsonObject ?: return@mapNotNull null
            Chapter(o.str("title") ?: "Chapter", o.num("start") ?: return@mapNotNull null)
        }.sortedBy { it.startSec }
    }
}

fun JsonObject.str(key: String): String? = (this[key] as? JsonPrimitive)?.contentOrNull
fun JsonObject.num(key: String): Double? = (this[key] as? JsonPrimitive)?.doubleOrNull
