package com.bennybar.kitzi.playback

import android.content.Intent
import android.os.Bundle
import androidx.media3.common.AudioAttributes
import androidx.media3.common.C
import androidx.media3.common.ForwardingPlayer
import androidx.media3.common.MediaItem
import androidx.media3.common.MediaMetadata
import androidx.media3.common.Player
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.session.CommandButton
import androidx.media3.session.LibraryResult
import androidx.media3.session.MediaLibraryService
import androidx.media3.session.MediaSession
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.LibraryFilter
import com.bennybar.kitzi.data.model.Book
import com.google.common.collect.ImmutableList
import com.google.common.util.concurrent.Futures
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.guava.future
import kotlinx.coroutines.launch

/**
 * The media session: lock screen, notification, hardware buttons and Android Auto.
 *
 * The player exposed to the session is wrapped so that everything outside the app
 * sees BOOK coordinates, not track-local ones — otherwise the Auto seekbar and
 * the lock screen would show "12 minutes" for a 14-hour book, and skip would move
 * by file instead of by chapter.
 */
class PlaybackService : MediaLibraryService() {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var session: MediaLibrarySession
    private lateinit var controller: PlaybackController
    private lateinit var liveUpdate: NowPlayingLiveUpdate

    // Notification / Samsung Now Bar buttons, ALL as explicit button preferences so
    // they surface as custom actions (verified working via dumpsys) — the standard
    // SKIP_TO_PREVIOUS/NEXT actions don't reach the platform session through our
    // whole-book player wrapper. Slots put the SECONDS-SEEK beside play/pause and the
    // chapter-skip on the outer edges: [prev-ch][rewind][play][forward][next-ch].
    private val rewindButton: CommandButton by lazy {
        CommandButton.Builder(CommandButton.ICON_REWIND)
            .setDisplayName("Rewind ${Services.prefs.getInt("ui_seek_backward_seconds", 30)}s")
            .setPlayerCommand(Player.COMMAND_SEEK_BACK)
            .setSlots(CommandButton.SLOT_BACK)
            .build()
    }
    private val forwardButton: CommandButton by lazy {
        CommandButton.Builder(CommandButton.ICON_FAST_FORWARD)
            .setDisplayName("Forward ${Services.prefs.getInt("ui_seek_forward_seconds", 30)}s")
            .setPlayerCommand(Player.COMMAND_SEEK_FORWARD)
            .setSlots(CommandButton.SLOT_FORWARD)
            .build()
    }
    private val prevChapterButton: CommandButton by lazy {
        CommandButton.Builder(CommandButton.ICON_PREVIOUS)
            .setDisplayName("Previous chapter")
            .setPlayerCommand(Player.COMMAND_SEEK_TO_PREVIOUS)
            .setSlots(CommandButton.SLOT_BACK_SECONDARY, CommandButton.SLOT_OVERFLOW)
            .build()
    }
    private val nextChapterButton: CommandButton by lazy {
        CommandButton.Builder(CommandButton.ICON_NEXT)
            .setDisplayName("Next chapter")
            .setPlayerCommand(Player.COMMAND_SEEK_TO_NEXT)
            .setSlots(CommandButton.SLOT_FORWARD_SECONDARY, CommandButton.SLOT_OVERFLOW)
            .build()
    }

