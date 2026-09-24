package com.bennybar.kitzi.ui.detail

import androidx.compose.material.icons.automirrored.filled.PlaylistPlay
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.AssistChip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Bookmark
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.DownloadStatus
import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.downloads.ItemDownload
import com.bennybar.kitzi.playback.QueueEntry
import com.bennybar.kitzi.ui.common.formatHm
import com.bennybar.kitzi.ui.common.formatSize
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookDetailScreen(itemId: String, onPlay: () -> Unit, onBack: () -> Unit) {
    var book by remember { mutableStateOf<Book?>(null) }
    var download by remember { mutableStateOf<ItemDownload?>(null) }
    var progress by remember { mutableStateOf<MediaProgressEntity?>(null) }
    var bookmarks by remember { mutableStateOf<List<Bookmark>>(emptyList()) }
    var showInfo by remember { mutableStateOf(false) }
    var showCancelConfirm by remember { mutableStateOf(false) }
    var showRemoveConfirm by remember { mutableStateOf(false) }
    var confirmFinished by remember { mutableStateOf(false) }
    var finishedFailed by remember { mutableStateOf(false) }
    var playFailed by remember { mutableStateOf(false) }
    var notFound by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(itemId) {
        val loaded = Services.books.getBook(itemId)
        book = loaded
        // Distinguish "still loading" from "this book isn't there", so a missing book
        // shows an explanation and a way out instead of an endless spinner.
        notFound = loaded == null
        progress = Services.books.progressFor(itemId)
        bookmarks = runCatching { Services.books.bookmarks(itemId) }.getOrDefault(emptyList())
    }
    LaunchedEffect(itemId) {
        Services.downloads.watch(itemId).collect { download = it }
    }

    val b = book
    if (b == null) {
        Column(
            Modifier.fillMaxSize().padding(32.dp),
            verticalArrangement = Arrangement.Center,
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            if (notFound) {
                Text("Book unavailable", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    "It may have been removed from the server, or it hasn't finished syncing yet.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    modifier = Modifier.padding(top = 8.dp),
                )
                TextButton(onClick = onBack, modifier = Modifier.padding(top = 8.dp)) { Text("Go back") }
            } else {
                CircularProgressIndicator()
            }
        }
        return
    }

    if (confirmFinished) {
        val isFinished = progress?.isFinished == true
        AlertDialog(
            onDismissRequest = { confirmFinished = false },
            title = { Text(if (isFinished) "Mark as unfinished?" else "Mark as finished?") },
            text = {
                Text(
                    if (isFinished) {
                        "This clears the finished mark and resets your position to the start, here and on the server."
                    } else {
                        // Both consequences are worth stating: it is not undoable by
                        // simply pressing play, and it stops the book you're hearing.
                        "This marks the book finished here and on the server. If it's playing, playback stops."
                    }
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmFinished = false
                    scope.launch {
                        val before = progress
                        val ok = if (isFinished) Services.books.markUnfinished(itemId)
                                 else Services.books.markFinished(itemId)
                        if (!ok) finishedFailed = true
                        progress = Services.books.progressFor(itemId)
                        // Undo puts back the exact previous state — position included,
                        // which a plain "mark unfinished" would reset to the start.
                        if (ok) com.bennybar.kitzi.ui.common.Snackbars.show(
                            if (isFinished) "Marked as unfinished" else "Marked as finished", "Undo",
                        ) {
                            scope.launch {
                                if (Services.books.restoreProgress(before, itemId)) {
                                    progress = Services.books.progressFor(itemId)
                                } else {
                                    com.bennybar.kitzi.ui.common.Snackbars.show("Couldn't undo — check your connection")
                                }
                            }
                        }
                    }
                }) { Text(if (isFinished) "Mark as unfinished" else "Mark as finished") }
            },
            dismissButton = { TextButton(onClick = { confirmFinished = false }) { Text("Cancel") } },
        )
    }

    if (finishedFailed) {
        AlertDialog(
            onDismissRequest = { finishedFailed = false },
            title = { Text("Couldn't update the server") },
            text = { Text("Nothing was changed. Check your connection and try again.") },
            confirmButton = { TextButton(onClick = { finishedFailed = false }) { Text("OK") } },
        )
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Book details", fontWeight = FontWeight.SemiBold) },
            // The screen is already padded below the status bar; the bar's own
            // status-bar inset on top of that left an empty band above the title.
            windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                val isFinished = progress?.isFinished == true
                TextButton(onClick = { confirmFinished = true }) {
                    Text(if (isFinished) "Mark as unfinished" else "Mark as finished")
                }
            },
        )

        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)
                .padding(bottom = com.bennybar.kitzi.LocalMiniPlayerInset.current),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(16.dp)) {
                    Row {
                        AsyncImage(
                            model = b.coverUrl,
                            contentDescription = b.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.size(120.dp).clip(RoundedCornerShape(14.dp)),
                        )
                        Column(Modifier.padding(start = 16.dp)) {
                            Text(
                                b.title,
                                style = MaterialTheme.typography.headlineSmall,
                                fontWeight = FontWeight.SemiBold,
                            )
                            b.author?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.titleMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 4.dp),
                                )
                            }
                            b.narrators.firstOrNull()?.let {
                                Text(
                                    "Narrated by $it",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 6.dp),
                                )
                            }
                            com.bennybar.kitzi.ui.common.AudibleStars(
                                itemId = b.id,
                                title = b.title,
                                author = b.author,
                                narrator = b.narrators.firstOrNull(),
                                durationMs = b.durationMs,
                                modifier = Modifier.padding(top = 8.dp),
                            )
                        }
                    }

                    Row(
                        Modifier.padding(top = 14.dp),
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        b.durationMs?.let {
                            InfoChip(Icons.Default.Schedule, formatHm(it / 1000))
                        }
                        b.sizeBytes?.let {
                            InfoChip(Icons.Default.Storage, formatSize(it))
                        }
                    }
                }
            }

            // Primary actions right under the header, so Resume/Play is reachable
            // without scrolling past the metadata.
            val d = download
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val preparing by Services.playback.preparing.collectAsStateWithLifecycle()
                Button(
                    // Only navigate once the book actually loaded: opening the player
                    // after a failed load leaves the user staring at whatever was
                    // loaded before — since startup auto-loads the last book, that is
                    // a different book, which reads as "it played the wrong thing".
                    onClick = {
                        scope.launch {
                            if (Services.playback.playItem(itemId)) onPlay() else playFailed = true
                        }
                    },
                    // A slow openSession + sync-before-play can take seconds; disabling
                    // and showing a spinner stops the tap looking like it did nothing.
                    enabled = !preparing,
                    modifier = Modifier.weight(1f),
                ) {
                    if (preparing) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(18.dp),
                            color = MaterialTheme.colorScheme.onPrimary,
                            strokeWidth = 2.dp,
                        )
                        Text("Starting…", modifier = Modifier.padding(start = 8.dp))
                    } else {
                        Icon(Icons.Default.PlayArrow, null)
                        Text(
                            if ((progress?.progress ?: 0.0) > 0) "Resume" else "Play",
                            modifier = Modifier.padding(start = 6.dp),
                        )
                    }
                }
                val downloading = d != null && !d.isComplete &&
                    (d.status == DownloadStatus.RUNNING || d.status == DownloadStatus.QUEUED)
                when {
                    d?.isComplete == true -> OutlinedButton(
                        // Asks first, like the player and Downloads do — one tap used to
                        // delete hundreds of MB.
                        onClick = { showRemoveConfirm = true },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Delete, null)
                        Text("Remove", modifier = Modifier.padding(start = 6.dp))
                    }
                    downloading -> OutlinedButton(
                        onClick = { showCancelConfirm = true },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Close, null)
                        Text("Cancel", modifier = Modifier.padding(start = 6.dp))
                    }
                    else -> OutlinedButton(
                        onClick = {
                            scope.launch {
                                if (!Services.downloads.download(itemId)) {
                                    com.bennybar.kitzi.ui.common.Snackbars.show("Nothing to download: the server lists no audio files for this book")
                                }
                            }
                        },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Download, null)
                        Text("Download", modifier = Modifier.padding(start = 6.dp))
                    }
                }
            }

            ProgressCard(progress, b.durationMs?.let { it / 1000.0 })

            // The description is what people read when deciding, so it comes right
            // after progress (it used to sit below everything, under Bookmarks).
            b.description?.takeIf { it.isNotBlank() }?.let { raw ->
                DescriptionCard(remember(raw) { com.bennybar.kitzi.ui.common.decodeHtml(raw) })
            }

            // One light "details" card: aligned label/value rows (no uneven
            // two-column tiles that stretched when a value wrapped) plus the
            // "More info" entry — lighter, and balanced whatever the value length.
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(Modifier.padding(vertical = 4.dp)) {
                    b.publishYear?.let { DetailRow(Icons.Default.CalendarMonth, "Year", it.toString()) }
                    b.publisher?.let { DetailRow(Icons.Default.Business, "Publisher", it) }
                    // "Audio Book" as a genre just repeats what every book here is.
                    b.genres.filterNot { it.replace(" ", "").equals("audiobook", ignoreCase = true) }
                        .takeIf { it.isNotEmpty() }?.let {
                            DetailRow(Icons.Default.LocalOffer, "Genres", it.joinToString(", "))
                        }
                    HorizontalDivider(
                        Modifier.padding(start = 50.dp),
                        thickness = 0.5.dp,
                        color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.4f),
                    )
                    // "More info": language, ISBN, file type, bitrate, …
                    Row(
                        Modifier.fillMaxWidth().clickable { showInfo = true }
                            .padding(horizontal = 16.dp, vertical = 14.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Info, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text(
                            "More info",
                            style = MaterialTheme.typography.bodyLarge,
                            fontWeight = FontWeight.SemiBold,
                            modifier = Modifier.weight(1f).padding(start = 14.dp),
                        )
                        Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            if (d != null && !d.isComplete && d.status != DownloadStatus.CANCELED) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(20.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(16.dp)) {
                        Text(
                            "Downloading ${(d.progress * 100).toInt()}% · ${d.completedTracks}/${d.totalTracks} tracks",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                        LinearProgressIndicator(
                            progress = { d.progress.toFloat() },
                            modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                        )
                    }
                }
            }

            // One place for the queue (it was also an icon in the top bar), with the
            // "play next" the queue always supported, and a confirmation with Undo.
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                val entry = QueueEntry(b.id, b.title, b.author, b.coverUrl)
                OutlinedButton(
                    onClick = {
                        Services.queue.addNext(entry)
                        com.bennybar.kitzi.ui.common.Snackbars.show("Plays next", "Undo") { Services.queue.remove(b.id) }
                    },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.AutoMirrored.Filled.PlaylistPlay, null)
                    Text("Play next", modifier = Modifier.padding(start = 6.dp))
                }
                OutlinedButton(
                    onClick = {
                        Services.queue.addToBack(entry)
                        com.bennybar.kitzi.ui.common.Snackbars.show("Added to queue", "Undo") { Services.queue.remove(b.id) }
                    },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.AutoMirrored.Filled.QueueMusic, null)
                    Text("Add to queue", modifier = Modifier.padding(start = 6.dp))
                }
            }

            BookmarksCard(
                bookmarks,
                onOpen = { bm ->
                    scope.launch {
                        // Jump there: seek if this book is loaded, else start it first.
                        val loaded = Services.playback.nowPlaying.value?.itemId == itemId
                        if (loaded || Services.playback.playItem(itemId)) {
                            Services.playback.seekGlobal(bm.timeSec)
                            if (!loaded) onPlay()
                        } else playFailed = true
                    }
                },
                onDelete = { bm ->
                    scope.launch {
                        val ok = kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            Services.playbackApi.deleteBookmark(itemId, bm.timeSec)
                        }
                        if (ok) {
                            bookmarks = bookmarks - bm
                            com.bennybar.kitzi.ui.common.Snackbars.show("Bookmark deleted")
                        } else {
                            com.bennybar.kitzi.ui.common.Snackbars.show("Couldn't delete the bookmark")
                        }
                    }
                },
            )

            Spacer(Modifier.height(12.dp))
        }
    }

    if (showInfo) {
        com.bennybar.kitzi.ui.player.PlayerInfoSheet(itemId = itemId, onDismiss = { showInfo = false })
    }

    if (playFailed) {
        AlertDialog(
            onDismissRequest = { playFailed = false },
            title = { Text("Couldn't start this book") },
            text = { Text("The server didn't return a playable stream. Check your connection and try again — downloaded books always play offline.") },
            confirmButton = { TextButton(onClick = { playFailed = false }) { Text("OK") } },
        )
    }

    if (showRemoveConfirm) {
        AlertDialog(
            onDismissRequest = { showRemoveConfirm = false },
            title = { Text("Remove download?") },
            text = { Text("The downloaded files are deleted from this device. You can still stream the book.") },
            confirmButton = {
                TextButton(onClick = {
                    showRemoveConfirm = false
                    scope.launch { Services.downloads.delete(itemId) }
                }) { Text("Remove") }
            },
            dismissButton = { TextButton(onClick = { showRemoveConfirm = false }) { Text("Keep") } },
        )
    }

    if (showCancelConfirm) {
        AlertDialog(
            onDismissRequest = { showCancelConfirm = false },
            title = { Text("Cancel download?") },
            text = { Text("Stop downloading this book? Tracks already downloaded are kept.") },
            confirmButton = {
                TextButton(onClick = {
                    showCancelConfirm = false
                    scope.launch { Services.downloads.cancel(itemId) }
                }) { Text("Cancel download") }
            },
            dismissButton = {
                TextButton(onClick = { showCancelConfirm = false }) { Text("Keep downloading") }
            },
        )
    }
}

