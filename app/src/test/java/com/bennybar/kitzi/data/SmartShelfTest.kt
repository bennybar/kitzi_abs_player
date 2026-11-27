package com.bennybar.kitzi.data

import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test

class SmartShelfTest {
    private val day = 86_400_000L
    private val now = 1_000 * day

    private fun book(
        id: String,
        hours: Double = 10.0,
        addedDaysAgo: Long = 100,
        series: String? = null,
        seq: Double? = null,
        genres: List<String> = emptyList(),
    ) = Book(
        id = id, title = id, author = null, coverUrl = "", description = null,
        durationMs = (hours * 3_600_000).toLong(), sizeBytes = null, updatedAt = null, addedAt = now - addedDaysAgo * day,
        series = series, seriesSequence = seq, collection = null, collectionSequence = null, isAudioBook = true,
        mediaKind = null, libraryId = null, authors = emptyList(), narrators = emptyList(), publisher = null,
        publishYear = null, genres = genres,
    )

    private fun progress(id: String, p: Double, finished: Boolean = false) =
        MediaProgressEntity(id, p, finished, 0.0, 0.0, 0)

    private val books = listOf(
        book("short", hours = 3.0),
        book("long", hours = 20.0),
        book("started", hours = 2.0),
        book("done", hours = 1.0),
        book("new", hours = 5.0, addedDaysAgo = 2, genres = listOf("Fantasy")),
        book("s1", series = "Saga", seq = 1.0),
        book("s2", series = "Saga", seq = 2.0),
        book("other1", series = "Other", seq = 1.0),
    )
    private val progress = mapOf(
        "started" to progress("started", 0.3),
        "done" to progress("done", 1.0, finished = true),
        "s1" to progress("s1", 1.0, finished = true),
    )

    private fun SmartShelf.ids(stars: Map<String, Double> = emptyMap(), downloaded: Set<String> = emptySet()) =
        books(books, progress, stars, downloaded, now).map { it.id }

    @Test
    fun `under 6 hours, not started, shortest first`() {
        assertEquals(listOf("short", "new"), SmartShelf.presets[0].ids())
    }

    @Test
    fun `unstarted books of the series I'm in`() {
        assertEquals(listOf("s2"), SmartShelf.presets[1].ids())
    }

    @Test
    fun `highly rated leaves out books whose rating isn't known, best first`() {
        val stars = mapOf("long" to 4.6, "short" to 4.9, "new" to 4.2)
        assertEquals(listOf("short", "long"), SmartShelf.presets[2].ids(stars))
    }

    @Test
    fun `added this month, any status, newest first`() {
        assertEquals(listOf("new"), SmartShelf.presets[3].ids())
    }

    @Test
    fun `status, genre and downloaded rules`() {
        assertEquals(listOf("started"), SmartShelf(name = "x", status = "inProgress").ids())
        assertEquals(listOf("done", "s1"), SmartShelf(name = "x", status = "finished", sort = "title").ids())
        assertEquals(listOf("new"), SmartShelf(name = "x", genre = "Fantasy").ids())
        assertEquals(listOf("long"), SmartShelf(name = "x", downloaded = true).ids(downloaded = setOf("long", "done")))
    }

    @Test
    fun `reads and writes the iOS JSON, where an unset rule is left out`() {
        val ios = """[{"id":"A1","name":"Under 6 Hours","status":"notStarted","maxHours":6,"mySeries":false,"downloaded":false,"sort":"shortest"}]"""
        val shelves = SmartShelf.decode(ios)
        assertEquals(SmartShelf(id = "A1", name = "Under 6 Hours", maxHours = 6.0, sort = "shortest"), shelves.single())
        assertEquals(shelves, SmartShelf.decode(SmartShelf.encode(shelves)))
        assertEquals(false, SmartShelf.encode(shelves).contains("minRating"))
        assertEquals(emptyList<SmartShelf>(), SmartShelf.decode("not json"))
    }
}
