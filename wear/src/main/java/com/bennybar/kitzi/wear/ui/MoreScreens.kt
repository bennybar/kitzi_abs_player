package com.bennybar.kitzi.wear.ui

import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.Speed
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableLongStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material3.Button
import androidx.wear.compose.material3.CircularProgressIndicator
import androidx.wear.compose.material3.FilledTonalButton
import androidx.wear.compose.material3.Icon
import androidx.wear.compose.material3.ListHeader
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.material3.ScreenScaffold
import androidx.wear.compose.material3.Text
import com.bennybar.kitzi.wear.DownloadState
import com.bennybar.kitzi.wear.Kitzi
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/** The player's More page: speed, sleep timer, chapters, a bookmark, closing the book. */
@Composable
fun MoreScreen(k: Kitzi, onSpeed: () -> Unit, onSleep: () -> Unit, onChapters: () -> Unit, onClosed: () -> Unit) {
    val np by k.player.nowPlaying.collectAsState()
    val sleepAt by k.player.sleepAt.collectAsState()
    val scope = rememberCoroutineScope()
    val view = LocalView.current
    var bookmark by remember { mutableStateOf<String?>(null) }
    var now by remember { mutableLongStateOf(android.os.SystemClock.elapsedRealtime()) }
    LaunchedEffect(sleepAt) { while (sleepAt != null) { now = android.os.SystemClock.elapsedRealtime(); delay(1000) } }
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text(np?.book?.title ?: "Player", maxLines = 1, overflow = TextOverflow.Ellipsis) } }
            item {
                FilledTonalButton(
                    onClick = onSpeed,
                    icon = { Icon(Icons.Default.Speed, null) },
                    label = { Text("Speed") },
                    secondaryLabel = { Text(speedLabel(k.store.speed)) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                FilledTonalButton(
                    onClick = onSleep,
                    icon = { Icon(Icons.Default.Bedtime, null) },
                    label = { Text("Sleep timer") },
                    secondaryLabel = {
                        Text(
                            when (val at = sleepAt) {
                                null -> "Off"
                                -1L -> "End of chapter"
                                else -> "${((at - now) / 60_000 + 1).coerceAtLeast(1)} min left"
                            }
                        )
                    },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            if (!np?.chapters.isNullOrEmpty()) item {
                FilledTonalButton(
                    onClick = onChapters,
                    icon = { Icon(Icons.AutoMirrored.Filled.List, null) },
                    label = { Text("Chapters") },
                    secondaryLabel = { Text("${np?.chapters?.size} chapters") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                FilledTonalButton(
                    onClick = {
                        scope.launch {
                            bookmark = if (k.player.addBookmark()) { haptic(view); "Bookmark added" } else "Couldn't add it (offline?)"
                        }
                    },
                    icon = { Icon(Icons.Default.Bookmark, null) },
                    label = { Text("Add bookmark") },
                    secondaryLabel = bookmark?.let { { Text(it) } },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                FilledTonalButton(
                    onClick = { scope.launch { k.player.stop(); onClosed() } },
                    icon = { Icon(Icons.Default.Close, null) },
                    label = { Text("Close book") },
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}

private val SPEEDS = listOf(0.8f, 0.9f, 1.0f, 1.1f, 1.2f, 1.25f, 1.3f, 1.5f, 1.75f, 2.0f)

private fun speedLabel(s: Float) = (if ((s * 10) % 1f == 0f) "%.1f" else "%.2f").format(s) + "×"

@Composable
fun SpeedScreen(k: Kitzi, onDone: () -> Unit) {
    val current = k.store.speed
    val listState = rememberScalingLazyListState(initialCenterItemIndex = SPEEDS.indexOf(current).coerceAtLeast(0) + 1)
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Speed") } }
            SPEEDS.forEach { s ->
                item {
                    if (s == current) Button(onClick = { onDone() }, label = { Text(speedLabel(s)) }, modifier = Modifier.fillMaxWidth())
                    else FilledTonalButton(onClick = { k.player.setSpeed(s); onDone() }, label = { Text(speedLabel(s)) }, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
fun SleepScreen(k: Kitzi, onDone: () -> Unit) {
    val options = listOf(0 to "Off", 15 to "15 minutes", 30 to "30 minutes", 45 to "45 minutes", 60 to "1 hour", -1 to "End of chapter")
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Sleep timer") } }
            options.forEach { (minutes, label) ->
                if (minutes == -1 && k.player.chapterBounds() == null) return@forEach
                item {
                    FilledTonalButton(onClick = { k.player.sleep(minutes); onDone() }, label = { Text(label) }, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

@Composable
fun ChaptersScreen(k: Kitzi, onDone: () -> Unit) {
    val np by k.player.nowPlaying.collectAsState()
    val chapters = np?.chapters.orEmpty()
    val current = remember { k.player.chapterBounds()?.first ?: 0 }
    val listState = rememberScalingLazyListState(initialCenterItemIndex = current + 1)
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Chapters") } }
            chapters.forEachIndexed { i, c ->
                item {
                    val go = { k.player.seekTo(c.startSec); onDone() }
                    if (i == current) Button(onClick = go, label = { Text(c.title, maxLines = 2, overflow = TextOverflow.Ellipsis) }, modifier = Modifier.fillMaxWidth())
                    else FilledTonalButton(onClick = go, label = { Text(c.title, maxLines = 2, overflow = TextOverflow.Ellipsis) }, modifier = Modifier.fillMaxWidth())
                }
            }
        }
    }
}

/** Everything on the watch: downloaded, downloading, waiting or failed; space used and free. */
@Composable
fun DownloadsScreen(k: Kitzi, onOpenBook: (String) -> Unit) {
    val states by k.downloads.states.collectAsState()
    val shelf by k.shelf.collectAsState()
    val used = remember(states) { k.downloads.usedBytes() }
    val free = remember(states) { k.downloads.freeBytes() }
    val listState = rememberScalingLazyListState()
    ScreenScaffold(scrollState = listState) { padding ->
        ScalingLazyColumn(state = listState, contentPadding = padding, modifier = Modifier.fillMaxSize()) {
            item { ListHeader { Text("Downloads") } }
            val entries = states.filterValues { it != DownloadState.None }.toList()
            if (entries.isEmpty()) item {
                Text("Nothing on the watch yet. Download a book from its page.", textAlign = TextAlign.Center,
                    style = MaterialTheme.typography.bodySmall, modifier = Modifier.padding(8.dp))
            }
            entries.forEach { (id, state) ->
                val title = k.downloads.downloaded(id)?.book?.title ?: shelf.firstOrNull { it.id == id }?.title ?: "Audiobook"
                item(key = id) {
                    FilledTonalButton(
                        onClick = {
                            when {
                                state == DownloadState.Failed -> k.downloads.start(id)
                                // A book's page needs the book: downloaded, or on the shelf.
                                state == DownloadState.Done || shelf.any { it.id == id } -> onOpenBook(id)
                            }
                        },
                        icon = {
                            when (state) {
                                DownloadState.Done -> Icon(Icons.Default.DownloadDone, null)
                                DownloadState.Failed -> Icon(Icons.Default.ErrorOutline, null)
                                is DownloadState.Running -> CircularProgressIndicator(progress = { state.fraction }, modifier = Modifier.size(24.dp))
                                else -> CircularProgressIndicator(Modifier.size(24.dp))
                            }
                        },
                        label = { Text(title, maxLines = 2, overflow = TextOverflow.Ellipsis) },
                        secondaryLabel = {
                            Text(
                                when (state) {
                                    DownloadState.Done -> "On watch"
                                    DownloadState.Failed -> (k.downloads.failReasons[id] ?: "Failed") + " · tap to retry"
                                    is DownloadState.Running -> "${(state.fraction * 100).toInt()}%"
                                    else -> if (k.store.wifiOnly) "Waiting for Wi-Fi" else "Waiting for Wi-Fi/LTE"
                                }
                            )
                        },
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            item {
                Text("${"%.0f".format(used / 1_048_576.0)} MB used · ${"%.1f".format(free / 1_073_741_824.0)} GB free",
                    style = MaterialTheme.typography.bodySmall, textAlign = TextAlign.Center)
            }
        }
    }
}
