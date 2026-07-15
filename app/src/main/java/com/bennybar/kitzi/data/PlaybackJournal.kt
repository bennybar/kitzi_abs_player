package com.bennybar.kitzi.data

import org.json.JSONArray
import org.json.JSONObject

/**
 * A local per-book "play history": a position snapshot recorded each time playback
 * pauses (position + chapter + timestamp), so the player's Play history sheet can
 * offer to jump back to where you were. The Kotlin equivalent of Flutter's
 * PlaybackJournalService.
 */
object PlaybackJournal {
    private const val PREFIX = "playback_journal_"
    private const val MAX_PER_BOOK = 30

    data class Entry(
        val positionSec: Double,
        val chapterTitle: String?,
        val chapterIndex: Int?,
        val atMs: Long,
    )

    fun record(itemId: String, positionSec: Double, chapterTitle: String?, chapterIndex: Int?) {
        if (itemId.isBlank() || positionSec < 0) return
        val list = historyFor(itemId).toMutableList()
        // Skip a near-duplicate of the most recent entry (same spot re-paused).
        if (list.firstOrNull()?.let { kotlin.math.abs(it.positionSec - positionSec) < 2.0 } == true) return
        list.add(0, Entry(positionSec, chapterTitle, chapterIndex, System.currentTimeMillis()))
        save(itemId, list.take(MAX_PER_BOOK))
    }

    fun historyFor(itemId: String): List<Entry> {
        val raw = Services.prefs.getString(PREFIX + itemId) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                Entry(
                    positionSec = o.optDouble("p"),
                    chapterTitle = o.optString("c").takeIf { it.isNotBlank() },
                    chapterIndex = if (o.has("i")) o.optInt("i") else null,
                    atMs = o.optLong("t"),
                )
            }
        }.getOrDefault(emptyList())
    }

    private fun save(itemId: String, list: List<Entry>) {
        val arr = JSONArray()
        list.forEach { e ->
            arr.put(JSONObject().apply {
                put("p", e.positionSec)
                e.chapterTitle?.let { put("c", it) }
                e.chapterIndex?.let { put("i", it) }
                put("t", e.atMs)
            })
        }
        Services.prefs.putString(PREFIX + itemId, arr.toString())
    }
}
