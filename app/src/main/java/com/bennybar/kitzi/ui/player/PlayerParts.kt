package com.bennybar.kitzi.ui.player

import androidx.compose.foundation.layout.height
import kotlinx.coroutines.launch
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.material3.IconButton
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Bookmark
import androidx.compose.material.icons.filled.Bookmarks
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.material3.minimumInteractiveComponentSize
import android.graphics.Bitmap
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AudioFile
import androidx.compose.material.icons.filled.Book
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Gradient
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Inventory2
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.LocalShipping
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Segment
import androidx.compose.material.icons.filled.Tag
import androidx.compose.material.icons.filled.Forward10
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Forward5
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Replay10
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material.icons.filled.Replay5
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Slider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlin.math.roundToInt
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.core.graphics.drawable.toBitmapOrNull
import androidx.palette.graphics.Palette
import coil.imageLoader
import coil.compose.AsyncImage
import coil.request.ImageRequest
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.playback.Chapter
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** The two colours pulled from a cover, used to build the player gradient. */
class CoverPalette(val primary: Color, val secondary: Color)

/**
 * Process-level cache of extracted palettes, keyed by cover URL.
 *
 * Without this the palette is re-extracted (null -> resolved) every time the
 * player is entered, so the gradient visibly re-populates on each navigation.
 * Caching it makes re-entry instant and flash-free.
 */
private val paletteCache = mutableMapOf<String, CoverPalette>()

/** Rewind glyph that reflects the configured seek-back interval. */
fun replayIcon(seconds: Int): ImageVector = when (seconds) {
    5 -> Icons.Default.Replay5
    10 -> Icons.Default.Replay10
    30 -> Icons.Default.Replay30
    else -> Icons.Default.Replay
}

/** Forward glyph that reflects the configured seek-forward interval. */
fun forwardIcon(seconds: Int): ImageVector = when (seconds) {
    5 -> Icons.Default.Forward5
    10 -> Icons.Default.Forward10
    30 -> Icons.Default.Forward30
    else -> Icons.Default.FastForward
}

/**
 * Extracts a primary/secondary colour from the cover art, off the main thread.
 * Returns null until it resolves (or if extraction fails), so the caller can
 * fall back to a flat background — matching the Flutter palette_generator path.
 */
@Composable
fun rememberCoverPalette(coverUrl: String?): State<CoverPalette?> {
    val context = LocalContext.current
    // Seed from the cache so a previously-seen cover renders its gradient on the
    // very first frame, with no null-then-resolve flash.
    val cached = coverUrl?.let { paletteCache[it] }
    return produceState<CoverPalette?>(initialValue = cached, coverUrl) {
        if (coverUrl.isNullOrEmpty()) { value = null; return@produceState }
        paletteCache[coverUrl]?.let { value = it; return@produceState }
        value = withContext(Dispatchers.IO) {
            runCatching {
                // The app-wide loader: it authenticates, and shares the memory and
                // disk caches the cover itself was just loaded into.
                val loader = context.imageLoader
                val result = loader.execute(
                    ImageRequest.Builder(context)
                        .data(coverUrl)
                        .allowHardware(false) // Palette needs a readable bitmap
                        .build()
                )
                val bitmap: Bitmap = result.drawable?.toBitmapOrNull() ?: return@runCatching null
                val palette = Palette.from(bitmap).generate()
                // The dominant colour drives the wash so it's actually visible; a
                // vibrant fallback gives colourful covers some life. It's blended
                // low over the surface at draw time so it never gets garish.
                val primary = palette.dominantSwatch?.rgb
                    ?: palette.vibrantSwatch?.rgb
                    ?: palette.mutedSwatch?.rgb
                    ?: return@runCatching null
                val secondary = palette.vibrantSwatch?.rgb
                    ?: palette.mutedSwatch?.rgb
                    ?: palette.darkVibrantSwatch?.rgb
                    ?: primary
                CoverPalette(Color(primary), Color(secondary)).also { paletteCache[coverUrl] = it }
            }.getOrNull()
        }
    }
}

