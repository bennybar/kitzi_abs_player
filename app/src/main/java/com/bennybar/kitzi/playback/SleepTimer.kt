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
    /** Stop after a fixed wall-clock duration. */
    data class Duration(val remainingSec: Long) : SleepMode
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
        _mode.value = SleepMode.Duration(minutes * 60L)

        job = scope.launch {
            while (true) {
                val remainingMs = endsAt - SystemClock.elapsedRealtime()
                if (remainingMs <= 0) {
                    controller.player.pause()
                    _mode.value = SleepMode.Off
                    return@launch
                }
                _mode.value = SleepMode.Duration(remainingMs / 1000)
                delay(500)
            }
        }
    }

    /** Needs a locatable chapter; returns false when the book has none. */
    fun startEndOfChapter(): Boolean {
        val chapter = controller.currentChapter() ?: return false
        val itemId = controller.nowPlaying.value?.itemId ?: return false

        cancel()
        val targetEndSec = chapter.endSec

        job = scope.launch {
            while (true) {
                // Bail out if the user switched books.
                if (controller.nowPlaying.value?.itemId != itemId) {
                    _mode.value = SleepMode.Off
                    return@launch
                }

                val pos = controller.globalPositionSec()
                if (pos == null) { delay(500); continue }

                val remaining = targetEndSec - pos
                if (remaining <= 0.5) {
                    controller.player.pause()
                    _mode.value = SleepMode.Off
                    return@launch
                }
                _mode.value = SleepMode.EndOfChapter(remaining.toLong())
                delay(500)
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
}