@Composable
private fun InfoChip(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    // A non-interactive badge, not AssistChip(onClick = {}): these are facts, and
    // a chip announced them to accessibility services as buttons that do nothing.
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHighest,
        shape = RoundedCornerShape(8.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(label, style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = 8.dp))
        }
    }
}

/** A light metadata row: a small tinted icon, a muted label column, then the value. */
@Composable
private fun DetailRow(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
) {
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Text(
            label,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 14.dp).width(84.dp),
        )
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f).padding(start = 8.dp),
        )
    }
}

@Composable
private fun ProgressCard(progress: MediaProgressEntity?, bookDurationSec: Double?) {
    val fraction = progress?.progress ?: 0.0
    val finished = progress?.isFinished == true
    val duration = progress?.durationSec?.takeIf { it > 0 } ?: bookDurationSec

    val title = when {
        finished -> "Finished"
        fraction > 0 -> "${(fraction * 100).toInt()}% complete"
        else -> "Not started"
    }
    val subtitle = when {
        finished -> "You've listened to the whole book."
        fraction > 0 -> {
            val listened = progress!!.currentTimeSec
            val left = duration?.let { (it - listened).coerceAtLeast(0.0) }
            "${formatHm(listened.toLong())} in" + (left?.let { " · ${formatHm(it.toLong())} left" } ?: "")
        }
        else -> "Start listening to save your progress."
    }

    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            // Only the finished mark: a play glyph here read as a second Play button
            // right under the real one.
            if (finished) {
                Icon(
                    Icons.Default.CheckCircle, null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(30.dp).padding(end = 0.dp),
                )
            }
            Column(Modifier.weight(1f).padding(start = if (finished) 14.dp else 0.dp)) {
                Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (fraction > 0 && !finished) {
                    LinearProgressIndicator(
                        progress = { fraction.toFloat() },
                        modifier = Modifier.fillMaxWidth().padding(top = 8.dp),
                    )
                }
            }
        }
    }
}

