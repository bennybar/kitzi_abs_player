package com.bennybar.kitzi.wear

import android.content.Context
import android.net.Uri
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.text.DateFormat
import java.util.Date
import java.util.UUID

/** The book that's loaded, in book coordinates. */
data class NowPlaying(
    val book: Book,
    val tracks: List<TrackFile>,
    val chapters: List<Chapter>,
    /** Playing from files on the watch (else streaming through [sessionId]). */
    val local: Boolean,
    val sessionId: String?,
) {
    val totalSec: Double get() = tracks.sumOf { it.durationSec }.takeIf { it > 0 } ?: book.durationSec
}

/**
 * Plays one book and keeps the server in step: every 30 s while playing, on every
 * pause, at the end, and on demand ([reportNow]). A report that can't reach the
 * server is kept on the watch ("pending") and pushed by [SyncWorker] when the
 * network is back.
 */
@androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
class WearPlayer(private val context: Context, private val k: Kitzi) {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val syncMutex = Mutex()

    private val _nowPlaying = MutableStateFlow<NowPlaying?>(null)
    val nowPlaying: StateFlow<NowPlaying?> = _nowPlaying.asStateFlow()
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()
    private val _loading = MutableStateFlow(false)
    val loading: StateFlow<Boolean> = _loading.asStateFlow()
    /** The last sync, for the player screen ("Synced 14:02", "Saved on watch…"). */
    private val _status = MutableStateFlow<String?>(null)
    val status: StateFlow<String?> = _status.asStateFlow()

    // Listening time not yet recorded by the server, in wall-clock seconds.
    private var listenedSec = 0.0
    private var playingSince: Long? = null

    // A downloaded book's listening goes to the server as a "local" session.
    private var localSessionId: String? = null
    private var localStartedAt = 0L
    private var localStartSec = 0.0
    private var localListenedTotal = 0.0

