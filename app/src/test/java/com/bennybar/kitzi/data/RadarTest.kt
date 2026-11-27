package com.bennybar.kitzi.data

import com.bennybar.kitzi.data.audible.AudibleBook
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.LocalDate
import java.time.ZoneId

class RadarTest {
    private val today = LocalDate.of(2026, 11, 27)

    private fun audible(release: String?, language: String? = "English", authors: List<String> = listOf("Andy Weir")) = AudibleBook(
        asin = "B1", title = "T", subtitle = null, authors = authors, narrators = emptyList(), coverUrl = null,
        thumbUrl = null, stars = null, ratingCount = 0, performanceStars = null, storyStars = null, minutes = null,
        format = null, kind = null, releaseDate = release, language = language, publisher = null,
        seriesRefs = emptyList(), genreRefs = emptyList(), summary = null,
    )

    private fun seconds(day: LocalDate) = day.atStartOfDay(ZoneId.systemDefault()).plusHours(12).toEpochSecond().toDouble()

    private fun find(asin: String, release: LocalDate, foundOn: LocalDate = today, announcedOut: Boolean = false) =
        RadarFind(asin, asin, null, null, release.toString(), "New from Andy Weir", seconds(foundOn), announcedOut)

    @Test
    fun `window is six weeks back to six months ahead, in the library's language`() {
        assertTrue(Radar.inWindow(audible("2026-10-16"), "english", today)) // 42 days ago
        assertFalse(Radar.inWindow(audible("2026-10-15"), "english", today))
        assertTrue(Radar.inWindow(audible("2027-05-27"), "english", today))
        assertFalse(Radar.inWindow(audible("2027-05-28"), "english", today))
        assertFalse(Radar.inWindow(audible(null), "english", today))
        assertFalse(Radar.inWindow(audible("2026-11-20", language = "German"), "english", today))
        assertTrue(Radar.inWindow(audible("2026-11-20", language = null), "english", today))
    }

    @Test
    fun `an author's own books only, not anthologies or books with them`() {
        assertTrue(Radar.ownBook(audible("2026-11-20", authors = listOf("andy weir", "X")), "Andy Weir"))
        assertFalse(Radar.ownBook(audible("2026-11-20", authors = listOf("A", "B", "C", "Andy Weir")), "Andy Weir"))
        assertFalse(Radar.ownBook(audible("2026-11-20", authors = listOf("Someone Else")), "Andy Weir"))
    }

    @Test
    fun `new finds are notified, out ones marked announced, known ones kept as they were`() {
        val old = find("OLD", today.plusDays(30))
        val found = mapOf(
            "OLD" to find("OLD", today.plusDays(30)).copy(reason = "changed"),
            "NEW" to find("NEW", today.plusDays(5)),
            "OUT" to find("OUT", today.minusDays(3)),
        )
        val m = Radar.merge(listOf(old), found, incomplete = false, firstRun = false, today = today)
        assertEquals(listOf("NEW", "OUT"), m.fresh.map { it.asin })
        assertEquals(listOf(false, true), m.fresh.map { it.announcedOut })
        assertEquals("New from Andy Weir", m.finds.first { it.asin == "OLD" }.reason)
        assertTrue(m.nowOut.isEmpty())
    }

    @Test
    fun `the first run notifies nothing`() {
        val m = Radar.merge(emptyList(), mapOf("NEW" to find("NEW", today.plusDays(5))), incomplete = false, firstRun = true, today = today)
        assertEquals(listOf("NEW"), m.finds.map { it.asin })
        assertTrue(m.fresh.isEmpty() && m.nowOut.isEmpty())
    }

    @Test
    fun `a find that was coming is out today once`() {
        val coming = find("C", release = today, foundOn = today.minusDays(10))
        val m = Radar.merge(listOf(coming), mapOf("C" to coming), incomplete = false, firstRun = false, today = today)
        assertEquals(listOf("C"), m.nowOut.map { it.asin })
        assertTrue(m.finds.single().announcedOut)
        // Already announced, or found after it came out: not again.
        val again = Radar.merge(m.finds, mapOf("C" to coming), incomplete = false, firstRun = false, today = today)
        assertTrue(again.nowOut.isEmpty())
        val late = find("L", release = today.minusDays(2), foundOn = today.minusDays(1))
        assertTrue(Radar.merge(listOf(late), mapOf("L" to late), false, false, today).nowOut.isEmpty())
    }

    @Test
    fun `an incomplete check keeps earlier finds still in the window`() {
        val kept = find("KEPT", today.minusDays(10))
        val stale = find("STALE", today.minusDays(60))
        val complete = Radar.merge(listOf(kept, stale), emptyMap(), incomplete = false, firstRun = false, today = today)
        assertTrue(complete.finds.isEmpty())
        val partial = Radar.merge(listOf(kept, stale), emptyMap(), incomplete = true, firstRun = false, today = today)
        assertEquals(listOf("KEPT"), partial.finds.map { it.asin })
    }
}