@Composable
private fun BookmarksCard(
    bookmarks: List<Bookmark>,
    onOpen: (Bookmark) -> Unit,
    onDelete: (Bookmark) -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp)) {
            Text("Bookmarks", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)

            if (bookmarks.isEmpty()) {
                Row(
                    Modifier.padding(top = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Default.Bookmark,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(22.dp),
                    )
                    Text(
                        "No bookmarks yet. Use the bookmark button in the player to save your spot.",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 10.dp),
                    )
                }
            } else {
                bookmarks.forEach { bm ->
                    Row(
                        Modifier.fillMaxWidth().padding(top = 4.dp)
                            .clip(RoundedCornerShape(10.dp))
                            .clickable { onOpen(bm) }
                            .padding(vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Default.Bookmark,
                            null,
                            tint = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.size(20.dp),
                        )
                        Text(
                            bm.title,
                            style = MaterialTheme.typography.bodyLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f).padding(start = 10.dp),
                        )
                        Text(
                            // Exact time: minutes alone showed "0m" for most bookmarks.
                            com.bennybar.kitzi.ui.player.formatClock(bm.timeSec.toLong()),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        IconButton(onClick = { onDelete(bm) }) {
                            Icon(
                                Icons.Default.Delete, "Delete bookmark",
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.size(20.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

/** The description, collapsed to a few lines with More / Less. */
@Composable
private fun DescriptionCard(text: String) {
    var expanded by remember { mutableStateOf(false) }
    var overflows by remember { mutableStateOf(false) }
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
        onClick = { expanded = !expanded },
        enabled = overflows || expanded,
    ) {
        Column(Modifier.padding(16.dp)) {
            Text("Description", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                text,
                style = MaterialTheme.typography.bodyLarge,
                maxLines = if (expanded) Int.MAX_VALUE else 4,
                overflow = TextOverflow.Ellipsis,
                onTextLayout = { if (!expanded) overflows = it.hasVisualOverflow },
                modifier = Modifier.padding(top = 8.dp),
            )
            if (overflows || expanded) {
                Text(
                    if (expanded) "Less" else "More",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.primary,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
        }
    }
}

/** Kept for callers that still format a raw duration. */
fun formatDuration(totalSeconds: Long): String = formatHm(totalSeconds)