/** Alpha-blends [over] onto [under] by [fraction], as Flutter's Color.alphaBlend does. */
fun blend(over: Color, under: Color, fraction: Float): Color {
    val a = fraction.coerceIn(0f, 1f)
    return Color(
        red = over.red * a + under.red * (1 - a),
        green = over.green * a + under.green * (1 - a),
        blue = over.blue * a + under.blue * (1 - a),
    )
}

/** "8h 28m" style, but with h:mm:ss for the scrubber labels — matches the Flutter _fmt. */
fun formatClock(totalSeconds: Long): String {
    val s = totalSeconds.coerceAtLeast(0)
    val h = s / 3600
    val m = (s % 3600) / 60
    val sec = s % 60
    return if (h > 0) "%d:%02d:%02d".format(h, m, sec) else "%d:%02d".format(m, sec)
}

/** A translucent icon (optionally labelled) button that floats over the cover. */
@Composable
fun CoverButton(
    icon: ImageVector,
    modifier: Modifier = Modifier,
    label: String? = null,
    iconColor: Color = Color.White,
    /** For an icon-only button, what TalkBack reads (a visible [label] covers it). */
    contentDescription: String? = label,
    onClick: () -> Unit,
) {
    // The touch area is at least 48dp (the icon-only bookmark button was ~32dp);
    // the visible pill keeps its size inside it.
    Box(
        modifier
            .minimumInteractiveComponentSize()
            .clip(RoundedCornerShape(24.dp))
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
    Row(
        Modifier
            .clip(RoundedCornerShape(20.dp))
            .background(Color.Black.copy(alpha = 0.45f))
            .padding(horizontal = if (label != null) 10.dp else 8.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription, tint = iconColor, modifier = Modifier.size(16.dp))
        if (label != null) {
            Text(
                label,
                color = Color.White,
                style = MaterialTheme.typography.labelMedium,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(start = 6.dp),
            )
        }
    }
    }
}

/** A transport side button: just the icon, no background. */
@Composable
fun ControlButton(icon: ImageVector, contentDescription: String, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Box(
        Modifier.size(size).clip(RoundedCornerShape(16.dp)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription,
            tint = MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.size(size * 0.55f),
        )
    }
}

/** One of the five rounded action tiles under the transport controls. */
@Composable
fun ActionTile(
    icon: ImageVector,
    contentDescription: String,
    modifier: Modifier = Modifier,
    enabled: Boolean = true,
    highlighted: Boolean = false,
    /** Shown instead of the icon when set: the tile's current state ("1.5×", "12:04"). */
    label: String? = null,
    onClick: () -> Unit,
) {
    val bg = when {
        highlighted -> MaterialTheme.colorScheme.primaryContainer
        else -> MaterialTheme.colorScheme.surfaceContainerHigh
    }
    Box(
        modifier
            .clip(RoundedCornerShape(18.dp))
            .background(bg)
            .then(if (enabled) Modifier.clickable(onClick = onClick) else Modifier)
            .padding(vertical = 14.dp),
        contentAlignment = Alignment.Center,
    ) {
        if (label != null) {
            Text(
                label,
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.Bold,
                color = if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
                // Same height as the 22dp icon, so the tile doesn't jump.
                modifier = Modifier.height(22.dp).semantics { this.contentDescription = contentDescription },
            )
        } else {
            Icon(
                icon,
                contentDescription,
                tint = if (enabled) {
                    if (highlighted) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface
                } else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                modifier = Modifier.size(22.dp),
            )
        }
    }
}

