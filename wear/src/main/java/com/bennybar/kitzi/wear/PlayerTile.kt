package com.bennybar.kitzi.wear

import android.content.Context
import androidx.wear.protolayout.ActionBuilders
import androidx.wear.protolayout.ColorBuilders.argb
import androidx.wear.protolayout.DimensionBuilders.dp
import androidx.wear.protolayout.DimensionBuilders.expand
import androidx.wear.protolayout.DimensionBuilders.sp
import androidx.wear.protolayout.LayoutElementBuilders
import androidx.wear.protolayout.ModifiersBuilders
import androidx.wear.protolayout.ResourceBuilders
import androidx.wear.protolayout.TimelineBuilders
import androidx.wear.tiles.RequestBuilders
import androidx.wear.tiles.TileBuilders
import androidx.wear.tiles.TileService
import com.bennybar.kitzi.wear.ui.MainActivity
import com.google.common.util.concurrent.ListenableFuture
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.guava.future

/**
 * The Tile: the book (loaded, else the latest on the shelf), how far you are, and
 * play/pause. Tapping the title opens the app.
 */
class PlayerTile : TileService() {
    private val scope = MainScope()

    override fun onTileRequest(requestParams: RequestBuilders.TileRequest): ListenableFuture<TileBuilders.Tile> = scope.future {
        val k = Kitzi.init(this@PlayerTile)
        if (requestParams.currentState.lastClickableId == TOGGLE && k.store.signedIn) {
            val p = k.player
            when {
                p.nowPlaying.value != null -> p.togglePlay()
                else -> k.shelf.value.firstOrNull()?.let { p.play(it) }
            }
            delay(800) // let the player settle, so the tile shows the new state
        }
        TileBuilders.Tile.Builder()
            .setResourcesVersion(RESOURCES)
            .setFreshnessIntervalMillis(15 * 60_000L)
            .setTileTimeline(TimelineBuilders.Timeline.fromLayoutElement(layout(k)))
            .build()
    }

    override fun onTileResourcesRequest(requestParams: RequestBuilders.ResourcesRequest): ListenableFuture<ResourceBuilders.Resources> =
        scope.future { ResourceBuilders.Resources.Builder().setVersion(RESOURCES).build() }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun layout(k: Kitzi): LayoutElementBuilders.LayoutElement {
        val np = k.player.nowPlaying.value
        val book = np?.book ?: k.shelf.value.firstOrNull()
        val playing = k.player.wantsPlay.value
        val open = ModifiersBuilders.Clickable.Builder()
            .setId("open")
            .setOnClick(
                ActionBuilders.LaunchAction.Builder().setAndroidActivity(
                    ActionBuilders.AndroidActivity.Builder()
                        .setPackageName(packageName)
                        .setClassName(MainActivity::class.java.name)
                        .build()
                ).build()
            ).build()
        val column = LayoutElementBuilders.Column.Builder()
            .setHorizontalAlignment(LayoutElementBuilders.HORIZONTAL_ALIGN_CENTER)
        if (book == null) {
            column.addContent(text(if (k.store.signedIn) "Nothing in progress" else "Sign in on the watch", 14f, WHITE))
        } else {
            val pos = if (np != null) k.player.positionSec() ?: book.currentTimeSec else book.currentTimeSec
            val total = np?.totalSec ?: book.durationSec
            val pct = if (total > 0) "${(pos / total * 100).toInt()}%" else ""
            column.addContent(
                LayoutElementBuilders.Box.Builder()
                    .setModifiers(ModifiersBuilders.Modifiers.Builder().setClickable(open).build())
                    .addContent(text(book.title, 15f, WHITE, maxLines = 2))
                    .build()
            )
            column.addContent(text(listOf(pct, if (playing) "Playing" else "Paused").filter { it.isNotEmpty() }.joinToString(" · "), 12f, GREY))
            column.addContent(LayoutElementBuilders.Spacer.Builder().setHeight(dp(10f)).build())
            column.addContent(
                LayoutElementBuilders.Box.Builder()
                    .setWidth(dp(56f)).setHeight(dp(56f))
                    .setModifiers(
                        ModifiersBuilders.Modifiers.Builder()
                            .setBackground(
                                ModifiersBuilders.Background.Builder()
                                    .setColor(argb(ACCENT))
                                    .setCorner(ModifiersBuilders.Corner.Builder().setRadius(dp(28f)).build())
                                    .build()
                            )
                            .setClickable(
                                ModifiersBuilders.Clickable.Builder()
                                    .setId(TOGGLE)
                                    .setOnClick(ActionBuilders.LoadAction.Builder().build())
                                    .build()
                            )
                            .build()
                    )
                    .addContent(text(if (playing) "❚❚" else "▶", 22f, DARK))
                    .build()
            )
        }
        return LayoutElementBuilders.Box.Builder()
            .setWidth(expand()).setHeight(expand())
            .addContent(column.build())
            .build()
    }

    private fun text(s: String, size: Float, color: Int, maxLines: Int = 1) =
        LayoutElementBuilders.Text.Builder()
            .setText(s)
            .setMaxLines(maxLines)
            .setFontStyle(LayoutElementBuilders.FontStyle.Builder().setSize(sp(size)).setColor(argb(color)).build())
            .build()

    companion object {
        private const val TOGGLE = "toggle"
        private const val RESOURCES = "1"
        private const val WHITE = 0xFFFFFFFF.toInt()
        private const val GREY = 0xFFB0B0B0.toInt()
        private const val DARK = 0xFF1B1B1F.toInt()
        private const val ACCENT = 0xFFB4C5FF.toInt()

        /** Asks the system to redraw the tile (playback started, paused or stopped). */
        fun refresh(context: Context) {
            runCatching { getUpdater(context).requestUpdate(PlayerTile::class.java) }
        }
    }
}
