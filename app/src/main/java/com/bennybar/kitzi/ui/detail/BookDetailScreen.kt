package com.bennybar.kitzi.ui.detail

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
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
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
    val scope = rememberCoroutineScope()

    LaunchedEffect(itemId) {
        book = Services.books.getBook(itemId)
        progress = Services.books.progressFor(itemId)
        bookmarks = runCatching { Services.books.bookmarks(itemId) }.getOrDefault(emptyList())
    }
    LaunchedEffect(itemId) {
        Services.downloads.watch(itemId).collect { download = it }
    }

    val b = book
    if (b == null) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
            CircularProgressIndicator()
        }
        return
    }

    Column(Modifier.fillMaxSize()) {
        TopAppBar(
            title = { Text("Book Details", fontWeight = FontWeight.SemiBold) },
            navigationIcon = {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
            actions = {
                IconButton(onClick = {
                    b.let { Services.queue.addToBack(QueueEntry(it.id, it.title, it.author, it.coverUrl)) }
                }) { Icon(Icons.AutoMirrored.Filled.PlaylistAdd, "Add to queue") }
                TextButton(onClick = {
                    // Marking finished writes the finished state locally and on the
                    // server (off the main thread), then refreshes the shown progress.
                    scope.launch {
                        Services.books.markFinished(itemId)
                        progress = Services.books.progressFor(itemId)
                    }
                }) { Text("Mark as Finished") }
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
                Button(
                    onClick = { scope.launch { Services.playback.playItem(itemId); onPlay() } },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.PlayArrow, null)
                    Text(
                        if ((progress?.progress ?: 0.0) > 0) "Resume" else "Play",
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
                if (d?.isComplete == true) {
                    OutlinedButton(
                        onClick = { scope.launch { Services.downloads.delete(itemId) } },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Delete, null)
                        Text("Remove", modifier = Modifier.padding(start = 6.dp))
                    }
                } else {
                    OutlinedButton(
                        onClick = { scope.launch { Services.downloads.download(itemId) } },
                        modifier = Modifier.weight(1f),
                    ) {
                        Icon(Icons.Default.Download, null)
                        Text("Download", modifier = Modifier.padding(start = 6.dp))
                    }
                }
            }

            ProgressCard(progress)

            // Year / Publisher / Genres, as icon-badged fact cards in a grid — the
            // Year and Publisher share a row; Genres spans full width below.
            val facts = buildList {
                b.publishYear?.let { add(Triple(Icons.Default.CalendarMonth, "Year", it.toString())) }
                b.publisher?.let { add(Triple(Icons.Default.Business, "Publisher", it)) }
            }
            val genres = b.genres.takeIf { it.isNotEmpty() }?.joinToString(", ")
            if (facts.isNotEmpty() || genres != null) {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(20.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                        if (facts.isNotEmpty()) {
                            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                facts.forEach { (icon, label, value) ->
                                    FactCard(icon, label, value, Modifier.weight(1f))
                                }
                                if (facts.size == 1) Box(Modifier.weight(1f))
                            }
                        }
                        genres?.let { FactCard(Icons.Default.LocalOffer, "Genres", it, Modifier.fillMaxWidth()) }
                    }
                }
            }

            // Full "extra information" (language, ISBN, file type, bitrate, …).
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(20.dp),
                modifier = Modifier.fillMaxWidth().clickable { showInfo = true },
            ) {
                Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(Icons.Default.Info, null, tint = MaterialTheme.colorScheme.primary)
                    Text(
                        "More info",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.weight(1f).padding(start = 14.dp),
                    )
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
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

            OutlinedButton(
                onClick = {
                    Services.queue.addToBack(
                        QueueEntry(b.id, b.title, b.author, b.coverUrl)
                    )
                },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.AutoMirrored.Filled.QueueMusic, null)
                Text("Add to queue", modifier = Modifier.padding(start = 6.dp))
            }

            BookmarksCard(bookmarks)

            b.description?.takeIf { it.isNotBlank() }?.let {
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(20.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(Modifier.padding(16.dp)) {
                        Text(
                            "Description",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.SemiBold,
                        )
                        Text(
                            // ABS descriptions carry HTML; strip the tags rather than render them.
                            it.replace(Regex("<[^>]*>"), "").trim(),
                            style = MaterialTheme.typography.bodyLarge,
                            modifier = Modifier.padding(top = 8.dp),
                        )
                    }
                }
            }

            Text("", Modifier.padding(bottom = 12.dp))
        }
    }

    if (showInfo) {
        com.bennybar.kitzi.ui.player.PlayerInfoSheet(itemId = itemId, onDismiss = { showInfo = false })
    }
}

@Composable
private fun InfoChip(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String) {
    AssistChip(
        onClick = {},
        leadingIcon = { Icon(icon, null, Modifier.size(18.dp)) },
        label = { Text(label) },
    )
}

/** A fact tile: a tinted icon badge, a small label above its value. */
@Composable
private fun FactCard(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    value: String,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(16.dp),
        modifier = modifier,
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(
                Modifier
                    .size(38.dp)
                    .clip(RoundedCornerShape(12.dp))
                    .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
            }
            Column(Modifier.padding(start = 12.dp)) {
                Text(
                    label,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    value,
                    style = MaterialTheme.typography.bodyLarge,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun ProgressCard(progress: MediaProgressEntity?) {
    val fraction = progress?.progress ?: 0.0
    val finished = progress?.isFinished == true

    val title = when {
        finished -> "Finished"
        fraction > 0 -> "${(fraction * 100).toInt()}% complete"
        else -> "Not started"
    }
    val subtitle = when {
        finished -> "You've listened to the whole book."
        fraction > 0 -> "${formatHm((progress!!.currentTimeSec).toLong())} in"
        else -> "Start listening to save your progress."
    }

    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (finished) Icons.Default.CheckCircle else Icons.Default.PlayArrow,
                null,
                tint = if (finished) MaterialTheme.colorScheme.primary
                else MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(30.dp),
            )
            Column(Modifier.weight(1f).padding(start = 14.dp)) {
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
private fun BookmarksCard(bookmarks: List<Bookmark>) {
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
                        Modifier.fillMaxWidth().padding(top = 10.dp),
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
                            formatHm(bm.timeSec.toLong()),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

/** Kept for callers that still format a raw duration. */
fun formatDuration(totalSeconds: Long): String = formatHm(totalSeconds)
