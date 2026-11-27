package com.bennybar.kitzi

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.widget.Toast
import androidx.core.content.pm.ShortcutInfoCompat
import androidx.core.content.pm.ShortcutManagerCompat
import androidx.core.graphics.drawable.IconCompat
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.playback.PlaybackController
import com.bennybar.kitzi.playback.PlaybackService
import com.bennybar.kitzi.ui.player.formatClock
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.guava.await
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Launcher shortcuts (Android's stand-in for the iOS Siri / Shortcuts intents):
 * Resume, Add Bookmark, a 30-minute sleep timer, and the last book. They act on
 * playback without opening the app, the way the iOS intents do.
 */
class ShortcutActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        Services.init(this)
        val app = applicationContext
        val action = intent?.action
        val itemId = intent?.getStringExtra(EXTRA_ITEM_ID)
        // Playing needs the media service, connected while this activity is still in
        // the foreground: started seconds later from the background, Android 12+ can
        // refuse it as a foreground service. The controller holds it until playing.
        val controller = if (action == ACTION_RESUME || action == ACTION_PLAY_BOOK) {
            MediaController.Builder(app, SessionToken(app, ComponentName(app, PlaybackService::class.java))).buildAsync()
        } else null
        // Outlives this activity, which must finish before it's shown (Theme.NoDisplay).
        CoroutineScope(Dispatchers.Main).launch {
            val c = Services.playback
            if (controller != null && withTimeoutOrNull(10_000) { runCatching { controller.await() }.getOrNull() } == null) {
                Toast.makeText(app, "Couldn't start playback.", Toast.LENGTH_SHORT).show()
                MediaController.releaseFuture(controller)
                return@launch
            }
            val message = when (action) {
                ACTION_RESUME -> when {
                    c.nowPlaying.value != null -> { c.resume(); null }
                    else -> {
                        // As iOS: the last book, else the latest in progress.
                        val id = Services.prefs.getString(PlaybackController.KEY_LAST_ITEM)
                            ?: runCatching { Services.books.continueListening(limit = 1) }.getOrNull()?.firstOrNull()?.id
                        when {
                            id == null -> "There's nothing to resume."
                            runCatching { c.playItem(id) }.getOrDefault(false) -> null
                            else -> "Couldn't start this book"
                        }
                    }
                }
                ACTION_PLAY_BOOK -> if (itemId != null && runCatching { c.playItem(itemId) }.getOrDefault(false)) null
                    else "Couldn't start this book"
                ACTION_BOOKMARK -> {
                    val np = c.nowPlaying.value
                    val pos = c.globalPositionSec()
                    when {
                        np == null -> "Nothing is playing."
                        pos == null -> "Couldn't tell where the book is. Try again in a moment."
                        else -> {
                            val sent = Services.books.addBookmark(np.itemId, pos, c.currentChapter()?.title ?: "Bookmark")
                            if (sent) "Bookmark added at ${formatClock(pos.toLong())}."
                            else "Bookmark saved. It syncs when the server can be reached."
                        }
                    }
                }
                ACTION_SLEEP -> if (c.nowPlaying.value == null) "Nothing is playing." else {
                    Services.sleepTimer.startDuration(30)
                    "Pausing in 30 minutes."
                }
                else -> null
            }
            message?.let { Toast.makeText(app, it, Toast.LENGTH_SHORT).show() }
            if (controller != null) {
                if (message == null) withTimeoutOrNull(15_000) { c.isPlaying.first { it } }
                MediaController.releaseFuture(controller)
            }
        }
        finish()
    }

    companion object {
        const val ACTION_RESUME = "com.bennybar.kitzi.action.RESUME"
        const val ACTION_PLAY_BOOK = "com.bennybar.kitzi.action.PLAY_BOOK"
        const val ACTION_BOOKMARK = "com.bennybar.kitzi.action.ADD_BOOKMARK"
        const val ACTION_SLEEP = "com.bennybar.kitzi.action.SLEEP_TIMER"
        private const val EXTRA_ITEM_ID = "item_id"
        private const val BOOK_SHORTCUT_ID = "book"

        /** The long-press entry for the book just loaded: plays it. */
        fun pushBookShortcut(context: Context, itemId: String, title: String) {
            val shortcut = ShortcutInfoCompat.Builder(context, BOOK_SHORTCUT_ID)
                .setShortLabel(title.ifBlank { "Play Audiobook" })
                .setIcon(IconCompat.createWithResource(context, R.drawable.ic_shortcut_book))
                .setIntent(
                    Intent(context, ShortcutActivity::class.java)
                        .setAction(ACTION_PLAY_BOOK)
                        .putExtra(EXTRA_ITEM_ID, itemId)
                )
                .build()
            runCatching { ShortcutManagerCompat.pushDynamicShortcut(context, shortcut) }
        }

        fun removeBookShortcut(context: Context) {
            runCatching { ShortcutManagerCompat.removeDynamicShortcuts(context, listOf(BOOK_SHORTCUT_ID)) }
        }
    }
}
