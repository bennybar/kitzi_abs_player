package com.bennybar.kitzi

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.navigationBarsPadding
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
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.Color
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalLayoutDirection
import androidx.compose.ui.unit.Density
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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

/**
 * How much bottom space the floating bottom bar (mini-player + nav) occupies over
 * the content, so scrollable screens can pad their last items clear of it.
 */
val LocalMiniPlayerInset = androidx.compose.runtime.staticCompositionLocalOf { 0.dp }

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
 * A Samsung-style floating bottom navigation: a rounded capsule detached from the
 * screen edges, floating over the page content with a soft shadow. The selected
 * tab gets a filled pill behind its icon + label. Because the capsule floats, the
 * region around it (and behind the mini-player above it) is transparent and shows
 * the page, rather than a solid bar.
 */
@Composable
private fun KitziNavBar(tabs: List<Tab>, selected: Tab, overlayOpen: Boolean, onSelect: (Tab) -> Unit) {
    val shape = RoundedCornerShape(32.dp)
    Box(
        Modifier
            .fillMaxWidth()
            .navigationBarsPadding()
            .padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainer,
            shape = shape,
            shadowElevation = 12.dp,
            tonalElevation = 0.dp,
            modifier = Modifier
                .fillMaxWidth()
                .border(
                    width = 0.5.dp,
                    color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                    shape = shape,
                ),
        ) {
            Row(
                Modifier.padding(horizontal = 6.dp, vertical = 8.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                tabs.forEach { t ->
                    val active = selected == t && !overlayOpen
                    val content = if (active) MaterialTheme.colorScheme.onSecondaryContainer
                    else MaterialTheme.colorScheme.onSurfaceVariant
                    Column(
                        Modifier
                            .weight(1f)
                            .clip(RoundedCornerShape(20.dp))
                            .clickable { onSelect(t) }
                            .background(
                                if (active) MaterialTheme.colorScheme.secondaryContainer
                                else Color.Transparent,
                            )
                            .padding(vertical = 7.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                    ) {
                        Icon(t.icon, null, tint = content, modifier = Modifier.size(22.dp))
                        Text(
                            t.label,
                            fontSize = 10.sp,
                            lineHeight = 12.sp,
                            maxLines = 1,
                            color = content,
                            modifier = Modifier.padding(top = 3.dp),
                        )
                    }
                }
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

    val nowPlaying by Services.playback.nowPlaying.collectAsStateWithLifecycle()
    val density = LocalDensity.current
    val layoutDir = LocalLayoutDirection.current
    // The floating bottom bar (mini-player + nav) overlays the content rather than
    // reserving a slot, so the page scrolls behind it and both can be translucent.
    // We measure its height so scroll screens (and the player) can pad clear of it.
    var barHeightPx by remember { mutableIntStateOf(0) }

    Scaffold(
        // Fills behind the status-bar / camera cutout with the app surface, so that
        // strip is never a mismatched colour.
        containerColor = MaterialTheme.colorScheme.surface,
    ) { insets ->
        val openBook: (String) -> Unit = { overlay = Overlay.BookDetail(it) }
        // The player draws its background (gradient or surface) edge to edge —
        // behind the status bar / cutout — and pads its own content.
        val onPlayer = (tab == Tab.PLAYER && overlay == null) || overlay == Overlay.Player
        val miniVisible = nowPlaying != null && !onPlayer
        val barInset = with(density) { barHeightPx.toDp() }
        // Content clears the top system bar always; the bottom is handled by the
        // per-screen bar inset (scroll screens) or the player's own contentPadding.
        val contentInsets = if (onPlayer) PaddingValues() else PaddingValues(
            start = insets.calculateStartPadding(layoutDir),
            end = insets.calculateEndPadding(layoutDir),
            top = insets.calculateTopPadding(),
        )
        val playerPadding = PaddingValues(
            start = insets.calculateStartPadding(layoutDir),
            end = insets.calculateEndPadding(layoutDir),
            top = insets.calculateTopPadding(),
            bottom = barInset,
        )

        Box(Modifier.fillMaxSize()) {
            CompositionLocalProvider(LocalMiniPlayerInset provides if (onPlayer) 0.dp else barInset) {
                Box(Modifier.fillMaxSize().padding(contentInsets)) {
                    when (val current = overlay) {
                        is Overlay.BookDetail -> BookDetailScreen(
                            itemId = current.id,
                            onPlay = openPlayer,
                            onBack = { overlay = null },
                        )

                        Overlay.Series -> SeriesScreen(onOpenBook = openBook, onBack = { overlay = null })

                        Overlay.Stats -> StatsScreen(onBack = { overlay = null })

                        Overlay.Player -> PlayerScreen(contentPadding = playerPadding)

                        null -> when (tab) {
                            Tab.BOOKS -> LibraryScreen(
                                onOpenBook = openBook,
                                onOpenSeries = { overlay = Overlay.Series },
                                onOpenStats = { overlay = Overlay.Stats },
                            )
                            Tab.SERIES -> SeriesScreen(onOpenBook = openBook, onBack = { tab = Tab.BOOKS })
                            Tab.AUTHORS -> AuthorsScreen(onOpenBook = openBook)
                            Tab.QUEUE -> QueueScreen(onOpenPlayer = openPlayer)
                            Tab.PLAYER -> PlayerScreen(contentPadding = playerPadding)
                            Tab.DOWNLOADS -> DownloadsScreen(onOpenBook = openBook)
                            Tab.SETTINGS -> SettingsScreen(onSignedOut = { signedIn = false })
                        }
                    }
                }
            }

            // The floating cluster: mini-player above the nav, both over content.
            Column(
                Modifier
                    .align(Alignment.BottomCenter)
                    .fillMaxWidth()
                    .onGloballyPositioned { barHeightPx = it.size.height },
            ) {
                if (miniVisible) MiniPlayer(onExpand = openPlayer)
                KitziNavBar(
                    tabs = tabs,
                    selected = tab,
                    overlayOpen = overlay != null,
                    onSelect = { tab = it; overlay = null },
                )
            }
        }
    }
}
