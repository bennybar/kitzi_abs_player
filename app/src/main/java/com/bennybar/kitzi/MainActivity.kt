package com.bennybar.kitzi

import android.content.ComponentName
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.asPaddingValues
import androidx.compose.foundation.layout.calculateEndPadding
import androidx.compose.foundation.layout.calculateStartPadding
import androidx.compose.foundation.layout.navigationBars
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.luminance
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.input.pointer.pointerInput
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
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : ComponentActivity() {

    // Retained so the controller (and the service binding it holds) is released in
    // onDestroy instead of being leaked — the future was previously dropped on the
    // floor, leaving a dangling controller for the lifetime of the process.
    private var controllerFuture: com.google.common.util.concurrent.ListenableFuture<MediaController>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        Services.init(this)
        ThemeState.load(Services.prefs)
        com.bennybar.kitzi.ui.UiPrefsState.load(Services.prefs)

        // Android 13+ needs a runtime grant before ANY notification is posted —
        // without it the Media3 playback notification never appears, so there are
        // no lock-screen / media-pill controls. Ask on first launch.
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.TIRAMISU &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            android.content.pm.PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100)
        }

        // Binding to the session starts the service, so playback, the notification
        // and the app all share one player.
        val token = SessionToken(this, ComponentName(this, PlaybackService::class.java))
        controllerFuture = MediaController.Builder(this, token).buildAsync().also { future ->
            future.addListener({ /* the session owns the player */ }, MoreExecutors.directExecutor())
        }

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

    override fun onDestroy() {
        controllerFuture?.let { MediaController.releaseFuture(it) }
        controllerFuture = null
        super.onDestroy()
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
    data object Profile : Overlay
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
                            // Fully-rounded to echo the capsule (circular) bar exterior,
                            // rather than the squircle a fixed corner radius produced.
                            .clip(RoundedCornerShape(percent = 50))
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
    // Signed in if there's a base URL and EITHER a still-fresh access token or a
    // refresh token to renew it with. Requiring a fresh access token alone kicked
    // users to the login screen a few hours after launch — the access token's
    // expiry is only a hint, and a valid refresh token means the session lives on.
    var signedIn by remember {
        mutableStateOf(
            Services.auth.baseUrl != null &&
                (Services.session.hasFreshAccessToken(60) || Services.session.refreshToken != null)
        )
    }
    // When the access token is stale but we're still signed in, renew it in the
    // background (off the main thread) so the first API calls carry a fresh token.
    // We never force a logout here: an offline blip must not sign the user out.
    LaunchedEffect(Unit) {
        if (Services.auth.baseUrl != null && !Services.session.hasFreshAccessToken(60)) {
            withContext(Dispatchers.IO) { runCatching { Services.auth.hasValidSession() } }
        }
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

    // When the player isn't a bottom tab it opens as a card that slides up from
    // the mini-player (a full-height bottom sheet), matching the Flutter app.
    var playerCard by remember { mutableStateOf(false) }
    if (playerAsTab) playerCard = false

    val openPlayer = {
        if (playerAsTab) { tab = Tab.PLAYER; overlay = null } else playerCard = true
    }

    val nowPlaying by Services.playback.nowPlaying.collectAsStateWithLifecycle()
    val density = LocalDensity.current
    val layoutDir = LocalLayoutDirection.current
    // The floating bottom bar (mini-player + nav) overlays the content rather than
    // reserving a slot, so the page scrolls behind it and both can be translucent.
    // We measure its height so scroll screens (and the player) can pad clear of it.
    var barHeightPx by remember { mutableIntStateOf(0) }

    // Retains each screen's transient UI state (crucially the library's scroll
    // position) while it's swapped out for an overlay, so returning from a book's
    // detail lands you back where you were instead of scrolled to the top.
    val screenStateHolder = androidx.compose.runtime.saveable.rememberSaveableStateHolder()

    Scaffold(
        // Fills behind the status-bar / camera cutout with the app surface, so that
        // strip is never a mismatched colour.
        containerColor = MaterialTheme.colorScheme.surface,
    ) { insets ->
        val openBook: (String) -> Unit = { overlay = Overlay.BookDetail(it) }
        // The tab player draws its background (gradient or surface) edge to edge —
        // behind the status bar / cutout — and pads its own content.
        val playerIsTabFull = tab == Tab.PLAYER && overlay == null
        // The mini-player hides while the full player is showing, as a tab or card.
        val onPlayer = playerIsTabFull || playerCard
        val miniVisible = nowPlaying != null && !onPlayer

        // Keep the status-bar icons legible: the player card's dark scrim (and the
        // tab player's cover gradient) sit behind the status bar, so use light icons
        // there; otherwise follow the theme. Without this, light-theme dark icons
        // vanish against the scrim and the bar "goes black".
        val view = LocalView.current
        val darkTheme = MaterialTheme.colorScheme.surface.luminance() < 0.5f
        SideEffect {
            val window = (view.context as android.app.Activity).window
            androidx.core.view.WindowCompat.getInsetsController(window, view)
                .isAppearanceLightStatusBars = if (onPlayer) false else !darkTheme
        }
        val barInset = with(density) { barHeightPx.toDp() }
        // Content clears the top system bar always; the bottom is handled by the
        // per-screen bar inset (scroll screens) or the player's own contentPadding.
        val contentInsets = if (playerIsTabFull) PaddingValues() else PaddingValues(
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
            CompositionLocalProvider(LocalMiniPlayerInset provides if (playerIsTabFull) 0.dp else barInset) {
                // Screens cross-fade on change — a quick, snappy transition.
                androidx.compose.animation.Crossfade(
                    targetState = overlay to tab,
                    animationSpec = androidx.compose.animation.core.tween(120),
                    modifier = Modifier.fillMaxSize(),
                    label = "screen",
                ) { (ov, tb) ->
                    val screenKey: Any = when (ov) {
                        is Overlay.BookDetail -> "book:${ov.id}"
                        Overlay.Series -> "ov:series"
                        Overlay.Stats -> "ov:stats"
                        Overlay.Profile -> "ov:profile"
                        null -> "tab:${tb.name}"
                    }
                    screenStateHolder.SaveableStateProvider(screenKey) {
                    Box(Modifier.fillMaxSize().padding(contentInsets)) {
                        when (ov) {
                            is Overlay.BookDetail -> BookDetailScreen(
                                itemId = ov.id,
                                onPlay = openPlayer,
                                onBack = { overlay = null },
                            )

                            Overlay.Series -> SeriesScreen(onOpenBook = openBook, onBack = { overlay = null })

                            Overlay.Stats -> StatsScreen(onBack = { overlay = null })

                            Overlay.Profile -> com.bennybar.kitzi.ui.profile.ProfileScreen(onBack = { overlay = null })

                            null -> when (tb) {
                                Tab.BOOKS -> LibraryScreen(
                                    onOpenBook = openBook,
                                    onOpenSeries = { overlay = Overlay.Series },
                                    onOpenStats = { overlay = Overlay.Stats },
                                    onOpenProfile = { overlay = Overlay.Profile },
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

            // The expand-from-mini-player card: a scrim fades in and a rounded-top
            // card springs up from the bottom carrying the whole player — a smooth,
            // controlled transition. Tap the scrim or press back to collapse.
            AnimatedVisibility(
                visible = playerCard,
                enter = fadeIn(tween(180)),
                exit = fadeOut(tween(180)),
            ) {
                Box(
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.45f))
                        .clickable(
                            interactionSource = remember { MutableInteractionSource() },
                            indication = null,
                        ) { playerCard = false }
                )
            }
            AnimatedVisibility(
                visible = playerCard,
                enter = slideInVertically(
                    animationSpec = spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMediumLow),
                    initialOffsetY = { it },
                ),
                exit = slideOutVertically(animationSpec = tween(220), targetOffsetY = { it }),
                modifier = Modifier.align(Alignment.BottomCenter),
            ) {
                // Pull-down-to-dismiss: the card follows the finger and collapses
                // back to the mini-player when dragged far enough.
                val dragY = remember { Animatable(0f) }
                val dragScope = rememberCoroutineScope()
                Surface(
                    color = MaterialTheme.colorScheme.surface,
                    shape = RoundedCornerShape(topStart = 24.dp, topEnd = 24.dp),
                    shadowElevation = 16.dp,
                    modifier = Modifier
                        .fillMaxSize()
                        .padding(top = insets.calculateTopPadding() + 8.dp)
                        .graphicsLayer { translationY = dragY.value }
                        .pointerInput(Unit) {
                            detectVerticalDragGestures(
                                onDragEnd = {
                                    if (dragY.value > 220f) playerCard = false
                                    else dragScope.launch { dragY.animateTo(0f) }
                                },
                                onVerticalDrag = { _, delta ->
                                    dragScope.launch { dragY.snapTo((dragY.value + delta).coerceAtLeast(0f)) }
                                },
                            )
                        },
                ) {
                    // The player fills the whole card so its gradient reaches the
                    // rounded top edge (no flat band behind the handle). The drag
                    // handle floats over it.
                    Box(Modifier.fillMaxSize()) {
                        PlayerScreen(
                            contentPadding = PaddingValues(
                                top = 22.dp,
                                bottom = WindowInsets.navigationBars.asPaddingValues().calculateBottomPadding() + 6.dp,
                            ),
                        )
                        Box(
                            Modifier
                                .align(Alignment.TopCenter)
                                .padding(top = 8.dp)
                                .size(width = 40.dp, height = 4.dp)
                                .clip(RoundedCornerShape(2.dp))
                                .background(MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.35f)),
                        )
                    }
                }
            }
            // Back navigates WITHIN the app instead of dropping straight to the
            // launcher: collapse the player card, then close an overlay (book detail /
            // series / stats / profile), then fall back to the Books tab. Only when
            // we're already on Books with nothing stacked does the system get back
            // (and exit the app).
            androidx.activity.compose.BackHandler(
                enabled = playerCard || overlay != null || tab != Tab.BOOKS,
            ) {
                when {
                    playerCard -> playerCard = false
                    overlay != null -> overlay = null
                    tab != Tab.BOOKS -> tab = Tab.BOOKS
                }
            }
        }
    }
}
