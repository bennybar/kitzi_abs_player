package com.bennybar.kitzi.wear

import android.content.Context
import android.net.Uri
import android.os.Looper
import android.os.SystemClock
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.TransferListener
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
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
import java.util.concurrent.atomic.AtomicLong

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

    /** Waiting on the network (streaming) while meant to be playing: a spinner, not the Play button. */
    private val _buffering = MutableStateFlow(false)
    val buffering: StateFlow<Boolean> = _buffering.asStateFlow()
    /** Whether it's meant to be playing (true while buffering too): what Play/Pause shows. */
    private val _wantsPlay = MutableStateFlow(false)
    val wantsPlay: StateFlow<Boolean> = _wantsPlay.asStateFlow()
    /** When the sleep timer pauses (elapsedRealtime), or -1 for the end of the chapter; null when off. */
    private val _sleepAt = MutableStateFlow<Long?>(null)
    val sleepAt: StateFlow<Long?> = _sleepAt.asStateFlow()
    private var sleepJob: Job? = null

    /** When playback last paused (elapsedRealtime), to skip the server check after a short pause. */
    private var pausedAt = 0L
    /** Set while [stop] tears the book down: its pause isn't a report of its own. */
    private var stopping = false
    /** Stall watchdog: how many times this stream has been rebuilt since it last played ("Reconnecting…"). */
    private val _recoveries = MutableStateFlow(0)
    val recoveries: StateFlow<Int> = _recoveries.asStateFlow()
    private var stallSince: Long? = null
    /** Bytes the streams have fetched, and what they had at the watchdog's last look. */
    private val bytesIn = AtomicLong()
    private var seenBytes = 0L
    /** A long jump is opening its new stream (see [jumpStream]). */
    private val _jumping = MutableStateFlow(false)
    val jumping: StateFlow<Boolean> = _jumping.asStateFlow()
    /** Where a jump is taking the book: its position until the new stream is in. */
    private var jumpTarget: Double? = null
    /** Counts the books started and stopped, so a jump still in flight knows the playback it began in has gone. */
    private var runs = 0
    /** Where the server had the book at the last start-position check (null: no answer). */
    private var serverStart: Double? = null
    /**
     * A streamed book to download once listening stops ("Auto-download"):
     * downloading it while streaming it fetched the book twice at once.
     */
    private var downloadWhenPaused: String? = null
    private var ticker: Job? = null
    /** Seconds of playing since the last periodic report. */
    private var sinceReport = 0

    /** Built on the main looper whoever touches it first (a worker may init Kitzi). */
    val exo: ExoPlayer by lazy {
        val http = OkHttpDataSource.Factory(k.api.client).setTransferListener(object : TransferListener {
            override fun onTransferInitializing(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onTransferStart(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onTransferEnd(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean) {}
            override fun onBytesTransferred(source: DataSource, dataSpec: DataSpec, isNetwork: Boolean, bytesTransferred: Int) {
                bytesIn.addAndGet(bytesTransferred.toLong())
            }
        })
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
            .also {
                it.addListener(Events())
                it.setPlaybackSpeed(k.store.speed)
            }
    }

    /**
     * Once a second while meant to be playing: a report every 30 s of playing, and
     * the stall watchdog. Paused, nothing moves, so it stops (and starts again on Play).
     */
    private fun startTicker() {
        ticker?.cancel()
        // A stall counted before a pause isn't one now.
        stallSince = null
        seenBytes = bytesIn.get()
        ticker = scope.launch {
            while (true) {
                delay(1_000)
                if (_isPlaying.value && ++sinceReport >= SYNC_EVERY_SEC) {
                    sinceReport = 0
                    scope.launch { reportNow() }
                }
                watchStream()
            }
        }
    }

    fun playingItemId(): String? = _nowPlaying.value?.book?.id?.takeIf { _isPlaying.value }

    /** Plays [book] from the newest known position. Null, or why it can't. */
    suspend fun play(book: Book): String? {
        // A second tap while the first is still starting: one session, not two.
        if (_loading.value) return null
        val current = _nowPlaying.value
        if (current?.book?.id == book.id && exo.mediaItemCount > 0 && exo.playerError == null) {
            resumeLoaded()
            return null
        }
        _loading.value = true
        try {
            runs++
            if (current != null) stop()
            val saved = k.downloads.downloaded(book.id)
            var start = startPosition(book, streaming = saved == null)
            val np = if (saved != null) {
                NowPlaying(saved.book.copy(currentTimeSec = book.currentTimeSec, lastUpdate = book.lastUpdate), saved.tracks, saved.chapters, true, null)
            } else {
                if (book.durationSec > 0 && start >= book.durationSec - 5) start = 0.0
                // The server prepares the stream where IT has the book. Starting
                // elsewhere (a newer place saved on the watch), it gets that first.
                if (serverNeedsStart(serverStart, start)) {
                    withContext(Dispatchers.IO) { k.api.saveProgress(Report(book.id, start, book.durationSec, false, true, null)) }
                }
                k.store.openStream?.let { left -> scope.launch(Dispatchers.IO) { k.api.closeSession(left) } }
                val session = withContext(Dispatchers.IO) { k.api.openSession(book.id, hls = true) }
                    ?: return "Can't reach the server. Download the book to listen offline."
                if (session.tracks.isEmpty()) return "This book has no playable audio."
                k.store.openStream = session.id
                NowPlaying(book, session.tracks, session.chapters, false, session.id)
            }
            if (start >= np.totalSec - 5) start = 0.0 // finished: from the top

            exo.setMediaItems(mediaItems(np), locate(start, np.tracks).first, (locate(start, np.tracks).second * 1000).toLong())
            exo.prepare()
            _nowPlaying.value = np
            k.store.lastBookId = book.id
            listenedSec = 0.0
            sinceReport = 0
            _recoveries.value = 0
            if (np.local) {
                localSessionId = UUID.randomUUID().toString()
                localStartedAt = k.api.nowMs()
                localStartSec = start
                localListenedTotal = 0.0
            } else {
                localSessionId = null
            }
            // Streamed over the watch's network: kept on the watch for next time, once listening stops.
            downloadWhenPaused = book.id.takeIf { !np.local && k.store.autoDownload && k.downloads.state(it) == DownloadState.None }
            exo.play()
            return null
        } finally {
            _loading.value = false
        }
    }

    private fun mediaItems(np: NowPlaying): List<MediaItem> {
        val cover: Uri? = k.downloads.coverFile(np.book.id)?.let { Uri.fromFile(it) }
        return np.tracks.map { t ->
            MediaItem.Builder()
                .setUri(t.url)
                .setMimeType(if (t.url.contains(".m3u8")) MimeTypes.APPLICATION_M3U8 else t.mimeType)
                .setMediaMetadata(
                    MediaMetadata.Builder().setTitle(np.book.title).setArtist(np.book.author).setArtworkUri(cover).build()
                )
                .build()
        }
    }

    /**
     * Where to start: the newest of the watch's saved position and the server's.
     * When the server doesn't answer in time, the shelf's position (and when it was
     * saved) counts instead, so an old watch position can't beat a newer one from
     * another device. Streaming needs the network anyway, so it waits longer.
     */
    private suspend fun startPosition(book: Book, streaming: Boolean): Double {
        val local = k.store.position(book.id)
        // A blocking request can't be cancelled, so the wait is on a detached call
        // (it may finish later, harmlessly). No network: skip.
        val server = if (!hasNetwork()) null else {
            val fetch = scope.async(Dispatchers.IO) { runCatching { k.api.progress(book.id) }.getOrNull() }
            withTimeoutOrNull(if (streaming) 15_000 else 5_000) { fetch.await() }
        }
        serverStart = server?.first
        val shelf = k.shelf.value.firstOrNull { it.id == book.id } ?: book
        return newestPosition(local?.let { it.sec to it.savedAt }, server, shelf.currentTimeSec to shelf.lastUpdate)
    }

    private fun hasNetwork(): Boolean {
        val cm = context.getSystemService(android.net.ConnectivityManager::class.java)
        return cm.getNetworkCapabilities(cm.activeNetwork)
            ?.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
    }

    /** Play/Pause. Meant to be playing (even while buffering): pause. */
    fun togglePlay() {
        if (exo.playWhenReady && exo.playbackState != Player.STATE_ENDED) pause()
        else if (_nowPlaying.value != null) scope.launch { resumeLoaded() }
    }

    fun pause() {
        exo.pause()
    }

    /** The streamed book's download starts once listening stops (see [downloadWhenPaused]). */
    private fun startPendingDownload() {
        val id = downloadWhenPaused ?: return
        downloadWhenPaused = null
        if (k.downloads.state(id) == DownloadState.None) k.downloads.start(id)
    }

    /**
     * Resumes the loaded book — from the server's position if that's newer (listened
     * on the phone during the pause), like a fresh start does. Media buttons and the
     * system controls come through here too (see PlaybackService). After a pause of
     * under a minute nothing else can have moved it: no server check.
     */
    suspend fun resumeLoaded() {
        val np = _nowPlaying.value ?: return
        if (_loading.value) return
        // Streamed until now, and downloaded since: plays on from the file (no
        // stream to keep open, nothing more to fetch).
        if (!np.local && !_jumping.value && k.downloads.state(np.book.id) == DownloadState.Done) {
            stop()
            play(np.book)
            return
        }
        // A long jump still opening its stream: Play carries on from it.
        while (_jumping.value) delay(50)
        val gaveUp = _status.value == LOST
        val shortPause = pausedAt > 0 && SystemClock.elapsedRealtime() - pausedAt < 60_000
        if (!shortPause) {
            _loading.value = true
            try {
                val target = startPosition(np.book, streaming = !np.local)
                val here = positionSec()
                if (_nowPlaying.value?.book?.id == np.book.id && here != null &&
                    kotlin.math.abs(target - here) > 3 && target < np.totalSec - 5
                ) {
                    if (isLongJump(np.tracks[locate(target, np.tracks).first].url, here, target)) {
                        _loading.value = false
                        jumpStream(target, play = true, run = runs)
                        return
                    }
                    seekTo(target)
                }
            } finally {
                _loading.value = false
            }
        }
        if (_nowPlaying.value?.book?.id != np.book.id) return
        if (exo.playbackState == Player.STATE_ENDED) seekTo(0.0)
        if (gaveUp || exo.playbackState == Player.STATE_IDLE || exo.playerError != null) {
            // After an error, or a stream the watchdog gave up on: rebuild it where it was.
            positionSec()?.let { rebuild(it) }
        }
        _recoveries.value = 0
        exo.play()
    }

    fun skip(deltaSec: Double) {
        val pos = positionSec() ?: return
        seekTo((pos + deltaSec).coerceIn(0.0, (_nowPlaying.value?.totalSec ?: 0.0)))
    }

    /**
     * Seeks within the book. While paused, the new place is saved as the newest
     * position, so Play carries on from there (not back to where it was paused).
     */
    fun seekTo(sec: Double) {
        val np = _nowPlaying.value ?: return
        val (index, offset) = locate(sec, np.tracks)
        if (isLongJump(np.tracks[index].url, positionSec() ?: sec, sec)) {
            if (_loading.value || _jumping.value) return
            val wasPlaying = exo.playWhenReady
            // Tied to this run of the book here and now: started later, it could
            // attach itself to the next one. The book is at the target from now on.
            val run = runs
            _jumping.value = true
            jumpTarget = sec
            if (!wasPlaying) {
                k.store.savePosition(np.book.id, LocalPosition(sec, k.api.nowMs(), pending = true, finished = false))
                k.updateShelfPosition(np.book.id, sec)
            }
            scope.launch { jumpStream(sec, wasPlaying, run) }
            return
        }
        exo.seekTo(index, (offset * 1000).toLong())
        if (!exo.playWhenReady) {
            k.store.savePosition(np.book.id, LocalPosition(sec, k.api.nowMs(), pending = true, finished = false))
            k.updateShelfPosition(np.book.id, sec)
        }
    }

    /**
     * A long jump in an HLS stream. The server only has the segments around where
     * its stream started: asked for others it answers "not found" while it
     * restarts, and the player skips ahead past them. So the server is told the
     * new place and a new stream opens there, which starts exact, as a first start does.
     */
    private suspend fun jumpStream(target: Double, play: Boolean, run: Int) {
        try {
            val np = _nowPlaying.value
            if (run != runs || np == null) return
            _jumping.value = true
            jumpTarget = target
            stopping = true // its pause isn't a report of its own
            exo.pause()
            reportNow() // the listening so far, and the new place
            stopping = false
            val s = withContext(Dispatchers.IO) { runCatching { k.api.openSession(np.book.id, hls = true) }.getOrNull() }
            if (run != runs || _nowPlaying.value?.book?.id != np.book.id) {
                // Closed (or another book) meanwhile: the new stream isn't needed.
                s?.let { orphan -> scope.launch(Dispatchers.IO) { k.api.closeSession(orphan.id) } }
                return
            }
            if (s != null && s.tracks.isNotEmpty()) {
                // The one in use now: the report above may have replaced a session the server had closed.
                _nowPlaying.value?.sessionId?.let { old -> scope.launch(Dispatchers.IO) { k.api.closeSession(old) } }
                _nowPlaying.value = _nowPlaying.value?.copy(sessionId = s.id, tracks = s.tracks)
                k.store.openStream = s.id
            }
            val now = _nowPlaying.value ?: return
            val (index, offset) = locate(target, now.tracks)
            exo.setMediaItems(mediaItems(now), index, (offset * 1000).toLong())
            exo.prepare()
            if (play) exo.play()
        } finally {
            // A jump from an earlier run was cleared by stop(): one in the new run may be under way.
            if (run == runs) {
                jumpTarget = null
                _jumping.value = false
            }
        }
    }

    /** Where we are in the BOOK (all tracks), in seconds. */
    fun positionSec(): Double? {
        val np = _nowPlaying.value ?: return null
        jumpTarget?.let { return it }
        val index = exo.currentMediaItemIndex.coerceIn(0, (np.tracks.size - 1).coerceAtLeast(0))
        return np.tracks.take(index).sumOf { it.durationSec } + exo.currentPosition / 1000.0
    }

    /** The chapter we're in: (index, start, end). */
    fun chapterBounds(): Triple<Int, Double, Double>? {
        val np = _nowPlaying.value ?: return null
        val pos = positionSec() ?: return null
        val i = np.chapters.indexOfLast { it.startSec <= pos + 0.5 }.takeIf { it >= 0 } ?: return null
        val end = np.chapters.getOrNull(i + 1)?.startSec ?: np.totalSec
        return Triple(i, np.chapters[i].startSec, end)
    }

    fun chapterTitle(): String? {
        val np = _nowPlaying.value ?: return null
        return chapterBounds()?.let { np.chapters[it.first].title }
    }

    fun setSpeed(speed: Float) {
        k.store.speed = speed
        exo.setPlaybackSpeed(speed)
    }

    /**
     * Pauses after [minutes]; 0 cancels; -1 at the end of this chapter. It sleeps
     * until then (near the chapter's end: at most a minute at a time, as a seek or a
     * speed change moves it, then close checks) instead of polling.
     */
    fun sleep(minutes: Int) {
        val chapterEnd = if (minutes < 0) chapterBounds()?.third ?: return else null
        sleepJob?.cancel()
        _sleepAt.value = when {
            minutes == 0 -> null
            minutes < 0 -> -1L
            else -> SystemClock.elapsedRealtime() + minutes * 60_000L
        }
        val at = _sleepAt.value ?: return
        sleepJob = scope.launch {
            while (true) {
                val wait = if (chapterEnd != null) {
                    val left = (chapterEnd - (positionSec() ?: 0.0)) / exo.playbackParameters.speed.coerceAtLeast(0.5f)
                    if (left <= 0.5) break
                    if (left > 3) ((left - 2).coerceAtMost(60.0) * 1000).toLong() else 500L
                } else {
                    (at - SystemClock.elapsedRealtime()).takeIf { it > 0 } ?: break
                }
                delay(wait)
            }
            _sleepAt.value = null
            if (exo.playWhenReady) pause()
        }
    }

    /** Bookmarks the current place on the server. True when it was saved. */
    suspend fun addBookmark(): Boolean {
        val np = _nowPlaying.value ?: return false
        val pos = positionSec() ?: return false
        val title = chapterTitle() ?: "Bookmark"
        return withContext(Dispatchers.IO) { k.api.addBookmark(np.book.id, pos, title) }
    }

    /**
     * The stall watchdog: a stream waiting for data with none arriving is rebuilt at
     * its place after 15, then 30, then 60 s; after a minute more it pauses and says
     * so (ExoPlayer's own retries can wait on a dead connection for minutes).
     */
    private fun watchStream() {
        val np = _nowPlaying.value
        val waiting = np != null && !np.local && exo.playWhenReady && exo.playbackState == Player.STATE_BUFFERING &&
            !_loading.value && !_jumping.value
        if (!waiting) { stallSince = null; return }
        // Still loading (bytes are arriving): slow isn't stuck. Rebuilding now would
        // throw away what's been fetched and start it again.
        val bytes = bytesIn.get()
        if (bytes > seenBytes) { seenBytes = bytes; stallSince = null; return }
        val now = SystemClock.elapsedRealtime()
        val since = stallSince ?: now.also { stallSince = it }
        val limit = STALL_LIMITS_SEC.getOrNull(_recoveries.value)
        if (now - since < (limit ?: 60) * 1000L) return
        stallSince = null
        if (limit == null) {
            pause()
            _status.value = LOST
            return
        }
        _recoveries.value++
        positionSec()?.let { rebuild(it) }
        exo.play()
    }

    /** The same stream again at [sec]: new connections, same session. */
    private fun rebuild(sec: Double) {
        val np = _nowPlaying.value ?: return
        val (index, offset) = locate(sec, np.tracks)
        exo.setMediaItems(mediaItems(np), index, (offset * 1000).toLong())
        exo.prepare()
    }

    /**
     * Reports the position (and listening time) now. True when the server took it;
     * false when it was only saved on the watch; null when nothing is loaded.
     */
    suspend fun reportNow(finished: Boolean = false): Boolean? {
        val np = _nowPlaying.value ?: return null
        val pos = if (finished) np.totalSec else positionSec() ?: return null
        accrue()
        val now = k.api.nowMs()
        k.store.savePosition(np.book.id, LocalPosition(pos, now, pending = true, finished = finished))
        // While playing, the shelf is only updated in memory (it's written to disk
        // when listening stops, not with every report).
        k.updateShelfPosition(np.book.id, pos, persist = !_isPlaying.value || finished)

        val listened = listenedSec
        val report = Report(np.book.id, pos, np.totalSec, finished, !exo.isPlaying, listened.takeIf { it > 0 })
        val localSession = localSessionId
        var reopen = false
        val (saved, recorded) = withContext(Dispatchers.IO) {
            syncMutex.withLock {
                if (np.sessionId != null) {
                    when (k.api.syncSession(np.sessionId, report)) {
                        true -> true to true
                        // The session is gone (closed by the server after a long
                        // pause): the position goes through without it, and a new
                        // session takes the listening time from now on. Only for the
                        // session still in use: one replaced meanwhile (a long jump)
                        // answers "gone" too, and its replacement mustn't get another.
                        false -> {
                            reopen = !finished && _nowPlaying.value?.sessionId == np.sessionId
                            k.api.saveProgress(report) to false
                        }
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
        if (reopen) {
            val fresh = withContext(Dispatchers.IO) { runCatching { k.api.openSession(np.book.id, hls = true) }.getOrNull() }
            val current = _nowPlaying.value
            if (fresh != null && current?.book?.id == np.book.id && current.sessionId == np.sessionId) {
                // Same tracks: its URLs replace the old ones, which belonged to the closed session.
                val swap = fresh.tracks.size == current.tracks.size
                val pos = positionSec()
                _nowPlaying.value = current.copy(sessionId = fresh.id, tracks = if (swap) fresh.tracks else current.tracks)
                k.store.openStream = fresh.id
                // The player still has the closed session's URLs (a jump loads its own stream).
                if (swap && !_jumping.value) pos?.let { rebuild(it) }
            } else if (fresh != null) {
                scope.launch(Dispatchers.IO) { k.api.closeSession(fresh.id) }
            }
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

    /**
     * Stops the book: a final report (unless it was just sent), then the session
     * closes in the background (a slow network mustn't hold up the next book).
     */
    suspend fun stop(report: Boolean = true) {
        if (_nowPlaying.value == null) return
        runs++
        stopping = true
        try {
            exo.pause()
            if (report) reportNow()
            // (Store.openStream stays until the close gets through: one that didn't
            // is sent again at the next play.)
            _nowPlaying.value?.sessionId?.let { sid ->
                scope.launch(Dispatchers.IO) {
                    if (runCatching { k.api.closeSession(sid) }.getOrDefault(false) && k.store.openStream == sid) k.store.openStream = null
                }
            }
            exo.stop()
            exo.clearMediaItems()
            // A jump still opening its stream belongs to this book: it ends here (see jumpStream).
            jumpTarget = null
            _jumping.value = false
            startPendingDownload()
            sleepJob?.cancel()
            _nowPlaying.value = null
            _status.value = null
            _sleepAt.value = null
            PlayerTile.refresh(context)
        } finally {
            stopping = false
        }
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
                _recoveries.value = 0
                if (_status.value == LOST) _status.value = null
            } else {
                accrue()
                playingSince = null
                // Only a real pause is reported: buffering (still meant to play) isn't,
                // nor the pause inside stop(), which reports for itself.
                if (!exo.playWhenReady && !stopping && exo.playbackState != Player.STATE_ENDED) {
                    pausedAt = SystemClock.elapsedRealtime()
                    scope.launch { reportNow() }
                }
            }
        }

        override fun onPlayWhenReadyChanged(playWhenReady: Boolean, reason: Int) {
            _wantsPlay.value = playWhenReady
            if (playWhenReady) startTicker() else ticker?.cancel()
            // Listening stopped (not a jump's or stop()'s pause on the way): the
            // streamed book's download can start.
            if (!playWhenReady && !stopping) startPendingDownload()
            PlayerTile.refresh(context)
            _buffering.value = playWhenReady && exo.playbackState == Player.STATE_BUFFERING
        }

        override fun onPlaybackStateChanged(state: Int) {
            _buffering.value = exo.playWhenReady && state == Player.STATE_BUFFERING
            if (state != Player.STATE_ENDED) return
            scope.launch {
                val np = _nowPlaying.value ?: return@launch
                reportNow(finished = true)
                k.removeFromShelf(np.book.id)
                // Done with it: the session closes, and a downloaded book's files go.
                stop(report = false)
                if (np.local) k.downloads.delete(np.book.id)
            }
        }

        // A release build won't play through the watch speaker (see the builder):
        // say why nothing is happening, while Wear OS offers the Bluetooth picker.
        override fun onPlaybackSuppressionReasonChanged(reason: Int) {
            if (reason == Player.PLAYBACK_SUPPRESSION_REASON_UNSUITABLE_AUDIO_OUTPUT) {
                _status.value = "Connect headphones"
            }
        }

        override fun onPlayerError(error: PlaybackException) {
            val np = _nowPlaying.value
            // A streamed book that lost its connection: try again at its place, as
            // the watchdog would; past the last try, pause and say so.
            if (np != null && !np.local && _recoveries.value < STALL_LIMITS_SEC.size - 1) {
                _recoveries.value++
                val pos = positionSec() ?: 0.0
                scope.launch {
                    delay(3_000)
                    if (_nowPlaying.value?.book?.id == np.book.id) { rebuild(pos); exo.play() }
                }
            } else {
                _status.value = if (np?.local == false) LOST else "Playback error"
            }
        }
    }

    companion object {
        const val SKIP_MS = 30_000L
        private const val SYNC_EVERY_SEC = 30
        private val STALL_LIMITS_SEC = listOf(15, 30, 60)
        const val LOST = "Lost the connection. Tap Play to try again."

        /**
         * A long jump in an HLS stream (over 45 s) goes through a new stream at the
         * target (see jumpStream); a short one seeks in place.
         */
        fun isLongJump(url: String, from: Double, to: Double): Boolean =
            url.contains(".m3u8") && kotlin.math.abs(to - from) > 45

        /** The server gets the start position first when it has another (over 5 s away) or didn't answer. */
        fun serverNeedsStart(server: Double?, start: Double): Boolean =
            server == null || kotlin.math.abs(server - start) > 5

        /**
         * The newest of the watch's (sec, savedAt) and the server's. When the server
         * didn't answer, the shelf's position counts instead (if it has a time), so
         * an old watch position can't beat a newer one from another device.
         */
        fun newestPosition(local: Pair<Double, Long>?, server: Pair<Double, Long>?, shelf: Pair<Double, Long>): Double {
            val found = listOfNotNull(local, server ?: shelf.takeIf { it.second > 0 })
            return found.maxByOrNull { it.second }?.first ?: shelf.first
        }

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
