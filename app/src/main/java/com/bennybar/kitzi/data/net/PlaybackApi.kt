package com.bennybar.kitzi.data.net

import android.util.Log
import com.bennybar.kitzi.data.model.num
import com.bennybar.kitzi.data.model.str
import com.bennybar.kitzi.playback.Chapter
import com.bennybar.kitzi.playback.Track
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/** What the server hands back when a play session opens. */
data class PlaySession(
    val sessionId: String?,
    val tracks: List<Track>,
    val chapters: List<Chapter>,
    val durationSec: Double?,
)

/** The progress to report for a book, in BOOK coordinates. */
data class ProgressReport(
    val itemId: String,
    val currentTimeSec: Double,
    val totalSec: Double?,
    val isFinished: Boolean,
    val isPaused: Boolean,
    /** Wall-clock seconds actually spent listening since the last successful sync. */
    val timeListenedSec: Double?,
)

class PlaybackApi(
    private val client: OkHttpClient,
    private val session: SessionStore,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    private fun base() = session.baseUrl ?: error("Base URL not set")

    /**
     * Opens a play session. Streaming only — a downloaded book must never need
     * this, because needing it offline is what made tapping a downloaded book pop
     * "No Internet Connection".
     */
    fun openSession(itemId: String, episodeId: String? = null): PlaySession? {
        val path = if (episodeId != null) "/api/items/$itemId/play/$episodeId" else "/api/items/$itemId/play"

        val body = buildJsonObject {
            put("deviceInfo", buildJsonObject { put("clientVersion", CLIENT_VERSION) })
            put("supportedMimeTypes", buildJsonArray {
                SUPPORTED_MIME_TYPES.forEach { add(it) }
            })
        }.toString().toRequestBody(JSON_MEDIA)

        val request = Request.Builder().url(base() + path).post(body).build()

        return runCatching {
            client.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) return null
                val root = json.parseToJsonElement(resp.body?.string().orEmpty()) as? JsonObject
                    ?: return null
                parseSession(root)
            }
        }.onFailure { Log.w(TAG, "openSession failed for $itemId", it) }.getOrNull()
    }

    private fun parseSession(root: JsonObject): PlaySession {
        val sessionId = root["sessionId"].str() ?: root["id"].str() ?: root["_id"].str()

        val tracks = (root["audioTracks"] as? JsonArray).orEmpty().mapNotNull { el ->
            val t = el as? JsonObject ?: return@mapNotNull null
            val contentUrl = t["contentUrl"].str() ?: return@mapNotNull null
            Track(
                index = t["index"].num()?.toInt() ?: 0,
                // contentUrl is usually server-relative.
                url = if (contentUrl.startsWith("http")) contentUrl else base() + contentUrl,
                mimeType = t["mimeType"].str() ?: "audio/mpeg",
                durationSec = t["duration"].num()?.takeIf { it > 0 },
                isLocal = false,
            )
        }.sortedBy { it.index }

        val chapters = (root["chapters"] as? JsonArray).orEmpty().mapNotNull { el ->
            val c = el as? JsonObject ?: return@mapNotNull null
            val start = c["start"].num() ?: return@mapNotNull null
            Chapter(title = c["title"].str() ?: "Chapter", startSec = start)
        }.sortedBy { it.startSec }

        val duration = (root["duration"].num()
            ?: (root["libraryItem"] as? JsonObject)?.let { li ->
                (li["media"] as? JsonObject)?.get("duration").num()
            })?.takeIf { it > 0 }

        return PlaySession(sessionId, tracks, chapters, duration)
    }

    /**
     * The canonical progress report. Falls back to the older /api/me/progress
     * endpoint when the session sync fails, exactly as the Flutter app does —
     * some server versions only support one of them.
     *
     * Returns true only when the server accepted it; a false here means the
     * listening time must NOT be consumed, so it rolls into the next attempt.
     */
    fun sync(sessionId: String?, report: ProgressReport): Boolean {
        if (sessionId != null && syncSession(sessionId, report)) return true
        return patchProgress(report)
    }

    private fun syncSession(sessionId: String, r: ProgressReport): Boolean {
        val body = buildJsonObject {
            put("currentTime", r.currentTimeSec)
            put("position", (r.currentTimeSec * 1000).toLong())
            put("isPaused", r.isPaused)
            put("isFinished", r.isFinished)
            put("libraryItemId", r.itemId)
            put("lastUpdate", System.currentTimeMillis())
            r.totalSec?.takeIf { it > 0 }?.let {
                put("duration", it)
                put("progress", (r.currentTimeSec / it).coerceIn(0.0, 1.0))
            }
            r.timeListenedSec?.takeIf { it > 0 }?.let { put("timeListened", it) }
        }.toString().toRequestBody(JSON_MEDIA)

        return runCatching {
            val request = Request.Builder()
                .url("${base()}/api/session/$sessionId/sync")
                .post(body)
                .build()
            client.newCall(request).execute().use { it.isSuccessful }
        }.getOrDefault(false)
    }

    private fun patchProgress(r: ProgressReport): Boolean {
        val body = buildJsonObject {
            put("currentTime", r.currentTimeSec)
            put("isFinished", r.isFinished)
            put("libraryItemId", r.itemId)
            put("lastUpdate", System.currentTimeMillis())
            r.totalSec?.takeIf { it > 0 }?.let {
                put("duration", it)
                put("progress", (r.currentTimeSec / it).coerceIn(0.0, 1.0))
            }
            r.timeListenedSec?.takeIf { it > 0 }?.let { put("timeListened", it) }
        }.toString().toRequestBody(JSON_MEDIA)

        val url = "${base()}/api/me/progress/${r.itemId}"
        // Older servers accept only one of these verbs.
        return listOf("PATCH", "PUT", "POST").any { verb ->
            runCatching {
                val request = Request.Builder().url(url).method(verb, body).build()
                client.newCall(request).execute().use { it.isSuccessful }
            }.getOrDefault(false)
        }
    }

    /** Marks a book finished without playing it (the "Mark as Finished" action). */
    /**
     * Marking finished must state a position CONSISTENT with being finished: the
     * end of the book, with duration so the server computes progress = 1. Sending
     * `currentTime = 0` alongside `isFinished = true` is a contradiction, and the
     * server resolved it by recomputing progress from the position and dropping the
     * finished flag — the mark appeared to work locally and was gone on next sync.
     */
    fun setFinished(itemId: String, finished: Boolean, durationSec: Double?): Boolean = patchProgress(
        ProgressReport(
            itemId = itemId,
            currentTimeSec = if (finished) durationSec ?: 0.0 else 0.0,
            totalSec = durationSec,
            isFinished = finished,
            isPaused = true,
            timeListenedSec = null,
        )
    )

    fun closeSession(sessionId: String) {
        runCatching {
            val request = Request.Builder()
                .url("${base()}/api/session/$sessionId/close")
                .post(ByteArray(0).toRequestBody())
                .build()
            client.newCall(request).execute().close()
        }
    }

    /** Bookmarks are server-owned; the response is the source of truth. */
    fun addBookmark(itemId: String, timeSec: Double, title: String): Boolean {
        val body = buildJsonObject {
            put("time", Math.round(timeSec * 1000) / 1000.0)
            put("title", title)
        }.toString().toRequestBody(JSON_MEDIA)

        return runCatching {
            val request = Request.Builder()
                .url("${base()}/api/me/item/$itemId/bookmark")
                .post(body)
                .build()
            client.newCall(request).execute().use { it.isSuccessful }
        }.getOrDefault(false)
    }

    fun deleteBookmark(itemId: String, timeSec: Double): Boolean {
        // The server keys bookmarks by the raw time, with trailing zeros stripped.
        val key = if (timeSec % 1.0 == 0.0) timeSec.toLong().toString()
        else timeSec.toString().trimEnd('0').trimEnd('.')

        return runCatching {
            val request = Request.Builder()
                .url("${base()}/api/me/item/$itemId/bookmark/$key")
                .delete()
                .build()
            client.newCall(request).execute().use { it.isSuccessful || it.code == 404 }
        }.getOrDefault(false)
    }

    private companion object {
        const val TAG = "PlaybackApi"
        // Derived from the app version so server session diagnostics never drift.
        val CLIENT_VERSION = "kitzi-android-${com.bennybar.kitzi.BuildConfig.VERSION_NAME}"
        val JSON_MEDIA = "application/json".toMediaType()
        val SUPPORTED_MIME_TYPES = listOf(
            "audio/mpeg", "audio/mp4", "audio/aac", "audio/flac",
            "audio/ogg", "audio/opus", "audio/webm",
        )
    }
}
