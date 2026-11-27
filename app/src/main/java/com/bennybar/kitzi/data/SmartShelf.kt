package com.bennybar.kitzi.data

import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.model.Book
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.util.UUID

/**
 * A saved filter shown as a row on Home ("Under 6 Hours", "Highly Rated, Not
 * Started"): every rule that's set must hold. Stored as JSON in `ui_smart_shelves`,
 * in the same shape as the iOS app's.
 */
@Serializable
data class SmartShelf(
    val id: String = UUID.randomUUID().toString().uppercase(),
    val name: String,
    /** "any", "notStarted", "inProgress" or "finished". */
    val status: String = "notStarted",
    val maxHours: Double? = null,
    /** Audible's stars at least this (books whose rating isn't known yet are left out). */
    val minRating: Double? = null,
    /** Added to the library in the last so many days. */
    val addedDays: Int? = null,
    val genre: String? = null,
    /** Only books of a series you've started or finished a book of. */
    val mySeries: Boolean = false,
    val downloaded: Boolean = false,
    /** "added" (newest), "shortest", "rating" or "title". */
    val sort: String = "added",
) {
    /** What it asks for, in a line ("Not started · under 6 h · shortest first"). */
    val summary: String get() = listOfNotNull(
        when (status) {
            "notStarted" -> "Not started"
            "inProgress" -> "In progress"
            "finished" -> "Finished"
            else -> null
        },
        maxHours?.let { "under ${it.toInt()} h" },
        minRating?.let { String.format(java.util.Locale.US, "%.1f★ or more", it) },
        addedDays?.let { "added in the last $it days" },
        genre,
        "series I'm in".takeIf { mySeries },
        "downloaded".takeIf { downloaded },
        mapOf("added" to "newest first", "shortest" to "shortest first", "rating" to "best rated first", "title" to "by title")[sort],
    ).joinToString(" · ")

    /**
     * The books this shelf shows, in its order. [stars]: Audible's rating per book
     * id, for the books it's known for; [downloaded]: the ids on this device.
     */
    fun books(
        all: List<Book>,
        progress: Map<String, MediaProgressEntity>,
        stars: Map<String, Double>,
        downloaded: Set<String>,
        nowMs: Long,
    ): List<Book> {
        val started = if (mySeries) {
            all.filter { b -> b.series != null && progress[b.id]?.let { it.isFinished || it.progress > 0 } == true }
                .mapNotNull { it.series }.toSet()
        } else emptySet()
        val cutoff = addedDays?.let { nowMs - it * 86_400_000L }
        val list = all.filter { b ->
            val p = progress[b.id]
            when (status) {
                "notStarted" -> if (p != null && (p.isFinished || p.progress > 0)) return@filter false
                "inProgress" -> if (p == null || p.isFinished || p.progress <= 0) return@filter false
                "finished" -> if (p?.isFinished != true) return@filter false
            }
            if (maxHours != null && (b.durationMs ?: Long.MAX_VALUE) > maxHours * 3_600_000) return@filter false
            if (minRating != null && (stars[b.id] ?: 0.0) < minRating) return@filter false
            if (cutoff != null && (b.addedAt ?: 0L) < cutoff) return@filter false
            if (genre != null && genre !in b.genres) return@filter false
            if (mySeries && b.series !in started) return@filter false
            if (this.downloaded && b.id !in downloaded) return@filter false
            true
        }
        return when (sort) {
            "shortest" -> list.sortedBy { it.durationMs ?: Long.MAX_VALUE }
            "rating" -> list.sortedByDescending { stars[it.id] ?: 0.0 }
            // A series' books together and in order.
            "title" -> list.sortedWith(
                compareBy<Book, String>(String.CASE_INSENSITIVE_ORDER) { it.series ?: it.title }.thenBy { it.seriesSequence ?: 0.0 }
            )
            else -> list.sortedByDescending { it.addedAt ?: 0L }
        }
    }

    companion object {
        val presets = listOf(
            SmartShelf(name = "Under 6 Hours", maxHours = 6.0, sort = "shortest"),
            SmartShelf(name = "Unstarted in My Series", mySeries = true, sort = "title"),
            SmartShelf(name = "Highly Rated, Not Started", minRating = 4.5, sort = "rating"),
            SmartShelf(name = "Added This Month", status = "any", addedDays = 30),
        )

        // iOS writes nothing for an unset rule (and Swift's encoder leaves out a nil).
        private val json = Json { ignoreUnknownKeys = true; explicitNulls = false; encodeDefaults = true }
        private val serializer = ListSerializer(serializer())

        fun decode(text: String?): List<SmartShelf> =
            text?.let { runCatching { json.decodeFromString(serializer, it) }.getOrNull() }.orEmpty()

        fun encode(shelves: List<SmartShelf>): String = json.encodeToString(serializer, shelves)
    }
}
