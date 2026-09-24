package com.bennybar.kitzi.playback

import android.os.SystemClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

sealed interface SleepMode {
    data object Off : SleepMode
    /**
     * Stop after a fixed wall-clock duration. Holds the end time (elapsedRealtime),
     * not a countdown, so the timer needn't wake every half second just to publish
     * one; whoever shows the countdown ticks it while it's on screen.
     */
    data class Duration(val endsAtElapsedMs: Long) : SleepMode {
        val remainingSec: Long get() = ((endsAtElapsedMs - SystemClock.elapsedRealtime()) / 1000).coerceAtLeast(0)
    }
    /** Stop when the current chapter ends. */
    data class EndOfChapter(val remainingSec: Long) : SleepMode
}

/**
 * Sleep timer.
 *
 * Ticks off a monotonic clock rather than counting `delay(1000)` calls, because
 * under Doze those calls are coalesced and a naive accumulator drifts badly —
 * the user wakes up to a book that kept playing for an hour.
 *
 * End-of-chapter tracks the chapter's END in BOOK coordinates, so it survives the
 * playhead crossing a track boundary mid-chapter.
 */
class SleepTimer(private val controller: PlaybackController) {

    private val scope = CoroutineScope(Dispatchers.Main)
    private var job: Job? = null

    private val _mode = MutableStateFlow<SleepMode>(SleepMode.Off)
    val mode: StateFlow<SleepMode> = _mode.asStateFlow()

    fun startDuration(minutes: Int) {
        cancel()
        val endsAt = SystemClock.elapsedRealtime() + minutes * 60_000L
        _mode.value = SleepMode.Duration(endsAt)

        job = scope.launch {
            while (true) {
                val remainingMs = endsAt - SystemClock.elapsedRealtime()
                if (remainingMs <= 0) {
                    controller.player.pause()
                    _mode.value = SleepMode.Off
                    return@launch
                }
                // Sleep until the end, re-checking at least every 30 s: delay runs on
                // uptime, which stops while the CPU sleeps, so a single long delay
                // could fire late; the monotonic clock above is the authority.
                delay(remainingMs.coerceAtMost(MAX_WAIT_MS))
            }
        }
    }

    /** Needs a locatable chapter; returns false when the book has none. */
    fun startEndOfChapter(): Boolean {
        val chapter = controller.currentChapter() ?: return false
        val itemId = controller.nowPlaying.value?.itemId ?: return false

        cancel()
        var targetEndSec = chapter.endSec
        var seenSeeks = controller.seekGeneration

        job = scope.launch {
            while (true) {
                // Bail out if the user switched books.
                if (controller.nowPlaying.value?.itemId != itemId) {
                    _mode.value = SleepMode.Off
                    return@launch
                }

                val pos = controller.globalPositionSec()
                if (pos == null) { delay(500); continue }

                // A seek or skip means "the end of the chapter I'm in now". The target
                // used to stay fixed, so skipping into the next chapter was already
                // past it and paused at once. Playing on into the next chapter is not
                // a seek, so a natural chapter end still pauses.
                if (controller.seekGeneration != seenSeeks) {
                    seenSeeks = controller.seekGeneration
                    controller.currentChapter()?.let { targetEndSec = it.endSec }
                }

                val remaining = targetEndSec - pos
                if (remaining <= 0.5) {
                    controller.player.pause()
                    _mode.value = SleepMode.Off
                    return@launch
                }
                _mode.value = SleepMode.EndOfChapter(remaining.toLong())
                // Wake just before the chapter ends (media time, converted at the
                // current speed) instead of twice a second — but at least every 30 s,
                // so a seek or speed change is picked up. Paused, just re-check.
                val speed = if (controller.player.isPlaying) controller.player.playbackParameters.speed else 0f
                val waitMs = if (speed > 0f) ((remaining - 0.25) / speed * 1000).toLong() else MAX_WAIT_MS
                delay(waitMs.coerceIn(MIN_WAIT_MS, MAX_WAIT_MS))
            }
        }
        return true
    }

    fun addMinutes(minutes: Int) {
        val current = _mode.value
        if (current is SleepMode.Duration) {
            startDuration(((current.remainingSec / 60) + minutes).toInt().coerceAtLeast(1))
        }
    }

    fun cancel() {
        job?.cancel()
        job = null
        _mode.value = SleepMode.Off
    }

    private companion object {
        /** The longest the timer sleeps between checks. */
        const val MAX_WAIT_MS = 30_000L
        const val MIN_WAIT_MS = 200L
    }
}
