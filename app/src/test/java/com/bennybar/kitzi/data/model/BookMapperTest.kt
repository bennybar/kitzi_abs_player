package com.bennybar.kitzi.data.model

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BookMapperTest {

    private fun map(json: String) =
        BookMapper.fromLibraryItem(Json.parseToJsonElement(json).jsonObject, "https://s", null)

    private fun withSeries(series: String) = map(
        """{"id":"1","media":{"duration":100,"metadata":{"title":"T","series":$series}}}"""
    )

    /**
     * ABS minified responses put the sequence in the series string. Grouping on it
     * verbatim splits "Bill Hodges Trilogy" into three one-book series.
     */
    @Test
    fun `splits the sequence out of a series name`() {
        val book = withSeries("\"Bill Hodges Trilogy #1\"")!!
        assertEquals("Bill Hodges Trilogy", book.series)
        assertEquals(1.0, book.seriesSequence!!, 1e-9)
    }

    @Test
    fun `handles a decimal sequence`() {
        val book = withSeries("\"The Expanse #4.5\"")!!
        assertEquals("The Expanse", book.series)
        assertEquals(4.5, book.seriesSequence!!, 1e-9)
    }

    @Test
    fun `handles Book N and Volume N suffixes`() {
        assertEquals("Foundation", withSeries("\"Foundation Book 2\"")!!.series)
        assertEquals("Dune", withSeries("\"Dune Volume 3\"")!!.series)
    }

    @Test
    fun `leaves a series with no sequence alone`() {
        val book = withSeries("\"Discworld\"")!!
        assertEquals("Discworld", book.series)
        assertNull(book.seriesSequence)
    }

    /** A '#' inside the title itself must not be mistaken for a sequence. */
    @Test
    fun `does not mangle a name that merely contains a hash`() {
        assertEquals("Agent #6 Chronicles", withSeries("\"Agent #6 Chronicles\"")!!.series)
    }

    @Test
    fun `an object series keeps its explicit sequence`() {
        val book = withSeries("""{"name":"Bobiverse","sequence":"5"}""")!!
        assertEquals("Bobiverse", book.series)
        assertEquals(5.0, book.seriesSequence!!, 1e-9)
    }

    @Test
    fun `an ebook is not an audiobook`() {
        val ebook = map("""{"id":"1","media":{"duration":0,"ebookFormat":"epub","metadata":{"title":"T"}}}""")!!
        assertTrue(!ebook.isAudioBook)

        val audio = map("""{"id":"2","media":{"duration":3600,"metadata":{"title":"T"}}}""")!!
        assertTrue(audio.isAudioBook)
    }

    @Test
    fun `drops items with no title`() {
        assertNull(map("""{"id":"1","media":{"metadata":{}}}"""))
    }

    @Test
    fun `seconds and milliseconds timestamps both parse`() {
        val secs = map("""{"id":"1","updatedAt":1700000000,"media":{"duration":10,"metadata":{"title":"T"}}}""")!!
        val millis = map("""{"id":"2","updatedAt":1700000000000,"media":{"duration":10,"metadata":{"title":"T"}}}""")!!
        assertEquals(millis.updatedAt, secs.updatedAt)
    }
}
