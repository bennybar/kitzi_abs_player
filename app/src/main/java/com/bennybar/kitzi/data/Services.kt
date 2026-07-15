package com.bennybar.kitzi.data

import android.content.Context
import com.bennybar.kitzi.data.db.DownloadsDao
import com.bennybar.kitzi.data.db.KitziDatabase
import com.bennybar.kitzi.data.legacy.DownloadPaths
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import com.bennybar.kitzi.downloads.DownloadPlanResolver
import com.bennybar.kitzi.downloads.DownloadsRepository
import com.bennybar.kitzi.data.net.AbsApi
import com.bennybar.kitzi.data.net.AuthApi
import com.bennybar.kitzi.data.net.Http
import com.bennybar.kitzi.data.net.OidcClient
import com.bennybar.kitzi.data.net.PlaybackApi
import com.bennybar.kitzi.data.net.SessionStore
import com.bennybar.kitzi.data.net.TokenRefresher
import com.bennybar.kitzi.playback.PlayQueue
import com.bennybar.kitzi.playback.PlaybackController
import com.bennybar.kitzi.playback.SleepTimer
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * Manual wiring. The Flutter app used plain singletons (`AuthRepository.ensure()`
 * and friends) rather than a DI container, and a service locator keeps the port
 * a like-for-like translation instead of a re-architecture.
 */
object Services {

    @Volatile private var initialized = false

    lateinit var prefs: FlutterPrefs; private set
    lateinit var session: SessionStore; private set
    lateinit var auth: AuthRepository; private set
    lateinit var books: BooksRepository; private set
    lateinit var playback: PlaybackController; private set
    lateinit var playbackApi: PlaybackApi; private set
    lateinit var sleepTimer: SleepTimer; private set
    lateinit var queue: PlayQueue; private set
    lateinit var downloads: DownloadsRepository; private set
    lateinit var downloadPaths: DownloadPaths; private set
    lateinit var httpClient: OkHttpClient; private set

    private lateinit var appContext: Context

    fun init(context: Context) {
        if (initialized) return
        synchronized(this) {
            if (initialized) return
            val app = context.applicationContext
            appContext = app

            prefs = FlutterPrefs(app)
            session = SessionStore(app)
            downloadPaths = DownloadPaths(app, prefs)

            val authApi = AuthApi(Http.authClient(), session)
            val refresher = TokenRefresher(session, authApi)
            httpClient = Http.apiClient(session, refresher)
            auth = AuthRepository(session, authApi, refresher, OidcClient(session, authApi))

            val absApi = AbsApi(httpClient, session)
            playbackApi = PlaybackApi(httpClient, session)
            books = BooksRepository(app, absApi, session, prefs)
            playback = PlaybackController(app, playbackApi, books, prefs, downloadPaths)
            downloads = DownloadsRepository(
                app,
                downloadsDao(),
                DownloadPlanResolver(absApi, playbackApi, prefs),
                downloadPaths,
                prefs,
                books,
            )
            sleepTimer = SleepTimer(playback)
            queue = PlayQueue(prefs)

            initialized = true
        }

        // Bring downloads the Flutter app made into the database, so they show up
        // in Downloads and count as "already downloaded".
        CoroutineScope(Dispatchers.IO).launch {
            runCatching { downloads.adoptExistingDownloads() }
        }

        // Local playback only engages for COMPLETE downloads; a partial download
        // (interrupted mid-queue) must stream instead of playing 1-of-N files.
        playback.isDownloadComplete = { itemId -> downloads.isDownloaded(itemId) }
        // Seed local tracks with the durations captured at download time, so a
        // downloaded book's total is correct immediately (no understated progress).
        playback.localTrackDurations = { itemId -> downloads.trackDurations(itemId) }

        // "Pause cancels the sleep timer" (default on).
        playback.onPaused = {
            if (prefs.getBoolean("pause_cancels_sleep_timer", true)) sleepTimer.cancel()
        }

        // When a book finishes: advance the queue, and honour delete-on-finish.
        // Both are wired here rather than in the player so they work even when the
        // book completes with no UI attached (in the car, or with the screen off).
        playback.onBookFinished = { finishedId ->
            if (downloads.autoDeleteOnFinish) {
                CoroutineScope(Dispatchers.IO).launch {
                    runCatching { downloads.delete(finishedId) }
                }
            }
            queue.popNext(finishedId)?.let { next ->
                CoroutineScope(Dispatchers.Main).launch {
                    runCatching { playback.playItem(next.id) }
                }
            }
        }
    }

    /** The downloads table lives in the active library's database, like everything else. */
    fun downloadsDao(): DownloadsDao {
        val libraryId = prefs.getString(FlutterPrefs.KEY_LIBRARY_ID)
            ?.takeIf { it.isNotBlank() } ?: DownloadPaths.DEFAULT_LIBRARY_ID
        return KitziDatabase.forLibrary(appContext, libraryId).downloadsDao()
    }
}
