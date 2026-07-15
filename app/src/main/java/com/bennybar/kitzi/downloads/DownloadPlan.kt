package com.bennybar.kitzi.downloads

import com.bennybar.kitzi.data.model.num
import com.bennybar.kitzi.data.model.str
import com.bennybar.kitzi.data.net.AbsApi
import com.bennybar.kitzi.data.net.PlaybackApi
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

/** One downloadable audio file of a book. */
data class PlannedTrack(
    val index: Int,
    val fileId: String,
    val mimeType: String,
    val durationSec: Double?,
) {
    /**
     * `track_007.m4a`.
     *
     * The number is the SERVER's track index, not a positional counter, and the
     * extension comes from the mime type. Both details are load-bearing: playback
     * orders local files by filename, and every already-downloaded file on every
     * existing install is named this way. Deviating orphans them all.
     */
    val filename: String get() = "track_%03d.%s".format(index, extensionFor(mimeType))

    companion object {
        fun extensionFor(mime: String): String = when {
            mime.contains("mpeg") -> "mp3"
            mime.contains("mp4") || mime.contains("aac") -> "m4a"
            mime.contains("flac") -> "flac"
            mime.contains("opus") -> "opus"
            mime.contains("ogg") -> "ogg"
            mime.contains("webm") -> "webm"
            mime.contains("wav") -> "wav"
            // Deliberately mp3 rather than .bin: a bogus extension breaks players
            // that sniff the format from the filename.
            else -> "mp3"
        }
    }
}

/**
 * Works out which files make up a book.
 *
 * ABS deployments differ in what they expose, so this walks the same fallback
 * chain the Flutter app did, and additionally captures each track's duration so
 * playback of the downloaded book knows the book's shape without the network.
 */
class DownloadPlanResolver(
    private val api: AbsApi,
    private val playbackApi: PlaybackApi,
) {
    fun resolve(itemId: String): List<PlannedTrack> {
        fromItemMedia(itemId).takeIf { it.isNotEmpty() }?.let { return it }
        // Last resort: open a play session purely to enumerate the tracks, then
        // close it immediately so we don't leave a transcode running.
        return fromPlaySession(itemId)
    }

    private fun fromItemMedia(itemId: String): List<PlannedTrack> {
        val item = runCatching { api.item(itemId) }.getOrNull() ?: return emptyList()
        val media = item["media"] as? JsonObject ?: return emptyList()

        // audioFiles is the realistic hot path; tracks/files cover other versions.
        for (key in listOf("audioFiles", "tracks", "files")) {
            val arr = media[key] as? JsonArray ?: continue
            val planned = arr.mapIndexedNotNull { position, el ->
                val m = el as? JsonObject ?: return@mapIndexedNotNull null
                val nested = m["file"] as? JsonObject
                val fileId = m["id"].str() ?: m["_id"].str()
                    ?: m["fileId"].str() ?: nested?.get("id").str() ?: nested?.get("_id").str()
                    ?: return@mapIndexedNotNull null

                PlannedTrack(
                    // Fall back to the array position only when the server gives no index.
                    index = (m["index"].num() ?: m["order"].num() ?: m["track"].num()
                        ?: m["trackNumber"].num())?.toInt() ?: position,
                    fileId = fileId,
                    mimeType = m["mimeType"].str() ?: m["contentType"].str() ?: "audio/mpeg",
                    durationSec = m["duration"].num()?.takeIf { it > 0 },
                )
            }
            if (planned.isNotEmpty()) return planned.sortedBy { it.index }
        }
        return emptyList()
    }

    private fun fromPlaySession(itemId: String): List<PlannedTrack> {
        val session = playbackApi.openSession(itemId) ?: return emptyList()
        try {
            return session.tracks.mapNotNull { t ->
                // contentUrl looks like /api/items/<id>/file/<fileId>[/download]
                val segments = t.url.substringBefore('?').split('/').filter { it.isNotEmpty() }
                val fileIdx = segments.indexOfFirst { it == "file" || it == "files" }
                val fileId = segments.getOrNull(fileIdx + 1)?.takeIf { fileIdx >= 0 } ?: return@mapNotNull null

                PlannedTrack(
                    index = t.index,
                    fileId = fileId,
                    mimeType = t.mimeType,
                    durationSec = t.durationSec,
                )
            }.sortedBy { it.index }
        } finally {
            session.sessionId?.let { playbackApi.closeSession(it) }
        }
    }
}
