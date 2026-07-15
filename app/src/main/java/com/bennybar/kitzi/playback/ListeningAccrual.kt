package com.bennybar.kitzi.playback

/**
 * Tracks how long the user has actually spent *listening*, to report as
 * `timeListened` on progress sync.
 *
 * This is WALL-CLOCK time spent playing. It is deliberately not derived from how
 * far the playhead moved: a user who skips three chapters moves the playhead by
 * hours without listening to any of it, and deriving from position delta bills
 * them for it. Nor is it scaled by playback speed — at 2x, 26 seconds of
 * listening is 26 seconds of `timeListened` even though the position advanced 52.
 *
 * Uses a monotonic clock so an NTP correction or a user changing the device
 * clock can't inject phantom hours.
 */
class ListeningAccrual(
    private val nowMs: () -> Long = { android.os.SystemClock.elapsedRealtime() },
) {
    private var playStartedAt: Long? = null
    private var pendingSec: Double = 0.0

    val pending: Double get() = pendingSec

    /** Call when playback actually starts rendering audio (not merely buffering). */
    fun onPlaybackStarted() {
        if (playStartedAt == null) playStartedAt = nowMs()
    }

    /** Call when playback stops. Captures the final partial interval before clearing. */
    fun onPlaybackStopped() {
        accrue()
        playStartedAt = null
    }

    /** Folds elapsed wall-clock time into the pending total and re-arms. Idempotent. */
    fun accrue() {
        val started = playStartedAt ?: return
        val now = nowMs()
        val elapsed = (now - started) / 1000.0
        if (elapsed > 0) pendingSec += elapsed
        playStartedAt = now
    }

    /** The value to send, or null when there is nothing to report. */
    fun snapshot(): Double? {
        accrue()
        return pendingSec.takeIf { it > 0 }
    }

    /**
     * Call ONLY after the server accepted the sync. On failure the time stays
     * pending and rolls into the next successful report — that is what makes
     * listening time survive an offline stretch instead of being lost.
     */
    fun consume(reported: Double) {
        pendingSec = (pendingSec - reported).coerceAtLeast(0.0)
    }

    /** New book: nothing carries over. */
    fun reset() {
        playStartedAt = null
        pendingSec = 0.0
    }
}
