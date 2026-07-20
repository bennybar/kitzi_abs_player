package com.bennybar.kitzi.ui.downloads

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Download
import androidx.compose.material3.FilterChip
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.DownloadStatus
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.downloads.ItemDownload
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.formatHm
import com.bennybar.kitzi.ui.common.formatSize
import kotlinx.coroutines.launch

private enum class DownloadFilter { ALL, DOWNLOADING, DOWNLOADED }

@Composable
fun DownloadsScreen(onOpenBook: (String) -> Unit) {
    var downloads by remember { mutableStateOf<List<ItemDownload>>(emptyList()) }
    var books by remember { mutableStateOf<Map<String, Book>>(emptyMap()) }
    var bytes by remember { mutableStateOf(0L) }
    var search by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(DownloadFilter.ALL) }
    // The trash icon used to delete gigabytes on a single tap with no undo, while
    // the same action from the player and book detail already asks first.
    var pendingDelete by remember { mutableStateOf<ItemDownload?>(null) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(Unit) {
        // watchAll() re-emits on every byte-progress update (roughly every 512 KB
        // during a download). Doing a per-book metadata read and a full disk walk on
        // each emission made the list crawl while anything was downloading, so both
        // are now keyed to what actually changed: metadata is fetched in ONE query
        // and only when the set of items changes, and the disk total is recomputed
        // on the same trigger rather than continuously.
        var knownIds = emptySet<String>()
        Services.downloads.watchAll().collect { list ->
            downloads = list
            val ids = list.map { it.itemId }.toSet()
            if (ids != knownIds) {
                knownIds = ids
                books = Services.books.getBooks(ids).associateBy { it.id }
                bytes = Services.downloads.totalBytes()
            }
        }
    }

    val visible = downloads
        .filter { d ->
            when (filter) {
                DownloadFilter.ALL -> true
                DownloadFilter.DOWNLOADING -> !d.isComplete
                DownloadFilter.DOWNLOADED -> d.isComplete
            }
        }
        .filter { d ->
            val b = books[d.itemId]
            search.isBlank() ||
                b?.title?.contains(search, true) == true ||
                b?.author?.contains(search, true) == true
        }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = Icons.Default.Download,
            title = "Downloads",
            subtitle = "${downloads.size} ${if (downloads.size == 1) "book" else "books"} · ${formatSize(bytes)}",
        )
        KitziSearchField(search, { search = it }, "Search downloads", Modifier.padding(bottom = 8.dp))

        Row(
            Modifier
                .fillMaxWidth()
                .horizontalScroll(rememberScrollState())
                .padding(horizontal = 16.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            DownloadFilter.entries.forEach { f ->
                FilterChip(
                    selected = filter == f,
                    onClick = { filter = f },
                    label = { Text(f.name.lowercase().replaceFirstChar { it.uppercase() }) },
                )
            }
        }

        if (visible.isEmpty()) {
            com.bennybar.kitzi.ui.browse.BrowseEmptyState(
                icon = Icons.Default.Download,
                title = if (search.isNotBlank()) "No matches" else "No downloads yet",
                message = if (search.isNotBlank()) "Try adjusting your search terms"
                else "Books you download for offline listening appear here",
            )
            return@Column
        }

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp, top = 16.dp, end = 16.dp,
                bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(visible, key = { it.itemId }) { d ->
                val book = books[d.itemId]
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier.fillMaxWidth().clickable { onOpenBook(d.itemId) },
                ) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        AsyncImage(
                            model = book?.coverUrl,
                            contentDescription = book?.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)),
                        )
                        Column(Modifier.weight(1f).padding(start = 12.dp)) {
                            Text(
                                book?.title ?: "Downloading…",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            book?.author?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                            // "147.5 MB • 5h 22m • Complete"
                            val parts = buildList {
                                book?.sizeBytes?.let { add(formatSize(it)) }
                                book?.durationMs?.let { add(formatHm(it / 1000)) }
                                add(
                                    when (d.status) {
                                        DownloadStatus.COMPLETE -> "Complete"
                                        DownloadStatus.RUNNING -> "${(d.progress * 100).toInt()}%"
                                        DownloadStatus.QUEUED -> "Queued"
                                        DownloadStatus.FAILED -> "Failed"
                                        DownloadStatus.CANCELED -> "Stopped"
                                    }
                                )
                            }
                            Text(
                                parts.joinToString(" • "),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            if (!d.isComplete) {
                                LinearProgressIndicator(
                                    progress = { d.progress.toFloat() },
                                    modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
                                )
                            }
                        }
                        IconButton(onClick = { pendingDelete = d }) {
                            Icon(Icons.Default.Delete, "Delete download")
                        }
                    }
                }
            }
        }
    }

    pendingDelete?.let { target ->
        val title = books[target.itemId]?.title ?: "this book"
        val running = !target.isComplete
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text(if (running) "Cancel download?" else "Remove download?") },
            text = {
                Text(
                    if (running) "Stop downloading \u201c$title\u201d and discard what's downloaded so far?"
                    else "Delete the downloaded files for \u201c$title\u201d? You can download it again anytime."
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    pendingDelete = null
                    scope.launch { Services.downloads.delete(target.itemId) }
                }) { Text(if (running) "Cancel download" else "Remove download") }
            },
            dismissButton = { TextButton(onClick = { pendingDelete = null }) { Text("Keep") } },
        )
    }
}
