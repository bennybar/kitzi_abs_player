package com.bennybar.kitzi.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test
import java.time.LocalDate

class ListeningPaceTest {
    private val today = LocalDate.of(2026, 11, 27)

    @Test
    fun `the pace averages the last 14 days, days off included`() {
        val perDay = mapOf(
            "2026-11-27" to 3600.0,
            "2026-11-14" to 3600.0, // the 14th day back
            "2026-11-13" to 99999.0, // the 15th: left out
        )
        assertEquals(7200.0 / 14, ListeningPace.dailyPaceSec(perDay, today), 0.001)
    }

    @Test
    fun `time left is at the book's speed, and only for a started, unfinished book`() {
        assertEquals(1800.0, ListeningPace.timeLeftSec(0.5, false, 3600.0, 7200.0, 2.0)!!, 0.001)
        assertNull(ListeningPace.timeLeftSec(0.0, false, 0.0, 7200.0, 1.0))
        assertNull(ListeningPace.timeLeftSec(1.0, true, 7200.0, 7200.0, 1.0))
    }

    @Test
    fun `done today when it fits in a day, and counting days after`() {
        assertEquals(today, ListeningPace.finishDate(1800.0, 3600.0, today))
        assertEquals(today, ListeningPace.finishDate(3600.0, 3600.0, today))
        assertEquals(today.plusDays(1), ListeningPace.finishDate(3601.0, 3600.0, today))
        // Under 5 minutes a day isn't a pace.
        assertNull(ListeningPace.finishDate(3600.0, 200.0, today))
    }

    @Test
    fun `the speed to finish spreads what's left over the days up to the target, today included`() {
        // 10 hours left, an hour a day, five days (today and four more): 2x.
        assertEquals(2.0, ListeningPace.speedToFinish(36000.0, 3600.0, today, today.plusDays(4))!!, 0.001)
        // A target in the past still counts as one day.
        assertEquals(10.0, ListeningPace.speedToFinish(36000.0, 3600.0, today, today.minusDays(3))!!, 0.001)
        assertNull(ListeningPace.speedToFinish(36000.0, 60.0, today, today.plusDays(4)))
    }

    @Test
    fun `a needed speed rounds up to a speed the player has`() {
        assertEquals(1.25, ListeningPace.playableSpeed(1.21), 0.0001)
        assertEquals(1.5, ListeningPace.playableSpeed(1.5), 0.0001)
        assertEquals(0.5, ListeningPace.playableSpeed(0.2), 0.0001)
    }
}
