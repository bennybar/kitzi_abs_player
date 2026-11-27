package com.bennybar.kitzi.data

import java.time.LocalDate
import java.time.temporal.ChronoUnit
import kotlin.math.ceil

/**
 * "At your pace": the recent daily listening, when a book would be done at it, and
 * the speed a book needs to be done by a chosen day.
 */
object ListeningPace {
    /** Below this a day (5 minutes), there isn't enough listening to work a pace out. */
    const val MIN_PACE_SEC = 5 * 60.0

    /** Listening per day, averaged over the last 14 days (days off included). [perDay]: "yyyy-MM-dd" to seconds. */
    fun dailyPaceSec(perDay: Map<String, Double>, today: LocalDate): Double =
        (0L until 14L).sumOf { perDay[today.minusDays(it).toString()] ?: 0.0 } / 14

    /** Listening time left in a started, unfinished book at [speed]; null when not started or finished. */
    fun timeLeftSec(progress: Double, finished: Boolean, currentSec: Double, durationSec: Double, speed: Double): Double? {
        if (progress <= 0 || finished) return null
        val left = (durationSec - currentSec).coerceAtLeast(0.0) / speed.coerceAtLeast(0.1)
        return left.takeIf { it > 0 }
    }

    /** The day [leftSec] of listening is done at [paceSec] a day (today counts); null without a pace. */
    fun finishDate(leftSec: Double, paceSec: Double, today: LocalDate): LocalDate? {
        if (paceSec < MIN_PACE_SEC || leftSec <= 0) return null
        val days = ceil(leftSec / paceSec).toLong()
        return today.plusDays((days - 1).coerceAtLeast(0))
    }

    /** The speed that gets [contentLeftSec] of book done by [by] at [paceSec] a day; null without a pace. */
    fun speedToFinish(contentLeftSec: Double, paceSec: Double, today: LocalDate, by: LocalDate): Double? {
        if (paceSec < MIN_PACE_SEC) return null
        val days = (ChronoUnit.DAYS.between(today, by) + 1).coerceAtLeast(1)
        return contentLeftSec / (paceSec * days)
    }

    /** A needed speed as one the player offers: up to the next 0.05, and no slower than 0.5×. */
    fun playableSpeed(speed: Double): Double = ceil(speed.coerceAtLeast(0.5) * 20) / 20
}
