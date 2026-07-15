package com.bennybar.kitzi

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.border
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.ui.UiPrefsState
import com.bennybar.kitzi.playback.PlaybackService
import com.bennybar.kitzi.ui.browse.AuthorsScreen
import com.bennybar.kitzi.ui.browse.SeriesScreen
import com.bennybar.kitzi.ui.detail.BookDetailScreen
import com.bennybar.kitzi.ui.downloads.DownloadsScreen
import com.bennybar.kitzi.ui.library.LibraryScreen
import com.bennybar.kitzi.ui.login.LoginScreen
import com.bennybar.kitzi.ui.player.MiniPlayer
import com.bennybar.kitzi.ui.player.PlayerScreen
import com.bennybar.kitzi.ui.queue.QueueScreen
import com.bennybar.kitzi.ui.settings.SettingsScreen
import com.bennybar.kitzi.ui.stats.StatsScreen
import com.bennybar.kitzi.ui.theme.KitziTheme
import com.bennybar.kitzi.ui.theme.ThemeMode
import com.bennybar.kitzi.ui.theme.ThemeState
import com.google.common.util.concurrent.MoreExecutors

class MainActivity : ComponentActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        Services.init(this)
        ThemeState.load(Services.prefs)
        com.bennybar.kitzi.ui.UiPrefsState.load(Services.prefs)

        // Binding to the session starts the service, so playback, the notification
        // and the app all share one player.
        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        MediaController.Builder(this, token).buildAsync()
            .addListener({ /* the session owns the player */ }, MoreExecutors.directExecutor())

        setContent {
            val mode by ThemeState.mode
            val dark = when (mode) {
                ThemeMode.DARK -> true
                ThemeMode.LIGHT -> false
                ThemeMode.SYSTEM -> isSystemInDarkTheme()
            }

            // Apply the user's font-scale setting app-wide, as the Flutter app does
            // by scaling the MediaQuery textScaler.
            val fontScale = ThemeState.fontScale
            val density = LocalDensity.current
            CompositionLocalProvider(
                LocalDensity provides Density(density.density, fontScale)
            ) {
                KitziTheme(darkTheme = dark) { App() }
            }
        }
    }
}

/** Every possible tab. Which ones actually show is decided by the settings. */
private enum class Tab(val label: String, val icon: ImageVector) {
    BOOKS("Books", Icons.Default.LibraryBooks),
    SERIES("Series", Icons.Default.Bookmarks),
    AUTHORS("Authors", Icons.Default.Person),
    QUEUE("Queue", Icons.AutoMirrored.Filled.QueueMusic),
    PLAYER("Player", Icons.Default.PlayArrow),
    DOWNLOADS("Downloads", Icons.Default.Download),
    SETTINGS("Settings", Icons.Default.Settings),
}

/** What is stacked on top of the current tab, if anything. */
private sealed interface Overlay {
    data class BookDetail(val id: String) : Overlay
    data object Series : Overlay
    data object Stats : Overlay
    /** The full player shown as an overlay when it isn't a bottom tab. */
    data object Player : Overlay
}

/**
 * The bottom navigation bar: the standard Material 3 NavigationBar, wrapped in a
 * surfaceContainerHigh surface with 28dp rounded top corners and a hairline top
 * border to match the Flutter app. NavigationBar handles the system-gesture inset
 * itself.
 */
@Composable
private fun KitziNavBar(tabs: List<Tab>, selected: Tab, overlayOpen: Boolean, onSelect: (Tab) -> Unit) {
    val topShape = RoundedCornerShape(topStart = 28.dp, topEnd = 28.dp)
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = topShape,
        // A soft top shadow so the rounded top reads as a raised sheet floating
        // over the page, rather than a gap where the page shows through the corners.
        shadowElevation = 10.dp,
        modifier = Modifier
            .fillMaxWidth()
            .border(
                width = 0.5.dp,
                color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                shape = topShape,
            ),
    ) {
        NavigationBar(
            containerColor = Color.Transparent,
            tonalElevation = 0.dp,
        ) {
            tabs.forEach { t ->
                NavigationBarItem(
                    selected = selected == t && !overlayOpen,
                    onClick = { onSelect(t) },
                    icon = { Icon(t.icon, null, modifier = Modifier.size(22.dp)) },
                    label = {
                        // A small fixed size that fits "Downloads"/"Settings" across
                        // six or seven tabs without clipping.
                        Text(
                            t.label,
                            fontSize = 10.sp,
                            lineHeight = 12.sp,
                            maxLines = 1,
                        )
                    },
                )
            }
        }
    }
}

