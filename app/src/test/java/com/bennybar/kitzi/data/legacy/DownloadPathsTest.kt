package com.bennybar.kitzi.data.legacy

import org.junit.Assert.assertEquals
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class DownloadPathsTest {

    @get:Rule val tmp = TemporaryFolder()

    private fun file(name: String, bytes: Int = 10) =
        tmp.newFile(name).apply { writeBytes(ByteArray(bytes)) }

    /**
     * The offline cover lives next to the tracks. Counting it as a track is what
     * stopped downloaded books playing in 2.0.336, and download adoption had the
     * same mistake — both now go through this one check.
     */
    @Test
    fun `only finished audio files count as tracks`() {
        val kept = listOf(file("track_000.m4a"), file("track_001.mp3"), file("track_002.flac"))
        val dropped = listOf(
            file("cover.jpg"), file("cover.jpg.tmp"), file("cover.hd.png"),
            file("track_003.m4a.part"), file("track_004.m4a", bytes = 0),
        )
        tmp.newFolder("nested")

        val audio = tmp.root.listFiles()!!.filter(DownloadPaths::isAudioFile).map { it.name }.sorted()

        assertEquals(kept.map { it.name }.sorted(), audio)
        dropped.forEach { assert(it.name !in audio) }
    }
}