    override fun onCreate() {
        super.onCreate()
        Services.init(this)
        controller = Services.playback

        val httpFactory = OkHttpDataSource.Factory(Services.httpClient)
        // Streamed (non-downloaded) audio is served through an LRU disk cache so
        // re-seeking or replaying doesn't re-download bytes. Local file playback
        // bypasses it. Size = the streaming_cache_max_bytes_mb setting.
        val cacheFactory = androidx.media3.datasource.cache.CacheDataSource.Factory()
            .setCache(StreamCache.get(this, Services.prefs))
            .setUpstreamDataSourceFactory(DefaultDataSource.Factory(this, httpFactory))
            .setFlags(androidx.media3.datasource.cache.CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
        val player = ExoPlayer.Builder(this)
            .setMediaSourceFactory(
                DefaultMediaSourceFactory(cacheFactory)
            )
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setContentType(C.AUDIO_CONTENT_TYPE_SPEECH)
                    .setUsage(C.USAGE_MEDIA)
                    .build(),
                /* handleAudioFocus = */ true,
            )
            .setHandleAudioBecomingNoisy(true)
            .setSeekForwardIncrementMs(
                Services.prefs.getInt("ui_seek_forward_seconds", 30) * 1000L
            )
            .setSeekBackIncrementMs(
                Services.prefs.getInt("ui_seek_backward_seconds", 30) * 1000L
            )
            .build()

        controller.attach(player)

        // Notification / lock-screen / Samsung Now Bar buttons come from STANDARD
        // player commands only (no custom setMediaButtonPreferences): One UI's Now
        // Bar renders the platform session's standard actions, and custom actions
        // were ignored. BookCoordinatePlayer.getAvailableCommands advertises
        // seekToPrevious/Next (chapter skip) and seekBack/Forward (the configured
        // seconds), which Media3 exposes as SKIP_TO_PREVIOUS/NEXT + REWIND/FAST_FORWARD
        // for the pill to draw — the same standard-command approach Gramophone uses.

        // debug_plain_media_session (diagnostic): expose the RAW ExoPlayer with no
        // book-coordinate wrapper. Off by default.

        // The activity that opens when the media notification / lock screen / Samsung
        // Now Bar pill is tapped. BOTH the working Flutter app (audio_service) and
        // other working Media3 apps (e.g. Gramophone) set this; we didn't — and a
        // session with no tappable target is exactly what One UI's Now Bar withholds
        // the status-bar pill for.
        val sessionActivity = android.app.PendingIntent.getActivity(
            this, 0,
            Intent(this, com.bennybar.kitzi.MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            android.app.PendingIntent.FLAG_IMMUTABLE or android.app.PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Caches the cover art Media3 paints on the notification / lock screen / Now
        // Bar so it isn't re-decoded on every chapter/track change (adopted from
        // Gramophone). Cover URLs carry their auth token in the query string, so the
        // default HTTP data source is enough.
        val bitmapLoader = androidx.media3.session.CacheBitmapLoader(
            androidx.media3.datasource.DataSourceBitmapLoader(this)
        )
        val plainSession = Services.prefs.getBoolean("debug_plain_media_session", false)
        session = if (plainSession) {
            MediaLibrarySession.Builder(this, player, LibraryCallback())
                .setSessionActivity(sessionActivity)
                .setBitmapLoader(bitmapLoader)
                .build()
        } else {
            MediaLibrarySession.Builder(this, BookCoordinatePlayer(player), LibraryCallback())
                .setSessionActivity(sessionActivity)
                .setBitmapLoader(bitmapLoader)
                .build()
        }

        // Post the playback notification on the app's own audio channel (the one
        // the Flutter app used and users may have configured), instead of Media3's
        // default_channel_id.
        setMediaNotificationProvider(
            androidx.media3.session.DefaultMediaNotificationProvider.Builder(this)
                .setChannelId(com.bennybar.kitzi.KitziApplication.AUDIO_CHANNEL_ID)
                .setChannelName(com.bennybar.kitzi.R.string.app_name)
                .build()
        )

        // Optional promotable "now playing" notification for the Samsung Now Bar
        // pill (see NowPlayingLiveUpdate). Driven here because only the service
        // lives for the whole playback session. No-op unless the setting is on.
        liveUpdate = NowPlayingLiveUpdate(this)
        scope.launch {
            controller.nowPlaying.collectLatest { np ->
                if (np == null) { liveUpdate.clear(); return@collectLatest }
                while (true) {
                    val enabled = Services.prefs.getBoolean("live_update_now_playing", false)
                    val playing = runCatching { controller.player.isPlaying }.getOrDefault(false)
                    if (enabled && playing) {
                        val total = (controller.totalDurationSec() ?: 0.0).toInt()
                        val pos = (controller.globalPositionSec() ?: 0.0).toInt()
                        liveUpdate.update(np.title, controller.currentChapter()?.title ?: np.author, total, pos)
                        kotlinx.coroutines.delay(15_000)
                    } else {
                        // Nothing to refresh while paused or with the feature off
                        // (the default) — idle slowly instead of waking every 15s.
                        liveUpdate.clear()
                        kotlinx.coroutines.delay(if (enabled) 15_000 else 60_000)
                    }
                }
            }
        }
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo) = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiping the app away should not kill playback mid-chapter, but a paused
        // player has nothing to keep the service alive for.
        if (!session.player.playWhenReady || session.player.mediaItemCount == 0) {
            stopSelf()
        }
    }

    override fun onDestroy() {
        liveUpdate.clear()
        session.player.release()
        session.release()
        super.onDestroy()
    }

    /**
     * Presents the whole book to the outside world.
     *
     * Chapter skip is the point: REWRITE.md is explicit that skipToNext /
     * skipToPrevious must move by CHAPTER. Mapping them to a +/-30s nudge means a
     * driver cannot change chapter, which is the single most-used control in a car.
     * Seeking stays on fastForward / rewind, where it belongs.
     */
    private inner class BookCoordinatePlayer(player: Player) : ForwardingPlayer(player) {

        // External play commands (notification, lock screen, Android Auto, Bluetooth)
        // go through the same resume-or-reload path as the in-app buttons, so a
        // just-auto-loaded or errored book reloads fresh instead of no-op playing.
        override fun play() = controller.resume()

        override fun getCurrentPosition(): Long =
            controller.globalPositionSec()?.let { (it * 1000).toLong() } ?: super.getCurrentPosition()

        override fun getDuration(): Long =
            controller.totalDurationSec()?.let { (it * 1000).toLong() } ?: super.getDuration()

        override fun getContentPosition(): Long = currentPosition

        override fun getContentDuration(): Long = duration

        override fun seekTo(positionMs: Long) = controller.seekGlobal(positionMs / 1000.0)

        override fun seekToNext() = controller.nextChapter()

        override fun seekToPrevious() = controller.previousChapter()

        override fun seekToNextMediaItem() = controller.nextChapter()

        override fun seekToPreviousMediaItem() = controller.previousChapter()

        override fun hasNextMediaItem(): Boolean = true

        override fun hasPreviousMediaItem(): Boolean = true

        override fun seekForward() = controller.seekForward()

        override fun seekBack() = controller.seekBackward()

        // Advertise chapter-skip and seek as always available, even for a single-file
        // book whose raw ExoPlayer timeline has one window (which would otherwise not
        // offer prev/next) — the notification/pill buttons are only enabled for
        // commands the player reports here.
        override fun getAvailableCommands(): Player.Commands =
            super.getAvailableCommands().buildUpon()
                .addAll(
                    Player.COMMAND_SEEK_TO_PREVIOUS,
                    Player.COMMAND_SEEK_TO_NEXT,
                    Player.COMMAND_SEEK_TO_PREVIOUS_MEDIA_ITEM,
                    Player.COMMAND_SEEK_TO_NEXT_MEDIA_ITEM,
                    Player.COMMAND_SEEK_BACK,
                    Player.COMMAND_SEEK_FORWARD,
                )
                .build()
    }

    private inner class LibraryCallback : MediaLibrarySession.Callback {

        // Attach the rewind/forward buttons for the surfaces that draw a media UI
        // (notification, Now Bar, Android Auto) — the way Gramophone does it, which
        // is what actually populates One UI's expanded Now Bar button row.
        override fun onConnect(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val builder = MediaSession.ConnectionResult.AcceptedResultBuilder(session)
            if (session.isMediaNotificationController(controllerInfo) ||
                session.isAutoCompanionController(controllerInfo) ||
                session.isAutomotiveController(controllerInfo)
            ) {
                builder.setMediaButtonPreferences(
                    ImmutableList.of(prevChapterButton, rewindButton, forwardButton, nextChapterButton)
                )
            }
            return builder.build()
        }

        // Hardware / car media keys: route skip-next/prev (and fast-forward/rewind)
        // to the configured seconds-seek, not chapter skip or Media3's default
        // "jump to the start of the book". The on-screen OUTER buttons still do
        // chapter skip — they trigger commands directly, not through key events.
        override fun onMediaButtonEvent(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            intent: Intent,
        ): Boolean {
            val keyEvent = androidx.core.content.IntentCompat.getParcelableExtra(
                intent, Intent.EXTRA_KEY_EVENT, android.view.KeyEvent::class.java,
            )
            if (keyEvent?.action == android.view.KeyEvent.ACTION_DOWN && keyEvent.repeatCount == 0) {
                when (keyEvent.keyCode) {
                    android.view.KeyEvent.KEYCODE_MEDIA_NEXT,
                    android.view.KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                        controller.seekForward(); return true
                    }
                    android.view.KeyEvent.KEYCODE_MEDIA_PREVIOUS,
                    android.view.KeyEvent.KEYCODE_MEDIA_REWIND -> {
                        controller.seekBackward(); return true
                    }
                }
            }
            return super.onMediaButtonEvent(session, controllerInfo, intent)
        }

        override fun onGetLibraryRoot(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<MediaItem>> =
            Futures.immediateFuture(
                LibraryResult.ofItem(browsableItem(ROOT, "Kitzi"), params)
            )

        /**
         * The browse tree needs a real root — a single flat list of every book is
         * unusable in a car.
         */
        override fun onGetChildren(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            parentId: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = scope.future {
            val children: List<MediaItem> = when (parentId) {
                ROOT -> listOf(
                    browsableItem(CONTINUE, "Continue listening"),
                    browsableItem(RECENT, "Recently added"),
                    browsableItem(DOWNLOADED, "Downloaded"),
                    browsableItem(ALL, "All books"),
                )

                CONTINUE -> booksToItems(
                    Services.books.pagedBooks(
                        BookSort.UPDATED_DESC, LibraryFilter.IN_PROGRESS, null, pageSize, page * pageSize,
                    ).first()
                )

                RECENT -> booksToItems(
                    Services.books.pagedBooks(
                        BookSort.ADDED_DESC, LibraryFilter.ALL, null, pageSize, page * pageSize,
                    ).first()
                )

                DOWNLOADED -> booksToItems(
                    Services.downloadPaths.downloadedItemIds().mapNotNull { Services.books.getBook(it) }
                )

                ALL -> booksToItems(
                    Services.books.pagedBooks(
                        BookSort.NAME_ASC, LibraryFilter.ALL, null, pageSize, page * pageSize,
                    ).first()
                )

                else -> emptyList()
            }
            LibraryResult.ofItemList(ImmutableList.copyOf(children), params)
        }

        override fun onGetItem(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            mediaId: String,
        ): ListenableFuture<LibraryResult<MediaItem>> = scope.future {
            val book = Services.books.getBook(mediaId)
                ?: return@future LibraryResult.ofError<MediaItem>(
                    androidx.media3.session.SessionError(
                        androidx.media3.session.SessionError.ERROR_BAD_VALUE, "Item not found",
                    )
                )
            LibraryResult.ofItem(book.toMediaItem(), null)
        }

        /**
         * Auto/lock-screen asks us to play a media id. Load the book ourselves
         * rather than letting the session set the item directly — only the
         * controller knows how to resolve local files and book coordinates.
         */
        override fun onSetMediaItems(
            mediaSession: MediaSession,
            browser: MediaSession.ControllerInfo,
            mediaItems: MutableList<MediaItem>,
            startIndex: Int,
            startPositionMs: Long,
        ): ListenableFuture<MediaSession.MediaItemsWithStartPosition> {
            val requested = mediaItems.firstOrNull()
            val itemId = requested?.mediaId?.substringBefore('#')?.takeIf { it.isNotEmpty() }
            // Voice "play <book>" (MEDIA_PLAY_FROM_SEARCH) arrives with no media id,
            // only a search query — resolve it to the best-matching book and play.
            val query = requested?.requestMetadata?.searchQuery?.takeIf { it.isNotBlank() }
            when {
                itemId != null -> scope.launch { controller.playItem(itemId) }
                query != null -> scope.launch {
                    searchHits(query).firstOrNull()?.let { controller.playItem(it.id) }
                }
            }
            // The controller populates the playlist itself.
            return Futures.immediateFuture(
                MediaSession.MediaItemsWithStartPosition(emptyList(), startIndex, startPositionMs)
            )
        }

        override fun onSearch(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<Void>> = scope.future {
            session.notifySearchResultChanged(browser, query, searchHits(query).size, params)
            LibraryResult.ofVoid()
        }

        override fun onGetSearchResult(
            session: MediaLibrarySession,
            browser: MediaSession.ControllerInfo,
            query: String,
            page: Int,
            pageSize: Int,
            params: LibraryParams?,
        ): ListenableFuture<LibraryResult<ImmutableList<MediaItem>>> = scope.future {
            LibraryResult.ofItemList(ImmutableList.copyOf(booksToItems(searchHits(query))), params)
        }

        private suspend fun searchHits(query: String): List<Book> =
            Services.books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.ALL, query, 50, 0).first()
    }

    private fun booksToItems(books: List<Book>) = books.map { it.toMediaItem() }

    private fun Book.toMediaItem(): MediaItem = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setArtist(author)
                .setArtworkUri(coverUrl.let(android.net.Uri::parse))
                .setIsBrowsable(false)
                .setIsPlayable(true)
                .setMediaType(MediaMetadata.MEDIA_TYPE_AUDIO_BOOK)
                .build()
        )
        .build()

    private fun browsableItem(id: String, title: String): MediaItem = MediaItem.Builder()
        .setMediaId(id)
        .setMediaMetadata(
            MediaMetadata.Builder()
                .setTitle(title)
                .setIsBrowsable(true)
                .setIsPlayable(false)
                .setMediaType(MediaMetadata.MEDIA_TYPE_FOLDER_AUDIO_BOOKS)
                // Tell Android Auto to render this node's children as a list of
                // categories, and their books (playables) as a cover grid.
                .setExtras(CONTENT_STYLE_EXTRAS)
                .build()
        )
        .build()

    private companion object {
        /** Android Auto layout hints: category rows as a list, book covers as a grid. */
        val CONTENT_STYLE_EXTRAS = Bundle().apply {
            // Documented content-style values: 1 = list items, 2 = grid items.
            putInt(androidx.media3.session.MediaConstants.EXTRAS_KEY_CONTENT_STYLE_BROWSABLE, 1)
            putInt(androidx.media3.session.MediaConstants.EXTRAS_KEY_CONTENT_STYLE_PLAYABLE, 2)
        }

        const val ROOT = "kitzi_root"
        const val CONTINUE = "kitzi_continue"
        const val RECENT = "kitzi_recent"
        const val DOWNLOADED = "kitzi_downloaded"
        const val ALL = "kitzi_all"
    }
}
