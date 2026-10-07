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
import com.bennybar.kitzi.data.net.LocalPlay
import com.bennybar.kitzi.data.net.PlaybackApi
import com.bennybar.kitzi.data.net.ProgressReport
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
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

    // True while a play request is loading — opening the server session and running
    // the sync-before-play — but audio hasn't started. Drives a spinner so a slow
    // network doesn't look like a dead button.
    private val _preparing = MutableStateFlow(false)
    val preparing: StateFlow<Boolean> = _preparing.asStateFlow()

    /** Whether audio is playing, pushed from the player as it changes — the UI used
     *  to poll for it, so the play/pause icon lagged up to 2 s behind a tap. */
    private val _isPlaying = MutableStateFlow(false)
    val isPlaying: StateFlow<Boolean> = _isPlaying.asStateFlow()

    /**
     * Whether the position has moved since it was last saved: something played, or a
     * seek. Only then is it saved and reported. Loading a book used to report (and
     * re-stamp locally as "newest") the position it was loaded at — which could be
     * stale, overwriting newer progress made on another device.
     */
    private var positionDirty = false

    /** Where the last jump (a seek of more than a few seconds) started, for "Last position". */
    @Volatile var positionBeforeLastJump: Double? = null
        private set

    private var sessionId: String? = null

    /** Set while a DOWNLOADED book plays: its listening time is reported through a
     *  local session, since there is no server session to carry it (see LocalPlay). */
    private var localPlay: LocalPlay? = null

    // Set while stop()/stopAndAwait() tear a book down. player.stop() makes
    // isPlaying go false, and the listener treats that as a user pause: it fired one
    // more fire-and-forget progress report, with isFinished=false, that landed AFTER
    // the teardown finished. That is what reverted "Mark as Finished" on the server.
    @Volatile private var tearingDown = false
    private var lastSyncedSec: Double = -1.0

    /** When the last server report went out, and how many in a row have failed —
     *  the sync loop spaces reports out (and backs off) using these. */
    @Volatile private var lastNetSyncAt = 0L
    @Volatile private var failedSyncs = 0

    /** Bumped on every seek and chapter/track skip, so the sleep timer can tell a
     *  jump (re-target "end of chapter") from playing on. */
    @Volatile var seekGeneration = 0
        private set

    /** The report after a seek, delayed so a burst of taps sends one request. */
    private var seekSyncJob: kotlinx.coroutines.Job? = null
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
    // load waits on this rather than touching an uninitialised `player`. Replaced
    // with a fresh one when the service goes away (see detach).
    @Volatile private var playerReady = kotlinx.coroutines.CompletableDeferred<Unit>()

    /**
     * Set between the service releasing its player and the next load: where the book
     * was, in book seconds. Android can destroy a paused playback service while the
     * app lives on; the book stayed "loaded" here, but the player under it was
     * released (play did nothing) or replaced by an empty one (the position read 0 —
     * and the next play saved and synced that 0, resuming the book from the start
     * and overwriting the server's position).
     */
    @Volatile private var detachedAtSec: Double? = null

    /** Asks the app to bring the playback service back, when a play finds it gone. */
    var requestPlayer: (() -> Unit)? = null

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

    /**
     * The service is about to release [released]. Keeps the book (so the mini-player
     * still shows it, at the right place) but remembers the exact position, closes
     * the server session, and makes the next play reload the book on the next
     * player the service attaches.
     */
    fun detach(released: ExoPlayer) {
        if (!::player.isInitialized || player !== released) return
        val pos = if (_nowPlaying.value != null && detachedAtSec == null) globalPositionSec() else null
        syncJob?.cancel()
        // The final report (with its listening time) and the session close, in order,
        // like a pause — it used to save the position but never send the interval.
        syncThenClose()
        if (_nowPlaying.value != null && detachedAtSec == null) {
            detachedAtSec = pos ?: prefs.getDouble(progressKey(_nowPlaying.value!!.itemId), 0.0)
        }
        _isPlaying.value = false
        needsFreshLoad = true
        playerReady = kotlinx.coroutines.CompletableDeferred()
    }

    // ---- book coordinates --------------------------------------------------

    private fun tracks(): List<Track> = _nowPlaying.value?.tracks.orEmpty()

    /** Where we are in the BOOK, or null when it cannot be known (see PlaybackMath). */
    fun globalPositionSec(): Double? {
        if (!::player.isInitialized) return null
        val np = _nowPlaying.value ?: return null
        // No player holding this book right now (see detach): where it was, not the
        // empty player's 0.
        detachedAtSec?.let { return it }
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

        val before = globalPositionSec()
        if (before != null && kotlin.math.abs(target - before) > JUMP_MIN_SEC) positionBeforeLastJump = before
        player.seekTo(tp.trackIndex, (tp.offsetSec * 1000).toLong())
        seekGeneration++
        positionDirty = true
        if (reportNow) {
            // Debounced: five quick +30 s taps (or a scrub) sent five requests.
            seekSyncJob?.cancel()
            seekSyncJob = scope.launch { delay(SEEK_SYNC_DEBOUNCE_MS); syncNow() }
        }
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

        // Track skip only for a book with no chapters. In the LAST chapter there is no
        // next start, and falling back to the next file jumped mid-chapter in a
        // multi-file book.
        if (next != null) seekGlobal(next)
        else if (np?.chapters.isNullOrEmpty() && player.hasNextMediaItem()) { player.seekToNextMediaItem(); seekGeneration++; positionDirty = true }
    }

    fun previousChapter() {
        val pos = globalPositionSec()
        val np = _nowPlaying.value
        val prev = if (pos != null && np != null) {
            PlaybackMath.previousChapterStart(pos, np.chapters, totalDurationSec())
        } else null

        // In the first chapter there is no previous one: go to its start (a track
        // skip there jumped mid-chapter in a multi-file book).
        if (prev != null) seekGlobal(prev)
        else if (!np?.chapters.isNullOrEmpty()) seekGlobal(0.0)
        else if (player.hasPreviousMediaItem()) { player.seekToPreviousMediaItem(); seekGeneration++; positionDirty = true }
    }

    fun setSpeed(speed: Double) {
        // Free 0.05 steps across the allowed range (driven by the speed slider),
        // rather than snapping to a fixed preset set.
        val v = kotlin.math.round(speed.coerceIn(MIN_SPEED, MAX_SPEED) * 20) / 20.0
        player.setPlaybackParameters(PlaybackParameters(v.toFloat()))
        // Remembered for this book (narrators differ a lot), and as the default for
        // books that don't have their own yet.
        prefs.putDouble(KEY_SPEED, v)
        _nowPlaying.value?.let { prefs.putDouble(itemSpeedKey(it.itemId), v) }
    }

    private fun itemSpeedKey(itemId: String) = "playback_speed:$itemId"

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
        val np = _nowPlaying.value ?: return
        val itemId = np.itemId
        val notResumable = needsFreshLoad || detachedAtSec != null ||
            player.playerError != null ||
            player.playbackState == Player.STATE_IDLE ||
            // Ended (a finished book): play() does nothing there, and a reload starts
            // a finished book over (RESTART_WITHIN_SEC).
            player.playbackState == Player.STATE_ENDED ||
            player.mediaItemCount == 0 ||
            // Pausing a STREAMED book closes its server session (that's what stops
            // the transcode). Nothing reopened it, so resuming reused track URLs the
            // session owned: fine for a direct-played file, but a transcoded book's
            // URLs are session-scoped and 404 once it's gone — play looked like it
            // did nothing. A downloaded book has no session and is unaffected.
            (!np.isLocal && sessionId == null)
        // A streamed book paused briefly doesn't need the full reload: its session was
        // closed on pause, but a direct-played file's URL doesn't belong to the
        // session. So play at once and open a new session in the background, rather
        // than reopening it, re-downloading the whole /api/me and rebuffering from
        // scratch on every headset or car pause. Transcoded books (whose track URLs
        // die with the session) and long pauses (another device may have moved on)
        // still reload fully.
        val pausedFor = pausedAtMs?.let { android.os.SystemClock.elapsedRealtime() - it }
        val quickResume = notResumable && !needsFreshLoad &&
            player.playerError == null &&
            player.playbackState != Player.STATE_IDLE &&
            player.mediaItemCount > 0 &&
            !np.isLocal && sessionId == null &&
            np.tracks.none { it.isSessionScoped() } &&
            pausedFor != null && pausedFor < QUICK_RESUME_MAX_PAUSE_MS
        if (quickResume) {
            scope.launch {
                // "Sync progress before play" still applies: if another device moved
                // this book on during the pause, resume from there. One small
                // request, awaited for at most QUICK_SYNC_WAIT_MS so an unreachable
                // server can't stall the play (it may still land later, harmlessly).
                if (prefs.getBoolean("sync_progress_before_play", true)) {
                    val fetch = scope.async(Dispatchers.IO) { runCatching { books.syncProgressFor(itemId) } }
                    withTimeoutOrNull(QUICK_SYNC_WAIT_MS) { fetch.await() }
                    // Same rule as a fresh start: the newer of the local and server
                    // positions wins.
                    val target = resumePosition(itemId)
                    val here = globalPositionSec()
                    if (_nowPlaying.value?.itemId == itemId && here != null &&
                        kotlin.math.abs(target - here) > RESUME_JUMP_MIN_SEC
                    ) {
                        seekGlobal(target, reportNow = false)
                    }
                }
                player.play()
                reopenSession(itemId)
            }
        } else if (notResumable) {
            needsFreshLoad = false
            scope.launch { runCatching { playItem(itemId, startPlaying = true) } }
        } else {
            player.play()
        }
    }

    /** A transcode (HLS) track: its URL belongs to the server session. */
    private fun Track.isSessionScoped() =
        "/hls/" in url || url.substringBefore('?').endsWith(".m3u8") || mimeType.contains("mpegurl", ignoreCase = true)

    /**
     * The session for a quick resume. Progress reports and listening time go
     * through it once it's back; until then they wait in the accrual. If the user
     * paused again or moved to another book meanwhile, it's closed straight away
     * rather than left open on the server.
     */
    private suspend fun reopenSession(itemId: String) {
        val opened = withContext(Dispatchers.IO) { runCatching { api.openSession(itemId) }.getOrNull() }
            ?: return
        val sid = opened.sessionId ?: return
        if (_nowPlaying.value?.itemId == itemId && player.isPlaying && sessionId == null) {
            sessionId = sid
        } else {
            withContext(Dispatchers.IO) { syncMutex.withLock { runCatching { api.closeSession(sid) } } }
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
        // Don't touch `player` until the service has attached it — and if the service
        // was destroyed, ask for it back first.
        if (!playerReady.isCompleted) requestPlayer?.invoke()
        playerReady.await()
        val myGen = ++loadGeneration
        // Signal "preparing" for a real play: opening the session and the
        // sync-before-play can take seconds on a slow network, and without this the
        // UI shows a paused book with nothing happening and reads as stuck. Guarded
        // by generation on clear so a superseded double-tap can't switch off the
        // spinner the newer tap is still relying on.
        if (startPlaying) _preparing.value = true
        try {
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
            // Resolve the INCOMING book — including opening its server session —
            // before tearing anything down. Doing it the other way round meant a
            // server that refused the new session left the old book playing against
            // a session that had already been closed: audio that dies at the next
            // track, and progress reported for a book the user isn't on.
            val staged = resolve(itemId) ?: return false
            if (myGen != loadGeneration) {
                // Superseded while we were resolving. Give back the session we just
                // opened rather than leaking a transcode on the server.
                staged.sessionId?.let { id ->
                    withContext(Dispatchers.IO) { runCatching { api.closeSession(id) } }
                }
                return false
            }

            // Only now flush the OUTGOING book: loadAndStart resets the accrual and
            // the last-sync marker, so without this the final position and up to a
            // whole sync interval of listening time are silently discarded on every
            // switch. Awaited so it lands before the session it belongs to is closed.
            // Bounded: the local position is already persisted synchronously inside
            // the payload build, so this wait only buys the server report landing
            // before the session closes. Offline it must not stall the switch.
            // Not when detached: the position was saved when the player went, and the
            // new player can't report it (it would report 0).
            if (_nowPlaying.value != null && detachedAtSec == null) {
                runCatching { withTimeoutOrNull(3_000) { syncNowAwaiting() } }
            }
            // Close the previous streamed session so the server stops transcoding for
            // the book we're leaving. Ordered against in-flight progress reports so a
            // stale sync can't reopen it.
            sessionId?.let { id ->
                sessionId = null
                withContext(Dispatchers.IO) { syncMutex.withLock { runCatching { api.closeSession(id) } } }
            }
            sessionId = staged.sessionId
            loadAndStart(staged.nowPlaying, startPlaying)
            return true
        }
        } finally {
            // Only the latest load clears the flag — a superseded one returning here
            // must not turn off a spinner the newer load still owns.
            if (myGen == loadGeneration) _preparing.value = false
        }
    }

    /**
     * Builds the NowPlaying for a book, opening a server session when it isn't
     * downloaded. Returns null when the book can't be played — no session and no
     * local files. Touches no player or controller state, so a failure here leaves
     * whatever is currently playing exactly as it was.
     */
    private suspend fun resolve(itemId: String): Staged? {
        val durations = localTrackDurations?.invoke(itemId).orEmpty()
        val local = localTracks(itemId, durations)
            .takeIf { it.isNotEmpty() && isDownloadComplete?.invoke(itemId) != false }
            .orEmpty()
        val cached = books.getBook(itemId)

        if (local.isNotEmpty()) {
            return Staged(
                NowPlaying(
                    itemId = itemId,
                    title = cached?.title ?: "",
                    author = cached?.author,
                    coverUrl = cached?.coverUrl,
                    tracks = local,
                    // A DOWNLOADED book must start without touching the network: use
                    // the cached chapters, else per-track boundaries immediately. The
                    // real list is fetched in the background afterwards (see below) —
                    // awaiting it here made offline playback hang on a network timeout.
                    chapters = loadCachedChapters(itemId)
                        .ifEmpty { PlaybackMath.chaptersFromTracks(local) },
                    serverDurationSec = cached?.durationMs?.let { it / 1000.0 },
                    isLocal = true,
                ),
                sessionId = null,
            )
        }

        val session = withContext(Dispatchers.IO) { api.openSession(itemId) } ?: return null
        cacheChapters(itemId, session.chapters)
        return Staged(
            NowPlaying(
                itemId = itemId,
                title = cached?.title ?: "",
                author = cached?.author,
                coverUrl = cached?.coverUrl,
                tracks = session.tracks,
                chapters = session.chapters.ifEmpty { PlaybackMath.chaptersFromTracks(session.tracks) },
                serverDurationSec = session.durationSec ?: cached?.durationMs?.let { it / 1000.0 },
                isLocal = false,
            ),
            sessionId = session.sessionId,
        )
    }

    /** A book resolved and ready to commit, with the session it owns (null if local). */
    private data class Staged(val nowPlaying: NowPlaying, val sessionId: String?)

    private suspend fun loadAndStart(np: NowPlaying, startPlaying: Boolean) {
        val itemId = np.itemId
        _nowPlaying.value = np
        // Remembered so the player can offer "Resume last book" on a cold start.
        prefs.putString(KEY_LAST_ITEM, itemId)
        accrual.reset()
        lastSyncedSec = -1.0

        // "Sync progress before play": pull the latest server progress first so
        // resuming picks up where another device left off. Streamed books only —
        // a downloaded book must start instantly and never wait on the network.
        if (!np.isLocal && startPlaying) maybeSyncBeforePlay(itemId)
        // A finished book is saved at (or a hair before) its end. Resuming there ended
        // it again at once and re-ran the finish handlers — advancing the queue and,
        // with auto-delete on, deleting the download the user had just tapped to
        // re-listen. Starting a finished book means starting it over.
        val total = np.serverDurationSec ?: np.tracks.sumOf { it.durationSec ?: 0.0 }.takeIf { it > 0 }
        val resumeSec = resumePosition(itemId)
            .let { if (total != null && it >= total - RESTART_WITHIN_SEC) 0.0 else it }
        val tp = PlaybackMath.mapGlobalToTrack(resumeSec, np.tracks)
        localPlay = if (np.isLocal) {
            LocalPlay(java.util.UUID.randomUUID().toString(), System.currentTimeMillis(), resumeSec, np.title, np.author)
        } else null

        // Streaming holds a Wi-Fi lock as well as the CPU one (only while playing):
        // with the screen off, Wi-Fi power saving otherwise throttles the stream.
        player.setWakeMode(if (np.isLocal) androidx.media3.common.C.WAKE_MODE_LOCAL else androidx.media3.common.C.WAKE_MODE_NETWORK)
        player.setMediaItems(np.tracks.map { it.toMediaItem(np) }, tp.trackIndex, (tp.offsetSec * 1000).toLong())
        // The player holds the book again; positions come from it from here on.
        detachedAtSec = null
        // Freshly loaded: nothing to report until it plays or seeks.
        positionDirty = false
        positionBeforeLastJump = null
        // This book's own speed, if it has one; else the last speed used.
        player.setPlaybackParameters(
            PlaybackParameters(prefs.getDouble(itemSpeedKey(itemId), savedSpeed().toDouble()).coerceIn(MIN_SPEED, MAX_SPEED).toFloat())
        )
        // A streamed book loaded paused (the last book, auto-loaded on launch) isn't
        // prepared, and its server session is given back now: preparing buffered
        // about a minute of audio for a book the user may never play, and the first
        // play reloads it fresh anyway. A downloaded book is prepared — that's only
        // local disk, and it's what reads its track durations.
        if (startPlaying || np.isLocal) player.prepare()
        if (startPlaying) player.play()
        if (!startPlaying && !np.isLocal) {
            sessionId?.let { sid ->
                sessionId = null
                scope.launch(Dispatchers.IO) { syncMutex.withLock { runCatching { api.closeSession(sid) } } }
            }
        }
        // Loaded-but-not-playing (auto-load) → the first play reloads it fresh.
        needsFreshLoad = !startPlaying

        // A downloaded book plays on its cached chapters (or track boundaries) so it
        // starts offline. Refresh them off the critical path when online and swap in a
        // changed list: chapters fixed on the server later (chapter editor, Audnexus)
        // never reached a downloaded book before. Offline this simply fails.
        if (np.isLocal) {
            scope.launch {
                val real = withContext(Dispatchers.IO) {
                    runCatching { books.chapters(itemId) }.getOrDefault(emptyList())
                }
                if (real.isNotEmpty() && real != loadCachedChapters(itemId)) {
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
    }

    private fun Track.toMediaItem(np: NowPlaying): MediaItem = MediaItem.Builder()
        .setUri(if (isLocal) Uri.fromFile(File(url)) else Uri.parse(url))
        .setMediaId("${np.itemId}#$index")
        .setMimeType(mimeType)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(np.title)
                .setArtist(np.author)
                // A content URI, never the server URL (which needs the token): the
                // session hands this to other apps. See CoverProvider.
                .setArtworkUri(CoverProvider.uriFor(np.itemId))
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
            // Audio only. The saved offline cover (cover.jpg) and its .tmp live in
            // this same directory, and listing everything here treated the cover as
            // track 0 — the player tried to "play" a JPEG and the book wouldn't
            // start until the download was deleted.
            .filter(DownloadPaths::isAudioFile)
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

    /**
     * While playing: the position is saved on the device every [PING_MS] (no radio),
     * and reported to the server every [NET_SYNC_MS]. A report every 26 s kept the
     * cellular radio awake for a third of the time; the final position still goes
     * out on pause, stop and book switch. After failures (server unreachable) the
     * reports back off, and a tick never starts one while another is still running —
     * each can take a minute to time out, and they used to queue up without limit.
     */
    private fun startSyncLoop() {
        syncJob?.cancel()
        syncJob = scope.launch {
            while (true) {
                delay(PING_MS)
                if (!player.isPlaying) continue
                val now = android.os.SystemClock.elapsedRealtime()
                val interval = NET_SYNC_MS shl failedSyncs.coerceAtMost(MAX_BACKOFF_STEPS)
                if (now - lastNetSyncAt >= interval && !syncMutex.isLocked) {
                    lastNetSyncAt = now
                    syncNow()
                } else {
                    buildSyncPayload(finished = false) // saves the position locally
                }
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
        // Nothing moved since the last save: nothing to save or report (see positionDirty).
        if (!finished && !positionDirty && !player.isPlaying) return null
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

        saveLocalPosition(np.itemId, current, finished)
        positionDirty = false

        // The session id and item id are captured HERE, on the caller's thread —
        // reading `sessionId` inside the coroutine could pick up a value changed by a
        // later load/stop and report against the wrong (or a closed) session.
        return SyncPayload(
            itemId = np.itemId,
            sessionId = sessionId,
            localPlay = localPlay,
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
            val report = ProgressReport(p.itemId, p.current, p.total, p.finished, p.paused, listened)
            val ok: Boolean
            val listenedRecorded: Boolean
            if (p.sessionId == null && p.localPlay != null) {
                // Downloaded book: the position (and finished flag) go to the progress
                // endpoint as before; the listening time goes to the local session,
                // which is the only place the server counts it.
                listenedRecorded = listened != null && api.syncLocal(p.localPlay, report, listened)
                if (listenedRecorded) p.localPlay.listenedSec += listened!!
                ok = api.sync(null, report.copy(timeListenedSec = null))
            } else {
                // Only a session sync records listening time; the progress endpoint
                // stores the position and drops it (see PlaybackApi.syncReport).
                val out = api.syncReport(p.sessionId, report)
                ok = out.positionSaved
                listenedRecorded = out.listeningRecorded
            }
            // Only once the server has it — otherwise the time rolls into the next attempt.
            if (listenedRecorded && listened != null) {
                accrual.consume(listened)
                // Record the confirmed listened interval for local stats.
                com.bennybar.kitzi.data.PlayHistoryStore.record(p.itemId, listened)
            }
            if (ok) {
                lastSyncedSec = p.current
                markConfirmed(p.itemId, p.current)
            } else {
                // Pushed once the network is back (or by the next sync).
                com.bennybar.kitzi.data.sync.ProgressPushWorker.enqueue(context)
            }
            failedSyncs = if (ok) 0 else failedSyncs + 1
            // The progress lists read Room rows, which only the server used to write:
            // what was listened here didn't show until the next pull, or ever offline.
            runCatching { books.recordLocalProgress(p.itemId, p.current, p.total, p.finished, System.currentTimeMillis()) }
        }
    }

    /**
     * The local copy of the position: stamped with WHEN it was saved (resume compares
     * it with the server's lastUpdate), and "pending" until the server accepts it —
     * a pending position is pushed when the network is back (flushPendingProgress).
     */
    private fun saveLocalPosition(itemId: String, sec: Double, finished: Boolean) {
        prefs.putDouble(progressKey(itemId), sec)
        prefs.putDouble(progressTsKey(itemId), System.currentTimeMillis().toDouble())
        prefs.putBoolean(pendingKey(itemId), true)
        prefs.putBoolean(finishedKey(itemId), finished)
    }

    /** The server accepted [sec] for [itemId]: no longer pending (unless a newer save happened since). */
    private fun markConfirmed(itemId: String, sec: Double) {
        if (prefs.getDouble(progressKey(itemId), -1.0) == sec) prefs.putBoolean(pendingKey(itemId), false)
    }

    /**
     * A position the server already has (Mark as finished / unfinished, its Undo):
     * the local copy follows it, so it can't win the next resume with an older value.
     */
    fun recordConfirmedPosition(itemId: String, sec: Double, finished: Boolean) {
        prefs.putDouble(progressKey(itemId), sec)
        prefs.putDouble(progressTsKey(itemId), System.currentTimeMillis().toDouble())
        prefs.putBoolean(pendingKey(itemId), false)
        prefs.putBoolean(finishedKey(itemId), finished)
    }

    /**
     * Pushes positions saved while the server couldn't be reached (offline listening,
     * a failed report) — they used to reach the server only the next time that book
     * was played online. A server position newer than the local one wins: something
     * was listened elsewhere since, and must not be overwritten. Skips the book
     * that's playing (its own reports carry it) — not one that's loaded but paused,
     * which sends nothing more until it plays. Safe to call any time.
     */
    suspend fun flushPendingProgress() = withContext(Dispatchers.IO) {
        val loaded = _nowPlaying.value?.itemId?.takeIf { _isPlaying.value }
        val pending = prefs.keysWithPrefix(PENDING_PREFIX)
            .filter { prefs.getBoolean(it, false) }
            .map { it.removePrefix(PENDING_PREFIX) }
            .filter { it != loaded }
        for (itemId in pending) {
            val sec = prefs.getDouble(progressKey(itemId), -1.0).takeIf { it >= 0 } ?: continue
            val ts = prefs.getDouble(progressTsKey(itemId), 0.0).toLong()
            val server = runCatching { books.syncProgressFor(itemId) }.getOrElse { return@withContext } // offline: later
            if (server != null && server.lastUpdate > ts) {
                prefs.putBoolean(pendingKey(itemId), false) // newer elsewhere; keep theirs
                continue
            }
            val total = server?.durationSec?.takeIf { it > 0 } ?: books.getBook(itemId)?.durationMs?.let { it / 1000.0 }
            val finished = prefs.getBoolean(finishedKey(itemId), false)
            val ok = api.sync(null, ProgressReport(itemId, sec, total, finished, true, null))
            if (ok) {
                markConfirmed(itemId, sec)
                books.recordLocalProgress(itemId, sec, total, finished, System.currentTimeMillis())
            } else return@withContext
        }
    }

    private data class SyncPayload(
        val itemId: String,
        val sessionId: String?,
        val localPlay: LocalPlay?,
        val current: Double,
        val total: Double?,
        val finished: Boolean,
        val paused: Boolean,
    )

    /**
     * The final report for a play, then the session close — in that order, in ONE
     * coroutine. They used to be two separate launches, and the mutex only made
     * them exclusive, not ordered: when the close won, the report hit a closed
     * session, fell back to the progress endpoint, and that interval's listening
     * time was consumed without the server ever recording it.
     */
    private fun syncThenClose(finished: Boolean = false) {
        // This report supersedes a pending post-seek one.
        seekSyncJob?.cancel()
        val payload = buildSyncPayload(finished) // captures the session id first
        val sid = sessionId
        sessionId = null
        if (payload == null && sid == null) return
        scope.launch(Dispatchers.IO) {
            payload?.let { performSync(it) }
            sid?.let { syncMutex.withLock { runCatching { api.closeSession(it) } } }
        }
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
        val local = prefs.getDouble(progressKey(itemId), -1.0)
        val localTs = prefs.getDouble(progressTsKey(itemId), 0.0).toLong()
        val pending = prefs.getBoolean(pendingKey(itemId), false)
        val serverEntity = books.progressFor(itemId)

        return when {
            local < 0.0 -> serverEntity?.currentTimeSec ?: 0.0
            // The server has no progress for this book: it never got ours (pending —
            // offline listening), or it was reset or removed (Mark unfinished, "remove
            // from Continue Listening", another account) and then 0 is right. A local
            // value used to win whenever the server said 0, undoing all of those.
            serverEntity == null -> if (pending) local else 0.0
            // Both known: the newer write wins, even when the server's is 0.
            localTs > serverEntity.lastUpdate -> local
            else -> serverEntity.currentTimeSec
        }
    }

    private fun progressKey(itemId: String) = "abs_progress:$itemId"
    private fun progressTsKey(itemId: String) = "abs_progress_ts:$itemId"
    private fun pendingKey(itemId: String) = "$PENDING_PREFIX$itemId"
    private fun finishedKey(itemId: String) = "abs_progress_fin:$itemId"

    /** On logout: every local position belongs to the account that's leaving. */
    fun clearLocalPositions() = prefs.removeWithPrefixes(
        "abs_progress:", "abs_progress_ts:", PENDING_PREFIX, "abs_progress_fin:", "playback_speed:",
    )

    /** Refreshes server-side progress into the local DB before resuming a book. */
    private suspend fun maybeSyncBeforePlay(itemId: String) {
        if (!prefs.getBoolean("sync_progress_before_play", true)) return
        // This one book's progress, not the whole /api/me (every book's progress
        // plus all bookmarks) on every play.
        withContext(Dispatchers.IO) { runCatching { books.syncProgressFor(itemId) } }
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
        tearingDown = true
        syncThenClose()
        syncJob?.cancel()
        player.stop()
        _nowPlaying.value = null
        tearingDown = false
    }

    /**
     * Like [stop], but SUSPENDS until the final progress report and session close
     * have actually gone out — so "Exit App" doesn't quit before the last sync
     * lands. Acquiring the sync mutex here drains the queued report first.
     */
    suspend fun stopAndAwait() {
        if (!::player.isInitialized) return
        tearingDown = true
        // The payload is built BEFORE the session id is cleared: built after, the last
        // interval went out without a session and its listening time was lost.
        val payload = buildSyncPayload(finished = false)
        val sid = sessionId
        sessionId = null
        syncJob?.cancel()
        seekSyncJob?.cancel()
        // Awaited, not fire-and-forget. syncNow() launches into scope and only the
        // mutex ordered it against the close below — nothing guaranteed the launched
        // report won the lock first. That let a stale report land AFTER whatever ran
        // next, which is how "Mark as Finished" on the playing book was reverted by
        // its own final isFinished=false sync moments later.
        withContext(Dispatchers.IO) {
            payload?.let { runCatching { performSync(it) } }
            syncMutex.withLock { sid?.let { runCatching { api.closeSession(it) } } }
        }
        player.stop()
        _nowPlaying.value = null
        tearingDown = false
    }

    /**
     * "Close book": stops it (sending the final position) and forgets it as the last
     * book, so the mini-player goes away until something else is played.
     */
    suspend fun closeBook() {
        stopAndAwait()
        prefs.remove(KEY_LAST_ITEM)
    }

    private inner class PlayerEvents : Player.Listener {

        /**
         * isPlaying (not playWhenReady): it is false while buffering or after an
         * audio-focus loss, so those don't get billed as listening time.
         */
        override fun onIsPlayingChanged(isPlaying: Boolean) {
            _isPlaying.value = isPlaying
            if (isPlaying) {
                positionDirty = true
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
                // A teardown already sent its final report and closed the session;
                // anything from here would race whatever the caller does next.
                if (tearingDown) return

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
                // It was playing until now, so there's a position to save.
                positionDirty = true
                // A session is closed on pause and reopened on resume — that is what
                // stops the server transcoding for a paused client.
                syncThenClose()
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
                syncThenClose(finished = true)
                finishedId?.let { onBookFinished?.invoke(it) }
            }
        }

        // A track change while playing. Not PLAYLIST_CHANGED: that's loading a book,
        // which has nothing new to report (see positionDirty).
        override fun onMediaItemTransition(item: MediaItem?, reason: Int) {
            if (reason != Player.MEDIA_ITEM_TRANSITION_REASON_PLAYLIST_CHANGED) syncNow()
        }
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
        private const val PING_MS = 30_000L
        private const val NET_SYNC_MS = 90_000L
        /** Backoff doubles the report interval up to 8x (12 minutes). */
        private const val MAX_BACKOFF_STEPS = 3
        private const val SEEK_SYNC_DEBOUNCE_MS = 2_500L
        /** A seek further than this counts as a jump (see positionBeforeLastJump). */
        private const val JUMP_MIN_SEC = 5.0
        private const val PENDING_PREFIX = "abs_progress_pending:"
        /** How long a quick resume waits for the server's position before playing. */
        private const val QUICK_SYNC_WAIT_MS = 1_500L
        /** A server position closer than this to where we are isn't worth a jump. */
        private const val RESUME_JUMP_MIN_SEC = 5.0
        /** A pause longer than this resumes with a full reload (see resume()). */
        private const val QUICK_RESUME_MAX_PAUSE_MS = 10 * 60 * 1000L
        /** A saved position this close to the end counts as "finished": start over. */
        private const val RESTART_WITHIN_SEC = 5.0

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
