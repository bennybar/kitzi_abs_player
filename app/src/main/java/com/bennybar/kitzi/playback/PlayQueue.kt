package com.bennybar.kitzi.playback

import com.bennybar.kitzi.data.legacy.FlutterPrefs
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json

@Serializable
data class QueueEntry(
    val id: String,
    val title: String,
    val author: String? = null,
    val coverUrl: String? = null,
)

/**
 * "Up Next": a queue of BOOKS.
 *
 * Distinct from the ExoPlayer playlist, which holds the tracks of a single book.
 * Conflating the two would make "next in queue" jump to the next audio file
 * instead of the next book.
 *
 * Persisted under the same pref key the Flutter app used, so an updated user's
 * queue survives.
 */
class PlayQueue(private val prefs: FlutterPrefs) {

    private val json = Json { ignoreUnknownKeys = true }

    private val _items = MutableStateFlow(load())
    val items: StateFlow<List<QueueEntry>> = _items.asStateFlow()

    fun addToBack(entry: QueueEntry) = update { list ->
        if (list.any { it.id == entry.id }) list else list + entry
    }

    fun addNext(entry: QueueEntry) = update { list ->
        listOf(entry) + list.filterNot { it.id == entry.id }
    }

    fun remove(id: String) = update { list -> list.filterNot { it.id == id } }

    fun clear() = update { emptyList() }

    fun move(from: Int, to: Int) = update { list ->
        if (from !in list.indices) return@update list
        val mutable = list.toMutableList()
        val item = mutable.removeAt(from)
        mutable.add(to.coerceIn(0, mutable.size), item)
        mutable
    }

    /** Pops the next book, dropping the one that just finished if it is queued. */
    fun popNext(finishedId: String?): QueueEntry? {
        val list = _items.value.filterNot { it.id == finishedId }
        val next = list.firstOrNull()
        _items.value = list.drop(1)
        save()
        return next
    }

    private fun update(block: (List<QueueEntry>) -> List<QueueEntry>) {
        _items.value = block(_items.value)
        save()
    }

    private fun save() {
        prefs.putString(KEY, json.encodeToString(_items.value))
    }

    private fun load(): List<QueueEntry> =
        prefs.getString(KEY)
            ?.let { runCatching { json.decodeFromString<List<QueueEntry>>(it) }.getOrNull() }
            .orEmpty()

    private companion object {
        const val KEY = "play_queue_v1"
    }
}
