package com.bennybar.kitzi.ui.queue

import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.zIndex
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.setValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.DragHandle
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
                    TextButton(onClick = {
                        val before = items
                        queue.clear()
                        com.bennybar.kitzi.ui.common.Snackbars.show("Queue cleared", "Undo") { queue.restore(before) }
                    }) { Text("Clear") }
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

        // Drag the handle to reorder; swipe a row away to remove it (with Undo). The
        // rows used to carry four small buttons each (up, down, play, remove).
        val latestItems by androidx.compose.runtime.rememberUpdatedState(items)
        var draggingId by remember { mutableStateOf<String?>(null) }
        var dragOffset by remember { mutableFloatStateOf(0f) }
        var rowStepPx by remember { mutableIntStateOf(0) }
        val spacingPx = with(androidx.compose.ui.platform.LocalDensity.current) { 10.dp.roundToPx() }
        // Part of each row's key, bumped on Undo: the list keeps a row's swipe state by
        // key, so a restored row under its old key came back already "dismissed" and
        // removed itself again.
        var restoreEpoch by remember { mutableIntStateOf(0) }
        fun removeWithUndo(entry: com.bennybar.kitzi.playback.QueueEntry) {
            val before = latestItems
            queue.remove(entry.id)
            com.bennybar.kitzi.ui.common.Snackbars.show("Removed from queue", "Undo") {
                restoreEpoch++
                queue.restore(before)
            }
        }

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(
                start = 16.dp, top = 16.dp, end = 16.dp,
                bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            itemsIndexed(items, key = { _, e -> "${e.id}:$restoreEpoch" }) { index, entry ->
                val dragging = draggingId == entry.id
                val swipe = androidx.compose.material3.rememberSwipeToDismissBoxState()
                androidx.compose.material3.SwipeToDismissBox(
                    state = swipe,
                    onDismiss = { removeWithUndo(entry) },
                    gesturesEnabled = !dragging,
                    backgroundContent = {
                        Box(
                            Modifier.fillMaxSize().clip(RoundedCornerShape(18.dp))
                                .background(MaterialTheme.colorScheme.errorContainer)
                                .padding(horizontal = 24.dp),
                            contentAlignment = Alignment.CenterEnd,
                        ) { Icon(Icons.Default.Delete, null, tint = MaterialTheme.colorScheme.onErrorContainer) }
                    },
                    modifier = Modifier
                        .animateItem()
                        .zIndex(if (dragging) 1f else 0f)
                        .graphicsLayer { translationY = if (dragging) dragOffset else 0f }
                        .onSizeChanged { rowStepPx = it.height + spacingPx }
                        .semantics {
                            customActions = listOfNotNull(
                                CustomAccessibilityAction("Move up") { queue.move(index, index - 1); true }.takeIf { index > 0 },
                                CustomAccessibilityAction("Move down") { queue.move(index, index + 1); true }.takeIf { index < items.lastIndex },
                                CustomAccessibilityAction("Remove") { removeWithUndo(entry); true },
                            )
                        },
                ) {
                Surface(
                    color = if (dragging) MaterialTheme.colorScheme.surfaceContainerHigh else MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(18.dp),
                    shadowElevation = if (dragging) 8.dp else 0.dp,
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
                        IconButton(onClick = {
                            scope.launch {
                                // Consume the queue entry and navigate only if the book
                                // actually loaded: doing it first meant a failed play
                                // silently dropped it from the queue AND opened the
                                // player on whatever was loaded before.
                                if (Services.playback.playItem(entry.id)) {
                                    queue.remove(entry.id)
                                    onOpenPlayer()
                                }
                            }
                        }) { Icon(Icons.Default.PlayArrow, "Play now") }
                        // The drag handle: each half-row of travel swaps with a neighbour.
                        Icon(
                            Icons.Default.DragHandle,
                            "Drag to reorder",
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier
                                .size(48.dp)
                                .pointerInput(entry.id) {
                                    detectVerticalDragGestures(
                                        onDragStart = { draggingId = entry.id; dragOffset = 0f },
                                        onDragEnd = { draggingId = null; dragOffset = 0f },
                                        onDragCancel = { draggingId = null; dragOffset = 0f },
                                        onVerticalDrag = { change, dy ->
                                            change.consume()
                                            dragOffset += dy
                                            val step = rowStepPx.takeIf { it > 0 } ?: return@detectVerticalDragGestures
                                            val i = latestItems.indexOfFirst { it.id == entry.id }
                                            if (dragOffset > step / 2f && i in 0 until latestItems.lastIndex) {
                                                queue.move(i, i + 1); dragOffset -= step
                                            } else if (dragOffset < -step / 2f && i > 0) {
                                                queue.move(i, i - 1); dragOffset += step
                                            }
                                        },
                                    )
                                }
                                .padding(12.dp),
                        )
                    }
                }
                }
            }
        }
    }
}
