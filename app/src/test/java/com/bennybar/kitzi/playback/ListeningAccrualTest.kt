package com.bennybar.kitzi.playback

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ListeningAccrualTest {

    private var clock = 0L
    private fun accrual() = ListeningAccrual { clock }
    private fun advance(seconds: Long) { clock += seconds * 1000 }

    /**
     * THE regression this class exists for.
     *
     * The user plays 10s, skips three chapters (moving the playhead ~3 hours),
     * plays 10s more, and pauses. They listened for 20 seconds. An implementation
     * that derives listening time from how far the playhead moved would report
     * roughly three hours — which is exactly the bug that shipped once.
     *
     * Note the seeks aren't even mentioned below: wall-clock accrual is
     * structurally incapable of seeing them, which is the point.
     */
    @Test
    fun `skipping chapters does not bill listening time`() {
        val a = accrual()

        a.onPlaybackStarted()
        advance(10)
        a.onPlaybackStopped()

        // ... user skips three chapters. Playhead jumps hours. No time passes.

        a.onPlaybackStarted()
        advance(10)
        a.onPlaybackStopped()

        assertEquals(20.0, a.snapshot()!!, 0.001)
    }

    @Test
    fun `accrues only while playing`() {
        val a = accrual()

        a.onPlaybackStarted()
        advance(30)
        a.onPlaybackStopped()

        // Paused for an hour — must not count.
        advance(3600)

        assertEquals(30.0, a.snapshot()!!, 0.001)
    }

    @Test
    fun `time is not scaled by playback speed`() {
        // At 2x, 26 seconds of listening advances the position by 52 seconds, but
        // the user still only listened for 26 seconds. Nothing here knows about
        // speed, and that is deliberate.
        val a = accrual()
        a.onPlaybackStarted()
        advance(26)
        assertEquals(26.0, a.snapshot()!!, 0.001)
    }

    @Test
    fun `unreported time survives failed syncs and rolls into the next success`() {
        val a = accrual()

        a.onPlaybackStarted()
        advance(26)
        val first = a.snapshot()!!          // sync attempt #1 -> fails, do NOT consume
        assertEquals(26.0, first, 0.001)

        advance(26)
        val second = a.snapshot()!!         // attempt #2 -> fails
        assertEquals(52.0, second, 0.001)

        advance(26)
        val third = a.snapshot()!!          // attempt #3 -> succeeds
        assertEquals(78.0, third, 0.001)
        a.consume(third)

        // Everything reported once, and only once.
        a.onPlaybackStopped()
        assertNull(a.snapshot())
    }

    @Test
    fun `a successful sync consumes only what it reported`() {
        val a = accrual()
        a.onPlaybackStarted()
        advance(26)

        val reported = a.snapshot()!!
        advance(4)              // more listening happens while the request is in flight
        a.consume(reported)     // only the reported amount is cleared

        assertEquals(4.0, a.snapshot()!!, 0.001)
    }

    @Test
    fun `a new book starts from zero`() {
        val a = accrual()
        a.onPlaybackStarted()
        advance(100)
        a.reset()
        assertNull(a.snapshot())
    }

    @Test
    fun `accrue is idempotent`() {
        val a = accrual()
        a.onPlaybackStarted()
        advance(10)
        a.accrue(); a.accrue(); a.accrue()
        assertEquals(10.0, a.snapshot()!!, 0.001)
    }
}
