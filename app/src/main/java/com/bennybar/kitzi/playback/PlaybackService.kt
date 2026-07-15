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
import androidx.media3.session.SessionCommand
import androidx.media3.session.SessionResult
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

        // Rewind / fast-forward as custom commands declared through Media3 1.6+
        // MEDIA BUTTON PREFERENCES — the API that replaced setCustomLayout because
        // custom layouts rendered in wrong/jumbled order on system media controls
        // (androidx/media#1317). Preferences carry slot placement (back / forward
        // of play-pause), which One UI and the platform notification honour.
        val backSec = Services.prefs.getInt("ui_seek_backward_seconds", 30)
        val fwdSec = Services.prefs.getInt("ui_seek_forward_seconds", 30)
        val rewindButton = CommandButton.Builder(CommandButton.ICON_REWIND)
            .setDisplayName("Rewind ${backSec}s")
            .setSessionCommand(SessionCommand(CMD_REWIND, Bundle.EMPTY))
            .setSlots(CommandButton.SLOT_BACK)
            .build()
        val forwardButton = CommandButton.Builder(CommandButton.ICON_FAST_FORWARD)
            .setDisplayName("Forward ${fwdSec}s")
            .setSessionCommand(SessionCommand(CMD_FORWARD, Bundle.EMPTY))
            .setSlots(CommandButton.SLOT_FORWARD)
            .build()

        // DIAGNOSTIC (Samsung Now Bar): when enabled, expose the RAW ExoPlayer to the
        // session with no custom button preferences, to test whether the whole-book
        // wrapper (per-track timeline reporting book position/duration) is why One UI
        // withholds the media pill. Off by default — turning it on trades away
        // book-coordinate lock-screen position and chapter-skip until turned off.
        val plainSession = Services.prefs.getBoolean("debug_plain_media_session", false)
        session = if (plainSession) {
            MediaLibrarySession.Builder(this, player, LibraryCallback()).build()
        } else {
            MediaLibrarySession.Builder(this, BookCoordinatePlayer(player), LibraryCallback())
                .setMediaButtonPreferences(ImmutableList.of(rewindButton, forwardButton))
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
    }

    private inner class LibraryCallback : MediaLibrarySession.Callback {

        // Grant the two custom seek commands so their buttons are live everywhere.
        override fun onConnect(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
        ): MediaSession.ConnectionResult {
            val commands = MediaSession.ConnectionResult.DEFAULT_SESSION_AND_LIBRARY_COMMANDS.buildUpon()
                .add(SessionCommand(CMD_REWIND, Bundle.EMPTY))
                .add(SessionCommand(CMD_FORWARD, Bundle.EMPTY))
                .build()
            return MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                .setAvailableSessionCommands(commands)
                .build()
        }

        override fun onCustomCommand(
            session: MediaSession,
            controllerInfo: MediaSession.ControllerInfo,
            customCommand: SessionCommand,
            args: Bundle,
        ): ListenableFuture<SessionResult> {
            when (customCommand.customAction) {
                CMD_REWIND -> controller.seekBackward()
                CMD_FORWARD -> controller.seekForward()
            }
            return Futures.immediateFuture(SessionResult(SessionResult.RESULT_SUCCESS))
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
                ?: return@future LibraryResult.ofError<MediaItem>(LibraryResult.RESULT_ERROR_BAD_VALUE)
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
            val itemId = mediaItems.firstOrNull()?.mediaId?.substringBefore('#')
            if (!itemId.isNullOrEmpty()) {
                scope.launch { controller.playItem(itemId) }
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
                .build()
        )
        .build()

    private companion object {
        const val CMD_REWIND = "com.bennybar.kitzi.REWIND"
        const val CMD_FORWARD = "com.bennybar.kitzi.FORWARD"
        const val ROOT = "kitzi_root"
        const val CONTINUE = "kitzi_continue"
        const val RECENT = "kitzi_recent"
        const val DOWNLOADED = "kitzi_downloaded"
        const val ALL = "kitzi_all"
    }
}
