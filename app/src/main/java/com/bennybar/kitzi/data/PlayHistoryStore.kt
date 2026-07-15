package com.bennybar.kitzi.data

import org.json.JSONArray
import org.json.JSONObject

/**
 * Local detailed play-history: one entry per confirmed listened interval
 * (itemId + seconds + timestamp), gated on the `detailed_play_history_enabled`
 * setting. Powers the stats screen's streak and top books/authors/narrators —
 * the Kotlin equivalent of Flutter's detailed_play_history_service.
 *
 * Deliberately minimal: only the itemId is stored, and title/author/narrator are
 * resolved from the library table at aggregation time, so it stays small and
 * never goes stale.
 */
object PlayHistoryStore {
    private const val KEY = "detailed_play_history"
    private const val MAX_ENTRIES = 5000
    private const val MAX_AGE_MS = 400L * 24 * 3600 * 1000 // ~13 months (covers year-wrapped)

    data class Session(val itemId: String, val listenedSec: Double, val atMs: Long)

    fun enabled(): Boolean = Services.prefs.getBoolean("detailed_play_history_enabled", false)

    fun record(itemId: String, listenedSec: Double) {
        if (!enabled() || listenedSec <= 0.0 || itemId.isBlank()) return
        val now = System.currentTimeMillis()
        val list = load().toMutableList()
        list.add(Session(itemId, listenedSec, now))
        val cutoff = now - MAX_AGE_MS
        val trimmed = list.filter { it.atMs >= cutoff }.takeLast(MAX_ENTRIES)
        save(trimmed)
    }

    fun sessions(): List<Session> = load()

    fun clear() = Services.prefs.putString(KEY, "[]")

    private fun load(): List<Session> {
        val raw = Services.prefs.getString(KEY) ?: return emptyList()
        return runCatching {
            val arr = JSONArray(raw)
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.optJSONObject(i) ?: return@mapNotNull null
                Session(o.optString("i"), o.optDouble("s"), o.optLong("t"))
            }
        }.getOrDefault(emptyList())
    }

    private fun save(list: List<Session>) {
        val arr = JSONArray()
        list.forEach { s ->
            arr.put(JSONObject().apply { put("i", s.itemId); put("s", s.listenedSec); put("t", s.atMs) })
        }
        Services.prefs.putString(KEY, arr.toString())
    }
}