/** The player with nothing loaded: gradient wash, headphones, resume offer. */
@Composable
fun NothingPlaying(onResume: () -> Unit) {
    val hasLast = com.bennybar.kitzi.data.Services.prefs
        .getString(com.bennybar.kitzi.playback.PlaybackController.KEY_LAST_ITEM) != null

    Box(
        Modifier
            .fillMaxSize()
            .background(
                Brush.verticalGradient(
                    listOf(
                        MaterialTheme.colorScheme.surfaceContainerHigh,
                        MaterialTheme.colorScheme.surface,
                    )
                )
            ),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(horizontal = 32.dp),
        ) {
            Icon(
                Icons.Default.Headphones,
                null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(64.dp),
            )
            Text(
                "Nothing playing",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.padding(top = 16.dp),
            )
            Text(
                "Pick a book from your library, or tap below to resume the last one you were listening to.",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 8.dp),
            )
            if (hasLast) {
                Button(onClick = onResume, modifier = Modifier.padding(top = 24.dp)) {
                    Icon(Icons.Default.PlayArrow, null)
                    Text("Resume last book", modifier = Modifier.padding(start = 8.dp))
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SleepTimerSheet(
    current: com.bennybar.kitzi.playback.SleepMode,
    onDismiss: () -> Unit,
    onDuration: (Int) -> Unit,
    onEndOfChapter: () -> Unit,
    onCancel: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        // Seed the scroller from a running duration timer, else a sensible default.
        val seed = (current as? com.bennybar.kitzi.playback.SleepMode.Duration)
            ?.let { (it.remainingSec / 60).toInt().coerceIn(5, 120) } ?: 15
        var minutes by remember { mutableStateOf(seed.toFloat()) }
        // Once the user moves the scroller, the primary button becomes "Start timer"
        // again so they can restart at the new duration; otherwise a running timer
        // shows "Cancel timer" in its place.
        var userMoved by remember { mutableStateOf(false) }

        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Sleep timer", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text(
                    "${minutes.roundToInt()} min",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                )
            }

            // Live status when a timer is already running. The timer only holds its
            // end time, so the countdown ticks here, while the sheet is open.
            val durationLeft by produceState(
                (current as? com.bennybar.kitzi.playback.SleepMode.Duration)?.remainingSec ?: 0L, current,
            ) {
                val c = current as? com.bennybar.kitzi.playback.SleepMode.Duration ?: return@produceState
                while (true) { value = c.remainingSec; kotlinx.coroutines.delay(1000) }
            }
            when (val c = current) {
                is com.bennybar.kitzi.playback.SleepMode.Duration ->
                    Text(
                        "Running — ${durationLeft / 60}m ${durationLeft % 60}s left",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                is com.bennybar.kitzi.playback.SleepMode.EndOfChapter ->
                    Text(
                        "Running — stops at end of chapter",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                    )
                com.bennybar.kitzi.playback.SleepMode.Off -> {}
            }

            // Presets start the timer in one tap; the slider below is for other lengths.
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(15, 30, 45, 60).forEach { m ->
                    FilterChip(
                        selected = false,
                        onClick = { minutes = m.toFloat(); onDuration(m); userMoved = false },
                        label = { Text("$m min") },
                    )
                }
            }
            Slider(
                value = minutes,
                onValueChange = { minutes = it; userMoved = true },
                valueRange = 5f..120f,
                steps = (120 - 5) / 5 - 1,   // 5-minute increments
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("5 min", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("2 hr", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }

            // A running, untouched timer turns the primary button into Cancel; moving
            // the scroller (or no timer) makes it Start again.
            if (current !is com.bennybar.kitzi.playback.SleepMode.Off && !userMoved) {
                Button(
                    onClick = onCancel,
                    modifier = Modifier.fillMaxWidth(),
                    colors = ButtonDefaults.buttonColors(
                        containerColor = MaterialTheme.colorScheme.errorContainer,
                        contentColor = MaterialTheme.colorScheme.onErrorContainer,
                    ),
                ) { Text("Cancel timer") }
            } else {
                Button(
                    onClick = { onDuration(minutes.roundToInt()); userMoved = false },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Start timer") }
            }
            FilterChip(
                selected = current is com.bennybar.kitzi.playback.SleepMode.EndOfChapter,
                onClick = { onEndOfChapter(); userMoved = false },
                label = { Text("End of chapter") },
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SpeedSheet(current: Float, onChange: (Float) -> Unit, onDismiss: () -> Unit) {
    val min = com.bennybar.kitzi.playback.PlaybackController.MIN_SPEED.toFloat()
    val max = com.bennybar.kitzi.playback.PlaybackController.MAX_SPEED.toFloat()
    ModalBottomSheet(onDismissRequest = onDismiss) {
        var value by remember { mutableStateOf(current.coerceIn(min, max)) }
        Column(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Playback speed", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
                Text(
                    String.format(java.util.Locale.US, "%.2fx", value),
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.primary,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf(1f, 1.25f, 1.5f, 1.75f, 2f).forEach { preset ->
                    FilterChip(
                        selected = kotlin.math.abs(value - preset) < 0.001f,
                        onClick = { value = preset; onChange(preset) },
                        label = { Text(speedLabel(preset)) },
                    )
                }
            }
            Slider(
                value = value,
                onValueChange = { value = it; onChange(it) },
                valueRange = min..max,
                steps = (((max - min) / 0.05f).roundToInt() - 1),   // 0.05 increments
            )
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text("${min}x", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("${max}x", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            // Snap back to normal speed without dragging the slider there.
            TextButton(
                onClick = { value = 1f; onChange(1f) },
                enabled = kotlin.math.abs(value - 1f) > 0.001f,
                modifier = Modifier.align(Alignment.End),
            ) { Text("Reset to 1×") }
        }
    }
}

/** "1×", "1.25×", "1.5×". */
fun speedLabel(speed: Float): String =
    String.format(java.util.Locale.US, "%.2f", speed).trimEnd('0').trimEnd('.') + "×"

/** "More info" — the book's full metadata fact list, opened from the player cover or book detail. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerInfoSheet(itemId: String, onDismiss: () -> Unit) {
    val data by produceState<Pair<Book?, List<com.bennybar.kitzi.data.MetaFact>>?>(null, itemId) {
        val b = Services.books.getBook(itemId)
        value = b to (b?.let { Services.books.metadataFacts(it) } ?: emptyList())
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        val b = data?.first
        val facts = data?.second
        LazyColumn(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = PaddingValues(bottom = 32.dp),
        ) {
            if (b != null) {
                item {
                    Row(verticalAlignment = Alignment.Top) {
                        AsyncImage(
                            model = b.coverUrl,
                            contentDescription = b.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.size(width = 84.dp, height = 126.dp).clip(RoundedCornerShape(12.dp)),
                        )
                        Column(Modifier.weight(1f).padding(start = 16.dp)) {
                            Text(b.title, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
                            b.author?.let {
                                Text(
                                    it,
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.padding(top = 4.dp),
                                )
                            }
                        }
                    }
                    Text(
                        "More info",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(top = 16.dp, bottom = 4.dp),
                    )
                }
            }
            if (data == null) {
                item { Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() } }
            } else {
                items(facts.orEmpty()) { fact -> FactRow(fact) }
                b?.description?.takeIf { it.isNotBlank() }?.let { desc ->
                    item {
                        Text(
                            "Description",
                            style = MaterialTheme.typography.titleMedium,
                            fontWeight = FontWeight.Bold,
                            modifier = Modifier.padding(top = 16.dp, bottom = 6.dp),
                        )
                        Text(
                            remember(desc) { com.bennybar.kitzi.ui.common.decodeHtml(desc) },
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun FactRow(fact: com.bennybar.kitzi.data.MetaFact) {
    Row(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalAlignment = Alignment.Top) {
        Box(
            Modifier.size(32.dp).clip(RoundedCornerShape(10.dp)).background(MaterialTheme.colorScheme.surfaceContainerHighest),
            contentAlignment = Alignment.Center,
        ) {
            Icon(factIcon(fact.icon), null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
        }
        Column(Modifier.weight(1f).padding(start = 12.dp)) {
            Text(
                fact.label.uppercase(),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.Bold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text(fact.value, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

private fun factIcon(key: String): ImageVector = when (key) {
    "user" -> Icons.Default.Person
    "mic" -> Icons.Default.Mic
    "calendar" -> Icons.Default.CalendarMonth
    "building" -> Icons.Default.Business
    "truck" -> Icons.Default.LocalShipping
    "tags" -> Icons.Default.LocalOffer
    "library" -> Icons.Default.LibraryBooks
    "folder" -> Icons.Default.Folder
    "book" -> Icons.Default.Book
    "clock" -> Icons.Default.Schedule
    "archive" -> Icons.Default.Inventory2
    "audio" -> Icons.Default.AudioFile
    "activity" -> Icons.Default.GraphicEq
    "language" -> Icons.Default.Language
    "pin" -> Icons.Default.Tag
    else -> Icons.Default.Info
}

/** The player "More" menu: mark finished, and the two player display toggles. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayerMoreSheet(
    gradientEnabled: Boolean,
    chapterized: Boolean,
    onPlayHistory: () -> Unit,
    onBookmarks: () -> Unit,
    onToggleGradient: () -> Unit,
    onToggleChapterized: () -> Unit,
    onMarkFinished: () -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(bottom = 16.dp)) {
            MoreRow(Icons.Default.CheckCircle, "Mark as finished", onMarkFinished)
            MoreRow(Icons.Default.Bookmarks, "Bookmarks", onBookmarks)
            MoreRow(Icons.Default.History, "Play history", onPlayHistory)
            MoreRow(
                Icons.Default.Gradient,
                if (gradientEnabled) "Disable gradient background" else "Enable gradient background",
                onToggleGradient,
            )
            MoreRow(
                Icons.Default.Segment,
                if (chapterized) "Chapter indicators: On" else "Chapter indicators: Off",
                onToggleChapterized,
            )
        }
    }
}

/** Play history: the position snapshots recorded on each pause; tap one to jump back. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun PlayHistorySheet(
    itemId: String,
    bookTitle: String,
    onPick: (Double) -> Unit,
    onDismiss: () -> Unit,
) {
    val entries by produceState<List<com.bennybar.kitzi.data.PlaybackJournal.Entry>?>(null, itemId) {
        value = com.bennybar.kitzi.data.PlaybackJournal.historyFor(itemId)
    }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp)) {
            Text("Play history", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Text(
                bookTitle,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(bottom = 12.dp),
            )
        }
        val e = entries
        when {
            e == null -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            e.isEmpty() -> Text(
                "No recent pauses recorded.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )
            else -> LazyColumn(Modifier.fillMaxWidth().heightIn(max = 420.dp)) {
                items(e) { entry ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onPick(entry.positionSec) }
                            .padding(horizontal = 20.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.History, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        Column(Modifier.padding(start = 16.dp)) {
                            Text(
                                entry.chapterTitle?.takeIf { it.isNotBlank() }
                                    ?: "Chapter ${(entry.chapterIndex ?: 0) + 1}",
                                style = MaterialTheme.typography.bodyLarge,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            Text(
                                "${relativeTime(entry.atMs)} • ${formatClock(entry.positionSec.toLong())}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }
        }
    }
}

private fun relativeTime(ms: Long): String {
    val diff = System.currentTimeMillis() - ms
    val min = diff / 60000
    return when {
        min < 1 -> "Just now"
        min < 60 -> "${min}m ago"
        min < 1440 -> "${min / 60}h ago"
        else -> "${min / 1440}d ago"
    }
}

@Composable
private fun MoreRow(icon: ImageVector, label: String, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Text(label, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.padding(start = 16.dp))
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChapterSheet(
    chapters: List<Chapter>,
    currentIndex: Int,
    totalSec: Double?,
    onPick: (Chapter) -> Unit,
    onDismiss: () -> Unit,
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            if (currentIndex >= 0) "Chapters · ${currentIndex + 1} of ${chapters.size}" else "Chapters",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        )
        // Opens on the chapter you're in (a couple of rows of context above it),
        // not on "00: Intro" with 60 chapters to scroll through.
        val listState = rememberLazyListState(initialFirstVisibleItemIndex = (currentIndex - 2).coerceAtLeast(0))
        LazyColumn(Modifier.fillMaxWidth(), state = listState) {
            itemsIndexed(chapters) { index, chapter ->
                val current = index == currentIndex
                val played = currentIndex >= 0 && index < currentIndex
                // Each chapter's length, which says more than its start time.
                val end = chapters.getOrNull(index + 1)?.startSec ?: totalSec
                val length = end?.let { (it - chapter.startSec).coerceAtLeast(0.0) }
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onPick(chapter) }
                        .background(if (current) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f) else Color.Transparent)
                        .padding(horizontal = 20.dp, vertical = 12.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.width(26.dp)) {
                        if (current) Icon(Icons.Default.PlayArrow, "Now playing", tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp))
                    }
                    Text(
                        chapter.title,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = if (current) FontWeight.SemiBold else FontWeight.Normal,
                        color = when {
                            current -> MaterialTheme.colorScheme.primary
                            played -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)
                            else -> MaterialTheme.colorScheme.onSurface
                        },
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f),
                    )
                    length?.let {
                        Text(
                            com.bennybar.kitzi.ui.common.formatHm(it.toLong()).takeIf { _ -> it >= 60 } ?: formatClock(it.toLong()),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 12.dp),
                        )
                    }
                }
            }
        }
    }
}

/** The book's bookmarks, from the player: tap to jump, delete to remove. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BookmarksSheet(itemId: String, onPick: (Double) -> Unit, onDismiss: () -> Unit) {
    var marks by remember { mutableStateOf<List<com.bennybar.kitzi.data.Bookmark>?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(itemId) { marks = runCatching { Services.books.bookmarks(itemId) }.getOrDefault(emptyList()) }
    ModalBottomSheet(onDismissRequest = onDismiss) {
        Text(
            "Bookmarks",
            style = MaterialTheme.typography.titleLarge,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = 20.dp, end = 20.dp, bottom = 8.dp),
        )
        val m = marks
        when {
            m == null -> Box(Modifier.fillMaxWidth().padding(24.dp), contentAlignment = Alignment.Center) { CircularProgressIndicator() }
            m.isEmpty() -> Text(
                "No bookmarks yet. Use the bookmark button on the cover to save your spot.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(horizontal = 20.dp, vertical = 12.dp),
            )
            else -> LazyColumn(Modifier.fillMaxWidth().heightIn(max = 460.dp), contentPadding = PaddingValues(bottom = 16.dp)) {
                items(m, key = { it.timeSec }) { bm ->
                    Row(
                        Modifier.fillMaxWidth().clickable { onPick(bm.timeSec) }.padding(start = 20.dp, end = 8.dp, top = 4.dp, bottom = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.Bookmark, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                        Text(
                            bm.title,
                            style = MaterialTheme.typography.bodyLarge,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f).padding(start = 14.dp),
                        )
                        Text(formatClock(bm.timeSec.toLong()), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        IconButton(onClick = {
                            scope.launch {
                                val ok = kotlinx.coroutines.withContext(Dispatchers.IO) { Services.playbackApi.deleteBookmark(itemId, bm.timeSec) }
                                if (ok) marks = marks.orEmpty() - bm
                                com.bennybar.kitzi.ui.common.Snackbars.show(if (ok) "Bookmark deleted" else "Couldn't delete the bookmark")
                            }
                        }) {
                            Icon(Icons.Default.Delete, "Delete bookmark", tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(20.dp))
                        }
                    }
                }
            }
        }
    }
}
