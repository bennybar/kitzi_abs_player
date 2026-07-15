package com.bennybar.kitzi.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackMathTest {

    /** Three tracks of 100s, 200s, 300s => book is 600s; track 1 starts at 100, track 2 at 300. */
    private val tracks = listOf(
        Track(0, "a.m4a", "audio/mp4", 100.0, false),
        Track(1, "b.m4a", "audio/mp4", 200.0, false),
        Track(2, "c.m4a", "audio/mp4", 300.0, false),
    )

    @Test
    fun `maps a book position into the right track`() {
        assertEquals(TrackPosition(0, 0.0), PlaybackMath.mapGlobalToTrack(0.0, tracks))
        assertEquals(TrackPosition(0, 50.0), PlaybackMath.mapGlobalToTrack(50.0, tracks))
        assertEquals(TrackPosition(1, 50.0), PlaybackMath.mapGlobalToTrack(150.0, tracks))
        assertEquals(TrackPosition(2, 100.0), PlaybackMath.mapGlobalToTrack(400.0, tracks))
    }

    /** A boundary must land at the START of the next track, not the end of the previous one. */
    @Test
    fun `a position exactly on a track boundary starts the next track`() {
        assertEquals(TrackPosition(1, 0.0), PlaybackMath.mapGlobalToTrack(100.0, tracks))
        assertEquals(TrackPosition(2, 0.0), PlaybackMath.mapGlobalToTrack(300.0, tracks))
    }

    @Test
    fun `a position past the end of the book clamps to the end`() {
        assertEquals(TrackPosition(2, 300.0), PlaybackMath.mapGlobalToTrack(9999.0, tracks))
    }

    @Test
    fun `an unknown duration means the target is assumed to be inside that track`() {
        val partial = listOf(
            Track(0, "a", "audio/mp4", 100.0, true),
            Track(1, "b", "audio/mp4", null, true),
            Track(2, "c", "audio/mp4", null, true),
        )
        // Not enough information to skip past track 1, so we stay in it.
        assertEquals(TrackPosition(1, 250.0), PlaybackMath.mapGlobalToTrack(350.0, partial))
    }

    @Test
    fun `converts a track position back to a book position`() {
        assertEquals(0.0, PlaybackMath.computeGlobal(0, 0.0, tracks)!!, 1e-9)
        assertEquals(150.0, PlaybackMath.computeGlobal(1, 50.0, tracks)!!, 1e-9)
        assertEquals(400.0, PlaybackMath.computeGlobal(2, 100.0, tracks)!!, 1e-9)
    }

    /**
     * The guard that protects the user's progress: if an earlier track's duration
     * is unknown, the book position is unknowable. Returning 0 (or the track
     * position) here would overwrite the server with a tiny number and lose the
     * user's place in the book.
     */
    @Test
    fun `book position is null when an earlier track duration is unknown`() {
        val partial = listOf(
            Track(0, "a", "audio/mp4", null, true),
            Track(1, "b", "audio/mp4", 200.0, true),
        )
        assertNull(PlaybackMath.computeGlobal(1, 10.0, partial))
        // Track 0 has no prefix to sum, so it is still answerable.
        assertEquals(10.0, PlaybackMath.computeGlobal(0, 10.0, partial)!!, 1e-9)
    }

    @Test
    fun `mapping round-trips across the whole book`() {
        var s = 0.0
        while (s <= 600.0) {
            val tp = PlaybackMath.mapGlobalToTrack(s, tracks)
            val back = PlaybackMath.computeGlobal(tp.trackIndex, tp.offsetSec, tracks)!!
            assertEquals("round-trip failed at ${s}s", s, back, 1e-6)
            s += 0.5
        }
    }

    @Test
    fun `total duration prefers the server figure when a track is unknown`() {
        assertEquals(600.0, PlaybackMath.totalDuration(tracks, null)!!, 1e-9)

        val partial = tracks.mapIndexed { i, t -> if (i == 2) t.copy(durationSec = null) else t }
        // Summing what we know gives 300 — but the book is really 600.
        assertEquals(600.0, PlaybackMath.totalDuration(partial, 600.0)!!, 1e-9)
    }

    // ---- chapters ----------------------------------------------------------

    /** Chapters deliberately straddle track boundaries: 0-250 spans tracks 0 and 1. */
    private val chapters = listOf(
        Chapter("One", 0.0),
        Chapter("Two", 250.0),
        Chapter("Three", 500.0),
    )

    @Test
    fun `locates a chapter that spans a track boundary`() {
        val m = PlaybackMath.currentChapter(150.0, chapters, 600.0)!!
        assertEquals(0, m.index)
        assertEquals("One", m.title)
        assertEquals(0.0, m.startSec, 1e-9)
        assertEquals(250.0, m.endSec, 1e-9)
        assertEquals(150.0, m.elapsedSec, 1e-9)
        // 150s is inside track 1, but it is still chapter One.
        assertEquals(1, PlaybackMath.mapGlobalToTrack(150.0, tracks).trackIndex)
    }

    @Test
    fun `the last chapter ends at the end of the book`() {
        val m = PlaybackMath.currentChapter(550.0, chapters, 600.0)!!
        assertEquals(2, m.index)
        assertEquals(600.0, m.endSec, 1e-9)
        assertEquals(50.0, m.elapsedSec, 1e-9)
    }

    @Test
    fun `a position exactly on a chapter start belongs to that chapter`() {
        assertEquals(1, PlaybackMath.currentChapter(250.0, chapters, 600.0)!!.index)
        assertEquals(0.0, PlaybackMath.currentChapter(250.0, chapters, 600.0)!!.elapsedSec, 1e-9)
    }

    @Test
    fun `chapter navigation moves by chapter, not by 30 seconds`() {
        assertEquals(250.0, PlaybackMath.nextChapterStart(150.0, chapters, 600.0)!!, 1e-9)
        // Previous means the previous chapter's start, not the current one's.
        assertEquals(0.0, PlaybackMath.previousChapterStart(300.0, chapters, 600.0)!!, 1e-9)
        assertNull(PlaybackMath.nextChapterStart(550.0, chapters, 600.0))
        assertNull(PlaybackMath.previousChapterStart(100.0, chapters, 600.0))
    }

    @Test
    fun `chapters derived from tracks refuse to collapse when a duration is unknown`() {
        assertEquals(3, PlaybackMath.chaptersFromTracks(tracks).size)
        assertEquals(listOf(0.0, 100.0, 300.0), PlaybackMath.chaptersFromTracks(tracks).map { it.startSec })

        // With an unknown duration every chapter would start at the same place —
        // better to have no chapters than three that all start at 0.
        val partial = tracks.mapIndexed { i, t -> if (i == 1) t.copy(durationSec = null) else t }
        assertTrue(PlaybackMath.chaptersFromTracks(partial).isEmpty())
    }
}
