package com.bennybar.kitzi.ui.queue

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.ArrowDownward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.ui.common.ScreenHeader
import kotlinx.coroutines.launch

/**
 * "Up Next" — a queue of BOOKS, not of tracks. When a book finishes, the head of
 * this queue starts automatically.
 */
@Composable
fun QueueScreen(onOpenPlayer: () -> Unit) {
    val queue = Services.queue
    val items by queue.items.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = Icons.AutoMirrored.Filled.QueueMusic,
            title = "Queue",
            // No subtitle when empty — the centered empty state below already says
            // "Nothing queued", and repeating it in the header read as a stutter.
            subtitle = if (items.isEmpty()) null else "${items.size} up next",
            trailing = {
                if (items.isNotEmpty()) {
                    TextButton(onClick = { queue.clear() }) { Text("Clear") }
                }
            },
        )

        if (items.isEmpty()) {
            Column(
                Modifier.fillMaxSize(),
                verticalArrangement = Arrangement.Center,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.QueueMusic,
                    null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(56.dp),
                )
                Text(
                    "Nothing queued",
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.padding(top = 12.dp),
                )
                Text(
                    "Add a book from its detail page to line it up next.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp, start = 32.dp, end = 32.dp),
                )
            }
            return@Column
        }

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp, top = 16.dp, end = 16.dp,
                bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            itemsIndexed(items, key = { _, e -> e.id }) { index, entry ->
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                        AsyncImage(
                            model = entry.coverUrl,
                            contentDescription = entry.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.size(64.dp).clip(RoundedCornerShape(10.dp)),
                        )
                        Column(Modifier.weight(1f).padding(start = 12.dp)) {
                            Text(
                                entry.title,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            entry.author?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                        IconButton(
                            onClick = { queue.move(index, index - 1) },
                            enabled = index > 0,
                        ) { Icon(Icons.Default.ArrowUpward, "Move up") }
                        IconButton(
                            onClick = { queue.move(index, index + 1) },
                            enabled = index < items.lastIndex,
                        ) { Icon(Icons.Default.ArrowDownward, "Move down") }
                        IconButton(onClick = {
                            queue.remove(entry.id)
                            scope.launch {
                                Services.playback.playItem(entry.id)
                                onOpenPlayer()
                            }
                        }) { Icon(Icons.Default.PlayArrow, "Play now") }
                        IconButton(onClick = { queue.remove(entry.id) }) {
                            Icon(Icons.Default.Close, "Remove")
                        }
                    }
                }
            }
        }
    }
}