@Composable
private fun App() {
    var signedIn by remember {
        mutableStateOf(Services.auth.baseUrl != null && Services.session.hasFreshAccessToken(60))
    }
    var tab by remember { mutableStateOf(Tab.BOOKS) }
    var overlay by remember { mutableStateOf<Overlay?>(null) }

    if (!signedIn) {
        Scaffold(Modifier.fillMaxSize()) { insets ->
            Box(Modifier.fillMaxSize().padding(insets)) {
                LoginScreen(onSignedIn = { signedIn = true })
            }
        }
        return
    }

    // The visible tabs follow the Appearance settings, live.
    val showAuthors by UiPrefsState.showAuthorsTab
    val showSeries by UiPrefsState.showSeriesTab
    val playerAsTab by UiPrefsState.fullPlayerAsTab
    val tabs = remember(showAuthors, showSeries, playerAsTab) {
        buildList {
            add(Tab.BOOKS)
            if (showSeries) add(Tab.SERIES)
            if (showAuthors) add(Tab.AUTHORS)
            add(Tab.QUEUE)
            if (playerAsTab) add(Tab.PLAYER)
            add(Tab.DOWNLOADS)
            add(Tab.SETTINGS)
        }
    }
    // If the current tab was just hidden, fall back to Books.
    if (tab !in tabs) tab = Tab.BOOKS

    val openPlayer = {
        if (playerAsTab) { tab = Tab.PLAYER; overlay = null } else overlay = Overlay.Player
    }

    Scaffold(
        // Fills behind the status-bar / camera cutout with the app surface, so that
        // strip is never a mismatched colour.
        containerColor = MaterialTheme.colorScheme.surface,
        bottomBar = {
            Column {
                // Above the nav bar everywhere except the full player, which would
                // otherwise show the same controls twice.
                val onPlayer = (tab == Tab.PLAYER && overlay == null) || overlay == Overlay.Player
                if (!onPlayer) {
                    MiniPlayer(onExpand = openPlayer)
                }
                KitziNavBar(
                    tabs = tabs,
                    selected = tab,
                    overlayOpen = overlay != null,
                    onSelect = { tab = it; overlay = null },
                )
            }
        },
    ) { insets ->
        Box(Modifier.fillMaxSize().padding(insets)) {
            val openBook: (String) -> Unit = { overlay = Overlay.BookDetail(it) }

            when (val current = overlay) {
                is Overlay.BookDetail -> BookDetailScreen(
                    itemId = current.id,
                    onPlay = openPlayer,
                    onBack = { overlay = null },
                )

                Overlay.Series -> SeriesScreen(onOpenBook = openBook, onBack = { overlay = null })

                Overlay.Stats -> StatsScreen(onBack = { overlay = null })

                Overlay.Player -> PlayerScreen()

                null -> when (tab) {
                    Tab.BOOKS -> LibraryScreen(
                        onOpenBook = openBook,
                        onOpenSeries = { overlay = Overlay.Series },
                        onOpenStats = { overlay = Overlay.Stats },
                    )
                    Tab.SERIES -> SeriesScreen(onOpenBook = openBook, onBack = { tab = Tab.BOOKS })
                    Tab.AUTHORS -> AuthorsScreen(onOpenBook = openBook)
                    Tab.QUEUE -> QueueScreen(onOpenPlayer = openPlayer)
                    Tab.PLAYER -> PlayerScreen()
                    Tab.DOWNLOADS -> DownloadsScreen(onOpenBook = openBook)
                    Tab.SETTINGS -> SettingsScreen(onSignedOut = { signedIn = false })
                }
            }
        }
    }
}
