package com.bennybar.kitzi.wear.ui

import android.app.Activity
import android.app.RemoteInput
import android.content.Context
import android.media.AudioManager
import android.view.inputmethod.EditorInfo
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.focusable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Smartphone
import androidx.compose.material.icons.filled.Sync
import androidx.compose.material.icons.filled.Watch
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.input.rotary.onRotaryScrollEvent
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.FilledIconButton
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.IconButton
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.SwitchButton
import androidx.wear.compose.material3.Text
import androidx.wear.input.RemoteInputIntentHelper
import androidx.wear.input.wearableExtender
import coil.compose.AsyncImage
import com.bennybar.kitzi.wear.Api
import com.bennybar.kitzi.wear.Book
import com.bennybar.kitzi.wear.DownloadState
import com.bennybar.kitzi.wear.Kitzi
import com.bennybar.kitzi.wear.PhoneLogin
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull

// ---- sign in ---------------------------------------------------------------------

@Composable
fun LoginScreen(k: Kitzi) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var message by remember { mutableStateOf<String?>(null) }
    var busy by remember { mutableStateOf(false) }
    var server by remember { mutableStateOf("") }
    var user by remember { mutableStateOf("") }

    // Signing in on the watch: three text prompts in a row, then the login.
    val askPassword = rememberTextInput("Password") { password ->
        busy = true
        message = "Signing in…"
        scope.launch {
            val result = withContext(Dispatchers.IO) { k.api.login(server, user, password) }
            busy = false
            message = when (result) {
                Api.LoginResult.OK -> { k.signedIn.value = true; null }
                Api.LoginResult.WRONG_CREDENTIALS -> "Wrong username or password"
                Api.LoginResult.UNREACHABLE -> "Can't reach $server"
                Api.LoginResult.NOT_ABS -> "That doesn't look like an Audiobookshelf server"
            }
        }
    }
    val askUser = rememberTextInput("Username") { user = it; askPassword() }
    val askServer = rememberTextInput("Server URL") { server = it; askUser() }

    LaunchedEffect(Unit) {
        PhoneLogin.replies.collect { error ->
            busy = false
            message = error
        }
    }

    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Kitzi") } }
            item {
                Button(
                    onClick = {
                        busy = true
                        message = "Check your phone…"
                        scope.launch {
                            if (!PhoneLogin.request(context)) {
                                busy = false
                                message = "No phone with Kitzi nearby. Sign in on the watch instead."
                            } else {
                                // The phone answers in a second or two; give up after 20 s.
                                delay(20_000)
                                if (busy && !k.signedIn.value) {
                                    busy = false
                                    message = "The phone didn't answer. Open Kitzi on it and try again."
                                }
                            }
                        }
                    },
                    enabled = !busy,
                    icon = { Icon(Icons.Default.Smartphone, null) },
                    label = { Text("Sign in with phone") },
                    secondaryLabel = { Text("Uses Kitzi on your phone") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                FilledTonalButton(
                    onClick = { askServer() },
                    enabled = !busy,
                    icon = { Icon(Icons.Default.Watch, null) },
                    label = { Text("Sign in on watch") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            message?.let { m ->
                item {
                    Text(m, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall,
                        modifier = Modifier.padding(top = 6.dp))
                }
            }
        }
    }
}

/** A text prompt using the watch's input methods (keyboard, voice); returns a launcher. */
@Composable
private fun rememberTextInput(label: String, onResult: (String) -> Unit): () -> Unit {
    val launcher = rememberLauncherForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        if (result.resultCode != Activity.RESULT_OK) return@rememberLauncherForActivityResult
        val text = result.data?.let { RemoteInput.getResultsFromIntent(it) }?.getCharSequence(label)?.toString()?.trim()
        if (!text.isNullOrEmpty()) onResult(text)
    }
    return {
        val intent = RemoteInputIntentHelper.createActionRemoteInputIntent()
        val input = RemoteInput.Builder(label).setLabel(label)
            .wearableExtender { setEmojisAllowed(false); setInputActionType(EditorInfo.IME_ACTION_DONE) }
            .build()
        RemoteInputIntentHelper.putRemoteInputsExtra(intent, listOf(input))
        launcher.launch(intent)
    }
}

// ---- home: Continue Listening ----------------------------------------------------

@Composable
fun HomeScreen(k: Kitzi, onOpenBook: (String) -> Unit, onOpenPlayer: () -> Unit, onOpenSettings: () -> Unit) {
    val shelf by k.shelf.collectAsState()
    val refreshing by k.refreshing.collectAsState()
    val online by k.online.collectAsState()
    val nowPlaying by k.player.nowPlaying.collectAsState()
    val downloads by k.downloads.states.collectAsState()
    val scope = rememberCoroutineScope()
    var syncResult by remember { mutableStateOf<String?>(null) }
    var syncing by remember { mutableStateOf(false) }

    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Continue Listening") } }
            nowPlaying?.let { np ->
                item {
                    Button(
                        onClick = onOpenPlayer,
                        icon = { Icon(Icons.Default.PlayArrow, null) },
                        label = { Text(np.book.title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                        secondaryLabel = { Text("Now playing") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            if (shelf.isEmpty()) {
                item {
                    Text(
                        when {
                            refreshing -> "Loading…"
                            online == false -> "Offline, and nothing saved yet"
                            else -> "Nothing in progress"
                        },
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(8.dp),
                    )
                }
            }
            shelf.forEach { book ->
                item(key = book.id) {
                    FilledTonalButton(
                        onClick = { onOpenBook(book.id) },
                        icon = { Cover(k, book.id, 32) },
                        label = { Text(book.title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        secondaryLabel = { Text(bookLine(book, downloads[book.id])) },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            item {
                Button(
                    onClick = {
                        syncing = true
                        scope.launch {
                            val ok = k.syncNow()
                            syncing = false
                            syncResult = if (ok) "All synced" else "Offline · will sync later"
                        }
                    },
                    enabled = !syncing,
                    icon = {
                        if (syncing) CircularProgressIndicator(Modifier.size(24.dp))
                        else Icon(Icons.Default.Sync, null)
                    },
                    label = { Text("Sync now") },
                    secondaryLabel = syncResult?.let { { Text(it) } },
                    modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                )
            }
            item {
                FilledTonalButton(
                    onClick = onOpenSettings,
                    icon = { Icon(Icons.Default.Settings, null) },
                    label = { Text("Settings") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

private fun bookLine(book: Book, download: DownloadState?): String {
    val pct = if (book.durationSec > 0) "${(book.currentTimeSec / book.durationSec * 100).toInt()}%" else ""
    val dl = when (download) {
        DownloadState.Done -> " · on watch"
        is DownloadState.Running -> " · ${(download.fraction * 100).toInt()}% downloaded"
        DownloadState.Waiting -> " · " + waitingLabel(Kitzi.get).lowercase()
        else -> ""
    }
    return pct + dl
}

@Composable
private fun Cover(k: Kitzi, itemId: String, sizeDp: Int) {
    val model: Any? = k.downloads.coverFile(itemId) ?: runCatching { k.api.coverUrl(itemId) }.getOrNull()
    AsyncImage(
        model = model,
        contentDescription = null,
        contentScale = ContentScale.Crop,
        modifier = Modifier.size(sizeDp.dp).clip(CircleShape),
    )
}

// ---- a book ----------------------------------------------------------------------

@Composable
fun BookScreen(k: Kitzi, itemId: String, onPlaying: () -> Unit) {
    val shelf by k.shelf.collectAsState()
    val downloads by k.downloads.states.collectAsState()
    val loading by k.player.loading.collectAsState()
    val book = shelf.firstOrNull { it.id == itemId } ?: k.downloads.downloaded(itemId)?.book ?: return
    val download = downloads[itemId] ?: DownloadState.None
    val scope = rememberCoroutineScope()
    var error by remember { mutableStateOf<String?>(null) }
    var confirmRemove by remember { mutableStateOf(false) }

    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { Cover(k, itemId, 64) }
            item {
                Text(book.title, textAlign = TextAlign.Center, maxLines = 3, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.titleMedium)
            }
            book.author?.let { item { Text(it, style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center) } }
            if (book.durationSec > 0) {
                item {
                    Text("${clock(book.currentTimeSec)} of ${clock(book.durationSec)}",
                        style = MaterialTheme.typography.bodySmall)
                }
            }
            item {
                Button(
                    onClick = {
                        error = null
                        scope.launch {
                            val problem = k.player.play(book)
                            if (problem == null) onPlaying() else error = problem
                        }
                    },
                    enabled = !loading,
                    icon = {
                        if (loading) CircularProgressIndicator(Modifier.size(24.dp))
                        else Icon(Icons.Default.PlayArrow, null)
                    },
                    label = { Text(if (book.currentTimeSec > 0) "Resume" else "Play") },
                    secondaryLabel = { Text(if (download == DownloadState.Done) "From watch" else "Streaming") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            error?.let { item { Text(it, textAlign = TextAlign.Center, style = MaterialTheme.typography.bodySmall) } }
            item {
                when (download) {
                    DownloadState.Done -> FilledTonalButton(
                        onClick = {
                            if (confirmRemove) { k.downloads.delete(itemId); confirmRemove = false } else confirmRemove = true
                        },
                        icon = { Icon(Icons.Default.DownloadDone, null) },
                        label = { Text(if (confirmRemove) "Tap again to remove" else "Remove download") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    is DownloadState.Running, DownloadState.Waiting -> FilledTonalButton(
                        onClick = { k.downloads.cancel(itemId) },
                        icon = {
                            if (download is DownloadState.Running) CircularProgressIndicator(progress = { download.fraction }, modifier = Modifier.size(24.dp))
                            else CircularProgressIndicator(Modifier.size(24.dp))
                        },
                        label = {
                            Text(if (download is DownloadState.Running) "Downloading ${(download.fraction * 100).toInt()}%" else waitingLabel(k))
                        },
                        secondaryLabel = { Text("Tap to cancel") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                    else -> FilledTonalButton(
                        onClick = { k.downloads.start(itemId) },
                        icon = { Icon(Icons.Default.Download, null) },
                        label = { Text(if (download == DownloadState.Failed) "Retry download" else "Download") },
                        secondaryLabel = { Text(if (k.store.wifiOnly) "Over Wi-Fi" else "Over Wi-Fi or LTE") },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
        }
    }
}

// ---- player ----------------------------------------------------------------------

@Composable
fun PlayerScreen(k: Kitzi) {
    val np by k.player.nowPlaying.collectAsState()
    val playing by k.player.isPlaying.collectAsState()
    val status by k.player.status.collectAsState()
    val book = np ?: run {
        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Text("Nothing playing") }
        return
    }
    val scope = rememberCoroutineScope()
    var position by remember { mutableDoubleStateOf(0.0) }
    var chapter by remember { mutableStateOf<String?>(null) }
    var syncing by remember { mutableStateOf(false) }
    LaunchedEffect(book.book.id) {
        while (true) {
            position = k.player.positionSec() ?: 0.0
            chapter = k.player.chapterTitle()
            delay(1000)
        }
    }

    // The crown / bezel changes the volume, as in every Wear OS media app.
    val context = LocalContext.current
    val audio = remember { context.getSystemService(Context.AUDIO_SERVICE) as AudioManager }
    val focus = remember { FocusRequester() }
    var rotary by remember { mutableDoubleStateOf(0.0) }
    LaunchedEffect(Unit) { focus.requestFocus() }

    val total = book.totalSec
    Box(
        Modifier.fillMaxSize()
            .onRotaryScrollEvent {
                rotary += it.verticalScrollPixels
                if (kotlin.math.abs(rotary) > 40) {
                    audio.adjustStreamVolume(
                        AudioManager.STREAM_MUSIC,
                        if (rotary > 0) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                        AudioManager.FLAG_SHOW_UI,
                    )
                    rotary = 0.0
                }
                true
            }
            .focusRequester(focus)
            .focusable(),
        contentAlignment = Alignment.Center,
    ) {
        // The book's progress around the edge of the screen.
        // The book's progress around the edge, drawn directly: the stock indicator
        // stayed empty for a paused book.
        val fraction = if (total > 0) (position / total).toFloat().coerceIn(0f, 1f) else 0f
        val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.15f)
        val fill = MaterialTheme.colorScheme.primary
        Canvas(Modifier.fillMaxSize().padding(4.dp)) {
            val stroke = Stroke(width = 4.dp.toPx(), cap = StrokeCap.Round)
            drawArc(track, 0f, 360f, useCenter = false, style = stroke)
            if (fraction > 0f) drawArc(fill, -90f, 360f * fraction, useCenter = false, style = stroke)
        }
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.padding(horizontal = 22.dp)) {
            Text(book.book.title, maxLines = 1, overflow = TextOverflow.Ellipsis,
                style = MaterialTheme.typography.titleSmall, textAlign = TextAlign.Center)
            chapter?.let {
                Text(it, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
            }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                IconButton(onClick = { k.player.skip(-30.0) }) { Icon(Icons.Default.Replay30, "Back 30 seconds") }
                FilledIconButton(onClick = { k.player.togglePlay() }, modifier = Modifier.size(56.dp)) {
                    Icon(if (playing) Icons.Default.Pause else Icons.Default.PlayArrow, if (playing) "Pause" else "Play",
                        modifier = Modifier.size(32.dp))
                }
                IconButton(onClick = { k.player.skip(30.0) }) { Icon(Icons.Default.Forward30, "Forward 30 seconds") }
            }
            Text("${clock(position)} / ${clock(total)}", style = MaterialTheme.typography.bodySmall)
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                IconButton(onClick = {
                    audio.adjustStreamVolume(AudioManager.STREAM_MUSIC, AudioManager.ADJUST_SAME, AudioManager.FLAG_SHOW_UI)
                }) { Icon(Icons.AutoMirrored.Filled.VolumeUp, "Volume") }
                IconButton(
                    onClick = {
                        syncing = true
                        scope.launch { withTimeoutOrNull(30_000) { k.syncNow() }; syncing = false }
                    },
                    enabled = !syncing,
                ) {
                    if (syncing) CircularProgressIndicator(Modifier.size(20.dp)) else Icon(Icons.Default.Sync, "Sync now")
                }
            }
        }
        // Below the controls, so a message doesn't push the title under the clock.
        status?.let {
            Text(
                it,
                style = MaterialTheme.typography.labelSmall,
                textAlign = TextAlign.Center,
                maxLines = 1,
                modifier = Modifier.align(Alignment.BottomCenter).padding(start = 48.dp, end = 48.dp, bottom = 26.dp),
            )
        }
    }
}

// ---- settings --------------------------------------------------------------------

@Composable
fun SettingsScreen(k: Kitzi) {
    val scope = rememberCoroutineScope()
    var wifiOnly by remember { mutableStateOf(k.store.wifiOnly) }
    var confirmSignOut by remember { mutableStateOf(false) }
    val used = remember { k.downloads.usedBytes() }
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Settings") } }
            item {
                SwitchButton(
                    checked = wifiOnly,
                    onCheckedChange = { wifiOnly = it; k.store.wifiOnly = it },
                    label = { Text("Wi-Fi only") },
                    secondaryLabel = { Text(if (wifiOnly) "Downloads skip LTE" else "Downloads use Wi-Fi or LTE") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Text("Downloads use ${"%.0f".format(used / 1_048_576.0)} MB", style = MaterialTheme.typography.bodySmall)
            }
            item {
                Text(
                    listOfNotNull(k.store.username, k.store.baseUrl?.removePrefix("https://")).joinToString("\n"),
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.Center,
                )
            }
            item {
                FilledTonalButton(
                    onClick = {
                        if (!confirmSignOut) confirmSignOut = true
                        else scope.launch { k.signOut() }
                    },
                    label = { Text(if (confirmSignOut) "Tap again to sign out" else "Sign out") },
                    secondaryLabel = { Text("Downloads stay on the watch") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

private fun waitingLabel(k: Kitzi) = if (k.store.wifiOnly) "Waiting for Wi-Fi" else "Waiting for Wi-Fi/LTE"

private fun clock(sec: Double): String {
    val s = sec.toLong().coerceAtLeast(0)
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s / 60 % 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
