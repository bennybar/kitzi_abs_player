package com.bennybar.kitzi.data.audible

import com.bennybar.kitzi.data.model.Book
import org.junit.Assert.assertEquals
import org.junit.Test
import java.time.LocalDate

class SeriesLadderTest {
    private val today = LocalDate.of(2026, 11, 27)
    private val series = "SER"

    private fun audible(asin: String, seq: String?, release: String = "2020-01-01", ratings: Int = 0) = AudibleBook(
        asin = asin, title = asin, subtitle = null, authors = emptyList(), narrators = emptyList(), coverUrl = null,
        thumbUrl = null, stars = null, ratingCount = ratings, performanceStars = null, storyStars = null, minutes = null,
        format = null, kind = null, releaseDate = release, language = null, publisher = null,
        seriesRefs = listOf(AudibleBook.SeriesRef(series, "Saga", seq)), genreRefs = emptyList(), summary = null,
    )

    private fun mine(id: String, seq: Double?) = Book(
        id = id, title = id, author = null, coverUrl = "", description = null, durationMs = null, sizeBytes = null,
        updatedAt = null, addedAt = null, series = "Saga", seriesSequence = seq, collection = null, collectionSequence = null,
        isAudioBook = true, mediaKind = null, libraryId = null, authors = emptyList(), narrators = emptyList(),
        publisher = null, publishYear = null, genres = emptyList(),
    )

    @Test
    fun `missing books leave out what's here, by ASIN or number, and placeholder dates`() {
        val all = listOf(
            audible("B1", "1"), // here by ASIN
            audible("B2", "2"), // here by number (another edition)
            audible("B3", "3", ratings = 900),
            audible("B3X", "3", ratings = 5), // a second edition of 3: one per number
            audible("BOX", "1-2"), // a box set of books that are here
            audible("B4", "4", release = "2027-03-12"), // coming
            audible("B5", "5", release = "2200-01-01"), // Audible's "no date"
            audible("SIDE", null), // unnumbered
        )
        val missing = AudibleCatalog.missingFromSeries(all, series, inLibrary = setOf("B1"), owned = setOf(1.0, 2.0), today = today)
        assertEquals(listOf("B3", "B4", "SIDE"), missing.map { it.book.asin })
        assertEquals(listOf(3.0, 4.0, null), missing.map { it.sequence })
    }

    @Test
    fun `the ladder is in series order, yours first at the same number, unnumbered last`() {
        val missing = listOf(
            SeriesRung.Missing(audible("A2", "2"), 2.0),
            SeriesRung.Missing(audible("A2B", "2.5"), 2.5),
            SeriesRung.Missing(audible("SIDE", null), null),
        )
        val ladder = AudibleCatalog.ladder(listOf(mine("m1", 1.0), mine("m2", 2.0), mine("m3", 3.0), mine("mx", null)), missing)
        val ids = ladder.map {
            when (it) {
                is SeriesRung.Mine -> it.book.id
                is SeriesRung.Missing -> it.book.asin
            }
        }
        assertEquals(listOf("m1", "m2", "A2", "A2B", "m3", "mx", "SIDE"), ids)
    }
}