    /** Built on the main looper whoever touches it first (a worker may init Kitzi). */
    val exo: ExoPlayer by lazy {
        val http = OkHttpDataSource.Factory(k.api.client)
        ExoPlayer.Builder(context)
            .setLooper(Looper.getMainLooper())
            .setMediaSourceFactory(DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http)))
            .setAudioAttributes(
                AudioAttributes.Builder().setUsage(C.USAGE_MEDIA).setContentType(C.AUDIO_CONTENT_TYPE_SPEECH).build(),
                true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setWakeMode(C.WAKE_MODE_NETWORK)
            .setSeekBackIncrementMs(SKIP_MS)
            .setSeekForwardIncrementMs(SKIP_MS)
            // On a watch, audio belongs in headphones: with none connected, Media3
            // pauses and opens the Bluetooth picker instead of using the speaker.
            // Off in debug builds, so the emulator (no Bluetooth) can play.
            .setSuppressPlaybackOnUnsuitableOutput(!BuildConfig.DEBUG)
            .build()
            .also { it.addListener(Events()) }
    }

    init {
        scope.launch {
            while (true) {
                delay(SYNC_EVERY_MS)
                if (_isPlaying.value) reportNow()
            }
        }
    }

    fun playingItemId(): String? = _nowPlaying.value?.book?.id?.takeIf { _isPlaying.value }

    /** Plays [book] from the newer of the watch's and the server's positions. Null, or why it can't. */
    suspend fun play(book: Book): String? {
        val current = _nowPlaying.value
        if (current?.book?.id == book.id && exo.mediaItemCount > 0 && exo.playerError == null) {
            if (exo.playbackState == Player.STATE_ENDED) seekTo(0.0)
            exo.prepare()
            exo.play()
            return null
        }
        if (current != null) stop()
        _loading.value = true
        try {
            val saved = k.downloads.downloaded(book.id)
            val np = if (saved != null) {
                NowPlaying(saved.book.copy(currentTimeSec = book.currentTimeSec), saved.tracks, saved.chapters, true, null)
            } else {
                val session = withContext(Dispatchers.IO) { k.api.openSession(book.id) }
                    ?: return "Can't reach the server. Download the book to listen offline."
                if (session.tracks.isEmpty()) return "This book has no playable audio."
                NowPlaying(book, session.tracks, session.chapters, false, session.id)
            }
            var start = startPosition(book)
            if (start >= np.totalSec - 5) start = 0.0 // finished: from the top

            val cover: Uri? = k.downloads.coverFile(book.id)?.let { Uri.fromFile(it) }
            val items = np.tracks.map { t ->
                MediaItem.Builder()
                    .setUri(t.url)
                    .setMimeType(t.mimeType)
                    .setMediaMetadata(
                        MediaMetadata.Builder()
                            .setTitle(book.title)
                            .setArtist(book.author)
                            .setArtworkUri(cover)
                            .build()
                    )
                    .build()
            }
            val (index, offset) = locate(start, np.tracks)
            exo.setMediaItems(items, index, (offset * 1000).toLong())
            exo.prepare()
            _nowPlaying.value = np
            k.store.lastBookId = book.id
            listenedSec = 0.0
            if (np.local) {
                localSessionId = UUID.randomUUID().toString()
                localStartedAt = System.currentTimeMillis()
                localStartSec = start
                localListenedTotal = 0.0
            } else localSessionId = null
            exo.play()
            return null
        } finally {
            _loading.value = false
        }
    }

    /** The newer of the watch's saved position and the server's (if it can be reached quickly). */
    private suspend fun startPosition(book: Book): Double {
        val local = k.store.position(book.id)
        // At most a few seconds: a blocking request can't be cancelled, so the wait
        // is on a detached call (it may finish later, harmlessly). No network: skip.
        val server = if (!hasNetwork()) null else {
            val fetch = scope.async(Dispatchers.IO) { runCatching { k.api.progress(book.id) }.getOrNull() }
            withTimeoutOrNull(5_000) { fetch.await() }
        }
        return when {
            server != null && local != null -> if (local.savedAt > server.second) local.sec else server.first
            server != null -> server.first
            local != null -> local.sec
            else -> book.currentTimeSec
        }
    }

    private fun hasNetwork(): Boolean {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        return cm.getNetworkCapabilities(cm.activeNetwork)
            ?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }

    fun togglePlay() {
        if (exo.isPlaying) exo.pause()
        else if (_nowPlaying.value != null) {
            if (exo.playbackState == Player.STATE_ENDED) seekTo(0.0)
            if (exo.playbackState == Player.STATE_IDLE) exo.prepare()
            exo.play()
        }
    }

    fun skip(deltaSec: Double) {
        val pos = positionSec() ?: return
        seekTo((pos + deltaSec).coerceIn(0.0, (_nowPlaying.value?.totalSec ?: 0.0)))
    }

    fun seekTo(sec: Double) {
        val np = _nowPlaying.value ?: return
        val (index, offset) = locate(sec, np.tracks)
        exo.seekTo(index, (offset * 1000).toLong())
    }

    /** Where we are in the BOOK (all tracks), in seconds. */
    fun positionSec(): Double? {
        val np = _nowPlaying.value ?: return null
        val index = exo.currentMediaItemIndex.coerceIn(0, (np.tracks.size - 1).coerceAtLeast(0))
        return np.tracks.take(index).sumOf { it.durationSec } + exo.currentPosition / 1000.0
    }

    fun chapterTitle(): String? {
        val np = _nowPlaying.value ?: return null
        val pos = positionSec() ?: return null
        return np.chapters.lastOrNull { it.startSec <= pos + 0.5 }?.title
    }

    /**
     * Reports the position (and listening time) now. True when the server took it;
     * false when it was only saved on the watch; null when nothing is loaded.
     */
    suspend fun reportNow(finished: Boolean = false): Boolean? {
        val np = _nowPlaying.value ?: return null
        val pos = if (finished) np.totalSec else positionSec() ?: return null
        accrue()
        val now = System.currentTimeMillis()
        k.store.savePosition(np.book.id, LocalPosition(pos, now, pending = true, finished = finished))
        k.updateShelfPosition(np.book.id, pos)

        val listened = listenedSec
        val report = Report(np.book.id, pos, np.totalSec, finished, !exo.isPlaying, listened.takeIf { it > 0 })
        val localSession = localSessionId
        val (saved, recorded) = withContext(Dispatchers.IO) {
            syncMutex.withLock {
                if (np.sessionId != null) {
                    when (k.api.syncSession(np.sessionId, report)) {
                        true -> true to true
                        // The session is gone (closed by the server after a long
                        // pause): the position still goes through without it.
                        false -> k.api.saveProgress(report) to false
                        null -> false to false
                    }
                } else {
                    val ok = k.api.saveProgress(report)
                    val rec = ok && listened > 0 && localSession != null &&
                        k.api.syncLocalSession(localSession, np.book, localStartedAt, localStartSec, report, localListenedTotal + listened)
                    ok to rec
                }
            }
        }
        if (recorded) {
            listenedSec -= listened
            if (np.sessionId == null) localListenedTotal += listened
        }
        if (saved) {
            k.store.position(np.book.id)?.takeIf { it.savedAt == now }
                ?.let { k.store.savePosition(np.book.id, it.copy(pending = false)) }
            _status.value = "Synced " + DateFormat.getTimeInstance(DateFormat.SHORT).format(Date())
        } else {
            _status.value = "Saved on watch"
            SyncWorker.enqueue(context)
        }
        return saved
    }

    /** Stops the book: a final report, then the session closes. */
    suspend fun stop() {
        if (_nowPlaying.value == null) return
        exo.pause()
        reportNow()
        _nowPlaying.value?.sessionId?.let { sid -> withContext(Dispatchers.IO) { runCatching { k.api.closeSession(sid) } } }
        exo.stop()
        exo.clearMediaItems()
        _nowPlaying.value = null
        _status.value = null
    }

    private fun accrue() {
        val since = playingSince ?: return
        val now = SystemClock.elapsedRealtime()
        listenedSec += (now - since) / 1000.0
        playingSince = if (exo.isPlaying) now else null
    }

    private inner class Events : Player.Listener {
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _isPlaying.value = isPlaying
            if (isPlaying) {
                playingSince = SystemClock.elapsedRealtime()
            } else {
                accrue()
                playingSince = null
                if (exo.playbackState != Player.STATE_ENDED) scope.launch { reportNow() }
            }
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) scope.launch { reportNow(finished = true) }
        }

        // A release build won't play through the watch speaker (see the builder):
        // say why nothing is happening, while Wear OS offers the Bluetooth picker.
        override fun onPlaybackSuppressionReasonChanged(reason: Int) {
            if (reason == Player.PLAYBACK_SUPPRESSION_REASON_UNSUITABLE_AUDIO_OUTPUT) {
                _status.value = "Connect headphones"
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            _status.value = "Playback error"
        }
    }

    companion object {
        const val SKIP_MS = 30_000L
        private const val SYNC_EVERY_MS = 30_000L

        /** A book position as (track index, seconds into that track). */
        fun locate(sec: Double, tracks: List<TrackFile>): Pair<Int, Double> {
            var remaining = sec
            tracks.forEachIndexed { i, t ->
                if (remaining < t.durationSec || i == tracks.lastIndex) return i to remaining.coerceAtLeast(0.0)
                remaining -= t.durationSec
            }
            return 0 to 0.0
        }
    }
}
