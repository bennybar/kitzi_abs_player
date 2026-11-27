package com.bennybar.kitzi.data.audible

import com.bennybar.kitzi.data.audible.SeriesSync.Entry
import com.bennybar.kitzi.data.model.BookMapper
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SeriesSyncTest {
    /** A book as the library list gives it: series packed into seriesName. */
    private fun listed(seriesName: String) = BookMapper.fromLibraryItem(
        Json.parseToJsonElement(
            """{"id":"1","media":{"duration":100,"metadata":{"title":"T","seriesName":${JsonPrimitive(seriesName)}}}}"""
        ) as JsonObject,
        "https://abs",
    )!!

    @Test
    fun `none on the server - Audible's are added`() {
        val audible = listOf(Entry("The Titan Trilogy", "1"))
        assertEquals(audible, SeriesSync.merge(emptyList(), audible))
        assertEquals("The Titan Trilogy #1", SeriesSync.Change(emptyList(), audible).summary)
    }

    @Test
    fun `one each with different names - the server's is replaced`() {
        val out = SeriesSync.merge(listOf(Entry("Expanse", "3")), listOf(Entry("The Expanse Saga", "3")))
        assertEquals(listOf(Entry("The Expanse Saga", "3")), out)
    }

    @Test
    fun `a similar name is renamed and renumbered, the others kept`() {
        val server = listOf(Entry("My Favourites", null), Entry("Expanse", "2"))
        val out = SeriesSync.merge(server, listOf(Entry("Expanse Saga", "1")))
        assertEquals(listOf(Entry("My Favourites", null), Entry("Expanse Saga", "1")), out)
        assertEquals("Expanse #2 → Expanse Saga #1", SeriesSync.Change(server, out).summary)
    }

    @Test
    fun `extra server series are kept and a new one is added`() {
        val server = listOf(Entry("Discworld", "1"), Entry("Mine", null))
        val out = SeriesSync.merge(server, listOf(Entry("Discworld", "1"), Entry("Rincewind", "1")))
        assertEquals(listOf(Entry("Discworld", "1"), Entry("Mine", null), Entry("Rincewind", "1")), out)
    }

    @Test
    fun `no number from Audible keeps the server's`() {
        assertEquals(listOf(Entry("Saga", "4")), SeriesSync.merge(listOf(Entry("Saga", "4")), listOf(Entry("Saga", null))))
    }

    @Test
    fun `the same number written differently is the same`() {
        assertTrue(SeriesSync.same(listOf(Entry("A", "3")), listOf(Entry("A", "3.0"))))
        assertFalse(SeriesSync.same(listOf(Entry("A", "1-4")), listOf(Entry("A", "1-3"))))
        assertFalse(SeriesSync.same(listOf(Entry("A", null)), listOf(Entry("A", "1-4"))))
    }

    @Test
    fun `packed series string parses to each series`() {
        assertEquals(
            listOf(Entry("The Dune Sequence", "1"), Entry("DUNE: Legends of Dune", "1")),
            SeriesSync.entries(listed("The Dune Sequence #1, DUNE: Legends of Dune #1")),
        )
    }

    @Test
    fun `a range is kept`() {
        assertEquals(listOf(Entry("Four Past Midnight", "1-4")), SeriesSync.entries(listed("Four Past Midnight #1-4")))
    }

    @Test
    fun `a comma in a name is not a second series`() {
        assertEquals(listOf(Entry("Love, Death and Robots", "2")), SeriesSync.entries(listed("Love, Death and Robots #2")))
        assertEquals(listOf(Entry("Expanse", "4.5")), SeriesSync.entries(listed("Expanse #4.5")))
    }
}
