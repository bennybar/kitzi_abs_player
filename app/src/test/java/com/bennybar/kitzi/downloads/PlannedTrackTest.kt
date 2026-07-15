package com.bennybar.kitzi.downloads

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * The download filename is a compatibility contract, not an implementation
 * detail. Existing installs already have files on disk under these names, and
 * playback orders a book's tracks by sorting the filenames. Change the padding,
 * the index, or the extension mapping and every already-downloaded book on every
 * device is orphaned — the user silently loses gigabytes and has to re-download.
 */
class PlannedTrackTest {

    @Test
    fun `matches the real file observed on device`() {
        // Pulled off the emulator from the shipping Flutter app:
        //   app_flutter/abs/lib_<libId>/<itemId>/track_001.m4a
        val track = PlannedTrack(index = 1, fileId = "f", mimeType = "audio/mp4", durationSec = null)
        assertEquals("track_001.m4a", track.filename)
    }

    @Test
    fun `pads the index to three digits`() {
        fun name(i: Int) = PlannedTrack(i, "f", "audio/mpeg", null).filename
        assertEquals("track_000.mp3", name(0))
        assertEquals("track_007.mp3", name(7))
        assertEquals("track_042.mp3", name(42))
        assertEquals("track_999.mp3", name(999))
    }

    /**
     * Zero-padding is what makes a lexicographic sort of the filenames agree with
     * the track order — which is how playback decides what plays first.
     */
    @Test
    fun `lexicographic order of filenames matches track order`() {
        val names = (0..12).map { PlannedTrack(it, "f", "audio/mp4", null).filename }
        assertEquals(names, names.sorted())
    }

    @Test
    fun `derives the extension from the mime type`() {
        fun ext(mime: String) = PlannedTrack.extensionFor(mime)
        assertEquals("mp3", ext("audio/mpeg"))
        assertEquals("m4a", ext("audio/mp4"))
        assertEquals("m4a", ext("audio/aac"))
        assertEquals("flac", ext("audio/flac"))
        assertEquals("opus", ext("audio/opus"))
        assertEquals("ogg", ext("audio/ogg"))
        assertEquals("wav", ext("audio/wav"))
    }

    /** An unknown mime falls back to mp3, never to something a player can't sniff. */
    @Test
    fun `an unknown mime type falls back to mp3`() {
        assertEquals("mp3", PlannedTrack.extensionFor("application/octet-stream"))
        assertEquals("mp3", PlannedTrack.extensionFor(""))
    }
}
