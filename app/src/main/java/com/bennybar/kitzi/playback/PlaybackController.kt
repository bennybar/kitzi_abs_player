package com.bennybar.kitzi.playback

import android.content.Context
import android.net.Uri
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import com.bennybar.kitzi.data.BooksRepository
import com.bennybar.kitzi.data.legacy.DownloadPaths
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import com.bennybar.kitzi.data.net.PlaybackApi
import com.bennybar.kitzi.data.net.ProgressReport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File

data class NowPlaying(
    val itemId: String,
    val title: String,
    val author: String?,
    val coverUrl: String?,
    val tracks: List<Track>,
    val chapters: List<Chapter>,
    val serverDurationSec: Double?,
    val isLocal: Boolean,
)

/**
 * Owns the player and all book-coordinate state. One instance, shared by the UI
 * and the media service, so the notification and the app can never disagree.
 */
@androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
class PlaybackController(
    private val context: Context,
    private val api: PlaybackApi,
    private val books: BooksRepository,
    private val prefs: FlutterPrefs,
    private val downloads: DownloadPaths,
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private val accrual = ListeningAccrual()

    lateinit var player: ExoPlayer
        private set

    private val _nowPlaying = MutableStateFlow<NowPlaying?>(null)
    val nowPlaying: StateFlow<NowPlaying?> = _nowPlaying.asStateFlow()

    private var sessionId: String? = null
    private var lastSyncedSec: Double = -1.0
    private var syncJob: kotlinx.coroutines.Job? = null
    // A book that was loaded paused (the auto-loaded last book on startup) hasn't
    // opened a live streaming session for THIS play; its first play reloads from
    // scratch so it can't get stuck on a failed startup prepare or a stale session,
    // and so sync-before-play runs at play time rather than at load time.
    private var needsFreshLoad = false

    // Serialises book loads: two quick taps must not each open a server session
    // and race to assign sessionId (leaking the loser). The generation counter
    // lets a load that was superseded while queued bail out instead of loading a
    // book the user has already moved past.
    private val loadMutex = kotlinx.coroutines.sync.Mutex()
    private var loadGeneration = 0

    // Serialises progress reports and session close so they can't reorder or
    // overtake one another — a "close" must not land before the final "sync", and
    // two syncs must reach the server in the order they were taken.
    private val syncMutex = kotlinx.coroutines.sync.Mutex()

    // Completed once PlaybackService.onCreate has attached the ExoPlayer. A very
    // fast Resume/Play tap can arrive before the service connection finishes; a
    // load waits on this rather than touching an uninitialised `player`.
    private val playerReady = kotlinx.coroutines.CompletableDeferred<Unit>()

    /** Fired when a book plays to its end: drives the queue and delete-on-finish. */
    var onBookFinished: ((String) -> Unit)? = null

    /** Fired when playback pauses; used to honour "pause cancels sleep timer". */
    var onPaused: (() -> Unit)? = null

    /**
     * Answers "is this book FULLY downloaded?" — wired in by Services (the
     * downloads repository isn't a direct dependency). Local playback must only
     * engage for complete downloads: a partial one (say 1 of 28 files) would
     * otherwise play as if it were the whole book.
     */
    var isDownloadComplete: (suspend (String) -> Boolean)? = null

    /** Per-track durations captured at download time (trackIndex -> seconds). */
    var localTrackDurations: (suspend (String) -> Map<Int, Double>)? = null

    /** When a pause happened, so smart-rewind can size the rewind by how long. */
    private var pausedAtMs: Long? = null

    fun attach(player: ExoPlayer) {
        this.player = player
        player.addListener(PlayerEvents())
        player.setPlaybackParameters(PlaybackParameters(savedSpeed()))
        playerReady.complete(Unit)
    }

    // ---- book coordinates --------------------------------------------------

    private fun tracks(): List<Track> = _nowPlaying.value?.tracks.orEmpty()

    /** Where we are in the BOOK, or null when it cannot be known (see PlaybackMath). */
    fun globalPositionSec(): Double? {
        if (!::player.isInitialized) return null
        val np = _nowPlaying.value ?: return null
        return PlaybackMath.computeGlobal(
            player.currentMediaItemIndex,
            player.currentPosition / 1000.0,
            np.tracks,
        )
    }

    fun totalDurationSec(): Double? {
        val np = _nowPlaying.value ?: return null
        return PlaybackMath.totalDuration(np.tracks, np.serverDurationSec)
    }

    fun currentChapter(): ChapterMetrics? {
        val pos = globalPositionSec() ?: return null
        val np = _nowPlaying.value ?: return null
        return PlaybackMath.currentChapter(pos, np.chapters, totalDurationSec())
    }

    /**
     * The only seek that matters. With the whole book as one ExoPlayer playlist
     * this is a single atomic call — no source reload, no sleep, no play-state
     * juggling.
     */
    fun seekGlobal(globalSec: Double, reportNow: Boolean = true) {
        val np = _nowPlaying.value ?: return
        val total = totalDurationSec() ?: Double.MAX_VALUE
        val target = globalSec.coerceIn(0.0, total)
        val tp = PlaybackMath.mapGlobalToTrack(target, np.tracks)

        player.seekTo(tp.trackIndex, (tp.offsetSec * 1000).toLong())
        if (reportNow) syncNow()
    }

    fun nudge(seconds: Double) {
        val pos = globalPositionSec() ?: return
        seekGlobal(pos + seconds)
    }

    fun seekForward() = nudge(prefs.getInt(KEY_SEEK_FORWARD, 30).toDouble())
    fun seekBackward() = nudge(-prefs.getInt(KEY_SEEK_BACKWARD, 30).toDouble())

    /**
     * "Smart rewind": on resuming after a pause, step back by an amount sized to
     * how long the pause was, so you re-hear a little context. Consumed once.
     */
    private fun applySmartRewindIfDue() {
        val pausedAt = pausedAtMs ?: return
        pausedAtMs = null
        if (!prefs.getBoolean(KEY_SMART_REWIND, false)) return

        val elapsedSec = (android.os.SystemClock.elapsedRealtime() - pausedAt) / 1000.0
        val rewind = when {
            elapsedSec < 10 -> 3.0
            elapsedSec <= 30 -> 5.0
            elapsedSec >= 120 -> 30.0
            else -> 0.0
        }
        if (rewind > 0) nudge(-rewind)
    }

    /**
     * Chapter skip. REWRITE.md is explicit: skipToNext/Previous must move by
     * CHAPTER — mapping them to a 30s nudge means a driver cannot change chapter.
     * Falls back to track skip only when the book genuinely has no chapters.
     */
    fun nextChapter() {
        val pos = globalPositionSec()
        val np = _nowPlaying.value
        val next = if (pos != null && np != null) {
            PlaybackMath.nextChapterStart(pos, np.chapters, totalDurationSec())
        } else null

        if (next != null) seekGlobal(next) else if (player.hasNextMediaItem()) player.seekToNextMediaItem()
    }

    fun previousChapter() {
        val pos = globalPositionSec()
        val np = _nowPlaying.value
        val prev = if (pos != null && np != null) {
            PlaybackMath.previousChapterStart(pos, np.chapters, totalDurationSec())
        } else null

        if (prev != null) seekGlobal(prev) else if (player.hasPreviousMediaItem()) player.seekToPreviousMediaItem()
    }

    fun setSpeed(speed: Double) {
        // Free 0.05 steps across the allowed range (driven by the speed slider),
        // rather than snapping to a fixed preset set.
        val v = kotlin.math.round(speed.coerceIn(MIN_SPEED, MAX_SPEED) * 20) / 20.0
        player.setPlaybackParameters(PlaybackParameters(v.toFloat()))
        prefs.putDouble(KEY_SPEED, v)
    }

    private fun savedSpeed(): Float =
        prefs.getDouble(KEY_SPEED, 1.0).coerceIn(MIN_SPEED, MAX_SPEED).toFloat()

    // ---- loading -----------------------------------------------------------

    /**
     * Starts a book.
     *
     * Downloaded books are resolved entirely from disk and never touch the
     * network — no session open, no metadata fetch, no connectivity preflight.
     * A server round-trip here is what made tapping a downloaded book while
     * offline fail with "No Internet Connection".
     */
    /**
     * The play/pause toggle behind the mini-player and full-player buttons.
     *
     * Resuming isn't always a plain play(): an auto-loaded book (loaded paused on
     * startup) hasn't opened a streaming session for this play, and a book can be
     * left in an error/idle state if its prepare failed or a streaming session went
     * stale during a long pause — in those cases play() is a silent no-op. So when
     * the player isn't in a ready-to-resume state we reload the book from scratch
     * (fresh session + sync-before-play); otherwise we just resume.
     */
    fun playPause() {
        if (!::player.isInitialized) return
        if (player.isPlaying) player.pause() else resume()
    }

    /**
     * Resume playback, reloading the book from scratch when the player isn't in a
     * ready-to-resume state (an auto-loaded book with no session for this play, an
     * error, or an idle player) so play is never a silent no-op. Shared by the
     * in-app buttons (via playPause) and the media session's play command (via
     * BookCoordinatePlayer) so notification / lock-screen / Android Auto / Bluetooth
     * all recover too.
     */
    fun resume() {
        if (!::player.isInitialized) return
        val itemId = _nowPlaying.value?.itemId ?: return
        val notResumable = needsFreshLoad ||
            player.playerError != null ||
            player.playbackState == Player.STATE_IDLE ||
            player.mediaItemCount == 0
        if (notResumable) {
            needsFreshLoad = false
            scope.launch { runCatching { playItem(itemId, startPlaying = true) } }
        } else {
            player.play()
        }
    }

    /**
     * Loads (and optionally starts) a book. Returns false when the book could not be
     * loaded — a streaming session the server refused, or a load superseded by a
     * newer tap. Callers that navigate on the user's behalf must check this: opening
     * the player after a failed load strands the user on whatever was loaded before,
     * which since the last book auto-loads at startup is a different book entirely.
     */
    suspend fun playItem(itemId: String, startPlaying: Boolean = true): Boolean {
        // Don't touch `player` until the service has attached it.
        playerReady.await()
        val myGen = ++loadGeneration
        loadMutex.withLock {
            // A newer tap arrived while this one waited for the lock — abandon it
            // rather than load a book the user already moved past.
            if (myGen != loadGeneration) return false
            // Flush the OUTGOING book first: loadAndStart resets the accrual and the
            // last-sync marker, so without this the final position and up to a whole
            // sync interval of listening time are silently discarded on every switch.
            // Awaited so it lands before the session it belongs to is closed.
            // Bounded: the local position is already persisted synchronously inside
            // the payload build, so this wait only buys the server report landing
            // before the session closes. Offline it must not stall the switch.
            if (_nowPlaying.value != null) {
                runCatching { withTimeoutOrNull(3_000) { syncNowAwaiting() } }
            }
            // Close the previous streamed session before switching books so the
            // server stops transcoding for the book we're leaving. Ordered against
            // in-flight progress reports so a stale sync can't reopen it.
            sessionId?.let { id ->
                sessionId = null
                withContext(Dispatchers.IO) { syncMutex.withLock { runCatching { api.closeSession(id) } } }
            }
            return loadAndStart(itemId, startPlaying)
        }
    }

    /** Returns false when the book could not be loaded (no session, nothing to play). */
    private suspend fun loadAndStart(itemId: String, startPlaying: Boolean): Boolean {
        val durations = localTrackDurations?.invoke(itemId).orEmpty()
        val local = localTracks(itemId, durations)
            .takeIf { it.isNotEmpty() && isDownloadComplete?.invoke(itemId) != false }
            .orEmpty()
        val cached = books.getBook(itemId)

        val np: NowPlaying = if (local.isNotEmpty()) {
            NowPlaying(
                itemId = itemId,
                title = cached?.title ?: "",
                author = cached?.author,
                coverUrl = cached?.coverUrl,
                tracks = local,
                // A DOWNLOADED book must start without touching the network: use the
                // cached chapters, else per-track boundaries immediately. The real
                // list is fetched in the background afterwards (see below) — awaiting
                // it here made offline playback hang on a network timeout.
                chapters = loadCachedChapters(itemId)
                    .ifEmpty { PlaybackMath.chaptersFromTracks(local) },
                serverDurationSec = cached?.durationMs?.let { it / 1000.0 },
                isLocal = true,
            )
        } else {
            val session = withContext(Dispatchers.IO) { api.openSession(itemId) } ?: return false
            sessionId = session.sessionId
            cacheChapters(itemId, session.chapters)
            NowPlaying(
                itemId = itemId,
                title = cached?.title ?: "",
                author = cached?.author,
                coverUrl = cached?.coverUrl,
                tracks = session.tracks,
                chapters = session.chapters.ifEmpty { PlaybackMath.chaptersFromTracks(session.tracks) },
                serverDurationSec = session.durationSec ?: cached?.durationMs?.let { it / 1000.0 },
                isLocal = false,
            )
        }

        _nowPlaying.value = np
        // Remembered so the player can offer "Resume last book" on a cold start.
        prefs.putString(KEY_LAST_ITEM, itemId)
        accrual.reset()
        lastSyncedSec = -1.0

        // "Sync progress before play": pull the latest server progress first so
        // resuming picks up where another device left off. Streamed books only —
        // a downloaded book must start instantly and never wait on the network.
        if (!np.isLocal) maybeSyncBeforePlay()
        val resumeSec = resumePosition(itemId)
        val tp = PlaybackMath.mapGlobalToTrack(resumeSec, np.tracks)

        player.setMediaItems(np.tracks.map { it.toMediaItem(np) }, tp.trackIndex, (tp.offsetSec * 1000).toLong())
        player.prepare()
        if (startPlaying) player.play()
        // Loaded-but-not-playing (auto-load) → the first play reloads it fresh.
        needsFreshLoad = !startPlaying

        // A downloaded book with no cached chapters is playing on track-derived
        // boundaries right now; fetch the real list off the critical path and swap it
        // in if it arrives. Offline this simply fails and the fallback stands.
        if (np.isLocal && loadCachedChapters(itemId).isEmpty()) {
            scope.launch {
                val real = withContext(Dispatchers.IO) {
                    runCatching { books.chapters(itemId) }.getOrDefault(emptyList())
                }
                if (real.isNotEmpty()) {
                    cacheChapters(itemId, real)
                    _nowPlaying.value?.takeIf { it.itemId == itemId }?.let {
                        _nowPlaying.value = it.copy(chapters = real)
                    }
                }
            }
        }
        // The progress-sync loop is started/stopped by onIsPlayingChanged, not here,
        // so a loaded-but-paused book (e.g. the auto-loaded last book on launch)
        // doesn't wake every 26s doing nothing.
        return true
    }

    private fun Track.toMediaItem(np: NowPlaying): MediaItem = MediaItem.Builder()
        .setUri(if (isLocal) Uri.fromFile(File(url)) else Uri.parse(url))
        .setMediaId("${np.itemId}#$index")
        .setMimeType(mimeType)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(np.title)
                .setArtist(np.author)
                .setArtworkUri(np.coverUrl?.let(Uri::parse))
                // Tag the real playback items (not just browse items) as audiobooks so
                // System UI — notably Samsung's Now Bar — classifies the session as a
                // book rather than a generic track.
                .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
                .setIsPlayable(true)
                .build()
        )
        .build()

    /**
     * Downloaded files for a book, in the layout the Flutter app wrote them:
     * ordered by filename (track_000, track_001, ...), which is why the download
     * side must keep zero-padding the index.
     */
    private fun localTracks(itemId: String, durations: Map<Int, Double>): List<Track> {
        val dir = downloads.itemDir(itemId)
        if (!dir.isDirectory) return emptyList()

        return dir.listFiles().orEmpty()
            .filter { it.isFile && it.length() > 0 && !it.name.endsWith(".part") }
            .sortedBy { it.name }
            .mapIndexed { i, f ->
                // `track_007.m4a` -> 7 (the download DB's track index), used to seed
                // the duration captured at download time. Without this seed a
                // multi-track book's total is understated until every track hydrates,
                // and progress can be reported as ~100% while still in track 1.
                val fileIdx = f.nameWithoutExtension.substringAfterLast('_').toIntOrNull()
                Track(
                    index = i,
                    url = f.absolutePath,
                    mimeType = mimeFor(f.extension),
                    durationSec = fileIdx?.let { durations[it] },
                    isLocal = true,
                )
            }
    }

    private fun mimeFor(ext: String) = when (ext.lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a", "m4b", "aac", "mp4" -> "audio/mp4"
        "flac" -> "audio/flac"
        "ogg", "oga" -> "audio/ogg"
        "opus" -> "audio/opus"
        else -> "audio/mpeg"
    }

    // ---- progress ----------------------------------------------------------

    private fun startSyncLoop() {
        syncJob?.cancel()
        syncJob = scope.launch {
            while (true) {
                delay(PING_MS)
                if (player.isPlaying) syncNow()
            }
        }
    }

    /**
     * Reports progress. Persists locally FIRST so an offline session still keeps
     * the user's place, then tries the network.
     */
    fun syncNow(finished: Boolean = false) {
        val payload = buildSyncPayload(finished) ?: return
        scope.launch(Dispatchers.IO) { performSync(payload) }
    }

    /**
     * Like [syncNow] but waits for the report to be sent. Used before tearing a book
     * down (book switch), where fire-and-forget would race the session close and the
     * accrual reset and lose the final position / listened interval.
     */
    private suspend fun syncNowAwaiting(finished: Boolean = false) {
        val payload = buildSyncPayload(finished) ?: return
        withContext(Dispatchers.IO) { performSync(payload) }
    }

    /** Everything that must be read on the caller's thread, at call time. */
    private fun buildSyncPayload(finished: Boolean): SyncPayload? {
        val np = _nowPlaying.value ?: return null
        val pos = globalPositionSec()

        // Unknown book position: reporting the track-local value would overwrite
        // the server's correct progress with a much smaller number. Say nothing —
        // except when the book just FINISHED, where "the end" must still be sent
        // even if an earlier track's duration was never hydrated.
        val current = pos ?: when {
            finished -> totalDurationSec() ?: (player.currentPosition / 1000.0)
            player.currentMediaItemIndex == 0 -> player.currentPosition / 1000.0
            else -> return null
        }

        prefs.putDouble(progressKey(np.itemId), current)
        // Stamp WHEN this local position was saved, so resume can tell a fresh
        // offline position from a stale server one (see resumePosition).
        prefs.putDouble(progressTsKey(np.itemId), System.currentTimeMillis().toDouble())

        // The session id and item id are captured HERE, on the caller's thread —
        // reading `sessionId` inside the coroutine could pick up a value changed by a
        // later load/stop and report against the wrong (or a closed) session.
        return SyncPayload(
            itemId = np.itemId,
            sessionId = sessionId,
            current = current,
            total = totalDurationSec(),
            finished = finished,
            paused = !player.isPlaying,
        )
    }

    /**
     * The listened interval is snapshotted INSIDE the mutex, together with the send
     * and the consume. Snapshotting outside let two overlapping syncs capture the
     * same pending interval and report it twice — inflating listening stats — since
     * snapshot() only reads the pending total, it doesn't reserve it.
     */
    private suspend fun performSync(p: SyncPayload) {
        syncMutex.withLock {
            val listened = accrual.snapshot()
            val ok = api.sync(
                p.sessionId,
                ProgressReport(p.itemId, p.current, p.total, p.finished, p.paused, listened),
            )
            // Only on success — otherwise the time rolls into the next attempt.
            if (ok && listened != null) {
                accrual.consume(listened)
                // Record the confirmed listened interval for local stats.
                com.bennybar.kitzi.data.PlayHistoryStore.record(p.itemId, listened)
            }
            if (ok) lastSyncedSec = p.current
        }
    }

    private data class SyncPayload(
        val itemId: String,
        val sessionId: String?,
        val current: Double,
        val total: Double?,
        val finished: Boolean,
        val paused: Boolean,
    )

    /** Closes a server session, ordered behind any in-flight progress report. */
    private fun closeSessionOrdered(sid: String) {
        scope.launch(Dispatchers.IO) { syncMutex.withLock { runCatching { api.closeSession(sid) } } }
    }

    /**
     * Picks the resume position. Server and local can each be the newer one: the
     * server wins after listening on another device, but LOCAL wins after offline
     * listening (the server row is then stale). Comparing WHEN each was written —
     * local timestamp vs the server's lastUpdate — stops a stale server position
     * from yanking the user backward over progress they made offline. If we only
     * pre-play-sync'd the server just now (see [maybeSyncBeforePlay]) its row is
     * authoritative; otherwise the freshest write wins.
     */
    private suspend fun resumePosition(itemId: String): Double {
        val local = prefs.getDouble(progressKey(itemId), 0.0)
        val localTs = prefs.getDouble(progressTsKey(itemId), 0.0).toLong()
        val serverEntity = books.progressFor(itemId)
        val server = serverEntity?.currentTimeSec ?: 0.0
        val serverTs = serverEntity?.lastUpdate ?: 0L

        return when {
            local <= 0.0 -> server
            server <= 0.0 -> local
            localTs >= serverTs -> local
            else -> server
        }
    }

    private fun progressKey(itemId: String) = "abs_progress:$itemId"
    private fun progressTsKey(itemId: String) = "abs_progress_ts:$itemId"

    /** Refreshes server-side progress into the local DB before resuming a book. */
    private suspend fun maybeSyncBeforePlay() {
        if (!prefs.getBoolean("sync_progress_before_play", true)) return
        withContext(Dispatchers.IO) { runCatching { books.syncProgress() } }
    }

    // Chapters are cached so a downloaded book has them offline.
    private fun cacheChapters(itemId: String, chapters: List<Chapter>) {
        if (chapters.isEmpty()) return
        val encoded = chapters.joinToString(";") { "${it.startSec}|${it.title.replace(";", ",")}" }
        prefs.putString(chaptersKey(itemId), encoded)
    }

    private fun loadCachedChapters(itemId: String): List<Chapter> =
        prefs.getString(chaptersKey(itemId))
            ?.split(";")
            ?.mapNotNull { entry ->
                val start = entry.substringBefore('|').toDoubleOrNull() ?: return@mapNotNull null
                Chapter(entry.substringAfter('|'), start)
            }
            .orEmpty()

    private fun chaptersKey(itemId: String) = "chapters_$itemId"

    fun stop() {
        syncNow(finished = false)          // captures the current session id first
        sessionId?.let { id -> sessionId = null; closeSessionOrdered(id) }
        syncJob?.cancel()
        player.stop()
        _nowPlaying.value = null
    }

    /**
     * Like [stop], but SUSPENDS until the final progress report and session close
     * have actually gone out — so "Exit App" doesn't quit before the last sync
     * lands. Acquiring the sync mutex here drains the queued report first.
     */
    suspend fun stopAndAwait() {
        if (!::player.isInitialized) return
        syncNow(finished = false)
        val sid = sessionId
        sessionId = null
        syncJob?.cancel()
        withContext(Dispatchers.IO) {
            syncMutex.withLock { sid?.let { runCatching { api.closeSession(it) } } }
        }
        player.stop()
        _nowPlaying.value = null
    }

    private inner class PlayerEvents : Player.Listener {

        /**
         * isPlaying (not playWhenReady): it is false while buffering or after an
         * audio-focus loss, so those don't get billed as listening time.
         */
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            if (isPlaying) {
                needsFreshLoad = false
                accrual.onPlaybackStarted()
                applySmartRewindIfDue()
                startSyncLoop()
            } else {
                accrual.onPlaybackStopped()

                // isPlaying goes false for two very different reasons: the user (or
                // audio focus) intentionally paused — playWhenReady is then false —
                // or playback merely STALLED while buffering / re-preparing, where
                // playWhenReady stays true because we still intend to play. Only the
                // first is a real pause. Treating a rebuffer as a pause was closing
                // the streaming session (killing playback), cancelling the sleep
                // timer, and arming smart-rewind for a stall the user never caused.
                val intentionalPause = !::player.isInitialized || !player.playWhenReady
                if (!intentionalPause) return

                // Stop waking every 26s while paused; a final sync happens below.
                syncJob?.cancel()
                pausedAtMs = android.os.SystemClock.elapsedRealtime()
                onPaused?.invoke()
                // Snapshot where we paused so the player's Play history can jump back.
                _nowPlaying.value?.let { np ->
                    globalPositionSec()?.let { pos ->
                        val ch = currentChapter()
                        com.bennybar.kitzi.data.PlaybackJournal.record(np.itemId, pos, ch?.title, ch?.index)
                    }
                }
                syncNow()
                // A session is closed on pause and reopened on resume — that is what
                // stops the server transcoding for a paused client.
                sessionId?.let { id -> sessionId = null; closeSessionOrdered(id) }
            }
        }

        /**
         * Local files arrive with unknown durations; the player learns them as it
         * prepares each item. Without folding them back in, the book position is
         * unknowable past track 0 and progress sync silently stops.
         */
        override fun onEvents(player: Player, events: Player.Events) {
            if (!events.contains(Player.EVENT_TIMELINE_CHANGED) &&
                !events.contains(Player.EVENT_TRACKS_CHANGED)
            ) return
            hydrateDurations()
        }

        override fun onPlaybackStateChanged(state: Int) {
            if (state == Player.STATE_ENDED) {
                val finishedId = _nowPlaying.value?.itemId
                syncNow(finished = true)
                sessionId?.let { id -> sessionId = null; closeSessionOrdered(id) }
                finishedId?.let { onBookFinished?.invoke(it) }
            }
        }

        override fun onMediaItemTransition(item: MediaItem?, reason: Int) = syncNow()
    }

    private fun hydrateDurations() {
        val np = _nowPlaying.value ?: return
        if (np.tracks.all { it.durationSec != null }) return

        val timeline = player.currentTimeline
        if (timeline.windowCount != np.tracks.size) return

        val window = androidx.media3.common.Timeline.Window()
        var changed = false
        val hydrated = np.tracks.mapIndexed { i, t ->
            if (t.durationSec != null) return@mapIndexed t
            timeline.getWindow(i, window)
            val durationMs = window.durationUs / 1000
            if (durationMs <= 0 || window.durationUs == androidx.media3.common.C.TIME_UNSET) {
                t
            } else {
                changed = true
                t.copy(durationSec = durationMs / 1000.0)
            }
        }
        if (changed) {
            // Chapters for local books are derived from track durations, which were
            // unknown when playItem ran (chaptersFromTracks returns empty then).
            // Now that durations exist, rebuild — otherwise a downloaded book has
            // no chapter ticks, no chapter row, and a dead Chapters sheet.
            val chapters = np.chapters.ifEmpty { PlaybackMath.chaptersFromTracks(hydrated) }
            _nowPlaying.value = np.copy(tracks = hydrated, chapters = chapters)
        }
    }

    companion object {
        private const val TAG = "PlaybackController"
        private const val PING_MS = 26_000L

        private const val KEY_SEEK_FORWARD = "ui_seek_forward_seconds"
        private const val KEY_SEEK_BACKWARD = "ui_seek_backward_seconds"
        private const val KEY_SMART_REWIND = "smart_rewind_enabled"
        private const val KEY_SPEED = "playback_speed"
        const val KEY_LAST_ITEM = "playback_last_item_id"

        /** Playback-speed range the slider scrubs over, in 0.05 steps. */
        const val MIN_SPEED = 0.5
        const val MAX_SPEED = 3.0
    }
}
