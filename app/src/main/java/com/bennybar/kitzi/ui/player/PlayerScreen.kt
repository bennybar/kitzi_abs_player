package com.bennybar.kitzi.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.Downloading
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.NightsStay
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.SkipNext
import androidx.compose.material.icons.filled.SkipPrevious
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.foundation.gestures.detectHorizontalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.DownloadStatus
import com.bennybar.kitzi.playback.PlaybackController.Companion.KEY_LAST_ITEM
import com.bennybar.kitzi.playback.SleepMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PlayerScreen(contentPadding: androidx.compose.foundation.layout.PaddingValues = androidx.compose.foundation.layout.PaddingValues()) {
    val controller = Services.playback
    val nowPlaying by controller.nowPlaying.collectAsStateWithLifecycle()

    var positionSec by remember { mutableStateOf(0.0) }
    var isPlaying by remember { mutableStateOf(false) }
    var speed by remember { mutableStateOf(1.0) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var showSleep by remember { mutableStateOf(false) }
    var showChapters by remember { mutableStateOf(false) }
    var showSpeed by remember { mutableStateOf(false) }
    var showInfo by remember { mutableStateOf(false) }
    var showMore by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var showCancelDownload by remember { mutableStateOf(false) }
    var showDeleteDownload by remember { mutableStateOf(false) }
    val sleep by Services.sleepTimer.mode.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    LaunchedEffect(nowPlaying?.itemId) {
        while (true) {
            positionSec = controller.globalPositionSec() ?: 0.0
            isPlaying = runCatching { controller.player.isPlaying }.getOrDefault(false)
            speed = runCatching { controller.player.playbackParameters.speed.toDouble() }
                .getOrDefault(1.0).coerceAtLeast(0.1)
            delay(400)
        }
    }

    val np = nowPlaying ?: run {
        NothingPlaying(onResume = {
            Services.prefs.getString(KEY_LAST_ITEM)?.let { id ->
                scope.launch { controller.playItem(id) }
            }
        })
        return
    }

    // The download state for the book being played, so the Download tile can turn
    // into a live indicator and a cancel control.
    val downloadState by produceState<com.bennybar.kitzi.downloads.ItemDownload?>(null, np.itemId) {
        Services.downloads.watch(np.itemId).collect { value = it }
    }

    // Player-affecting settings, read live so the screen reflects them.
    val prefs = Services.prefs
    // Held as state so the "More" menu can toggle them and the player updates live.
    var gradientEnabled by remember { mutableStateOf(prefs.getBoolean("ui_player_gradient_background", true)) }
    var chapterizedBar by remember { mutableStateOf(prefs.getBoolean("ui_progress_bar_chapterized", true)) }
    val seekForwardSec = prefs.getInt("ui_seek_forward_seconds", 30)
    val seekBackwardSec = prefs.getInt("ui_seek_backward_seconds", 30)
    val coverMax = when (prefs.getString("ui_player_cover_size")) {
        "small" -> 240.dp
        "medium" -> 300.dp
        "extraLarge" -> 420.dp
        else -> 360.dp // large (default)
    }

    // Narrator lives in the book cache, not in NowPlaying.
    val narrator by produceState<String?>(null, np.itemId) {
        value = Services.books.getBook(np.itemId)?.narrators?.firstOrNull()
    }

    val palette by rememberCoverPalette(np.coverUrl)

    val total = controller.totalDurationSec() ?: 0.0
    val chapter = controller.currentChapter()

    // A gentle top-to-bottom wash of the cover's colour that settles back into the
    // theme surface. Kept subtle (low blend, ends in the surface, not pure black)
    // so text and controls — all onSurface — stay readable in both light and dark.
    val surface = MaterialTheme.colorScheme.surface
    val background: Modifier = if (gradientEnabled && palette != null) {
        Modifier.background(
            Brush.verticalGradient(
                colors = listOf(
                    blend(palette!!.primary, surface, 0.42f),
                    blend(palette!!.secondary, surface, 0.22f),
                    surface,
                ),
            )
        )
    } else {
        Modifier.background(surface)
    }

    Box(Modifier.fillMaxSize().then(background)) {
        Column(
            // Pad for the system bars (the background above already fills behind them)
            // then the player's own inset.
            Modifier.fillMaxSize().padding(contentPadding).padding(horizontal = 20.dp, vertical = 12.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // --- cover with overlay buttons ---
            // The cover takes the leftover space and shrinks to a square that fits,
            // so the whole player fits one screen without scrolling on any height.
            BoxWithConstraints(
                Modifier.weight(1f).fillMaxWidth(),
                contentAlignment = Alignment.Center,
            ) {
                val side = minOf(maxWidth, maxHeight, coverMax)
                Box(Modifier.size(side)) {
                AsyncImage(
                    model = np.coverUrl,
                    contentDescription = np.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize().clip(RoundedCornerShape(20.dp)),
                )
                CoverButton(
                    icon = Icons.Default.BookmarkAdd,
                    modifier = Modifier.align(Alignment.TopEnd).padding(12.dp),
                    onClick = {
                        val pos = controller.globalPositionSec() ?: 0.0
                        val label = controller.currentChapter()?.title ?: "Bookmark"
                        scope.launch(Dispatchers.IO) { Services.playbackApi.addBookmark(np.itemId, pos, label) }
                    },
                )
                if (com.bennybar.kitzi.ui.UiPrefsState.resumeFromHistory.value) {
                    CoverButton(
                        icon = Icons.Default.History,
                        label = "Last position",
                        iconColor = Color(0xFF7EE08A),
                        modifier = Modifier.align(Alignment.BottomStart).padding(12.dp),
                        // Jump back to the last saved listening position (useful after
                        // scrubbing around).
                        onClick = {
                            scope.launch {
                                Services.books.progressFor(np.itemId)?.currentTimeSec
                                    ?.let { controller.seekGlobal(it, reportNow = true) }
                            }
                        },
                    )
                }
                CoverButton(
                    icon = Icons.Default.Info,
                    label = "More info",
                    modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
                    onClick = { showInfo = true },
                )
                }
            }

            // --- metadata, centered ---
            Text(
                np.title,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.ExtraBold,
                textAlign = TextAlign.Center,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 14.dp),
            )
            np.author?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 6.dp),
                )
            }
            narrator?.takeIf { it.isNotBlank() }?.let {
                Text(
                    "Narrated by $it",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f),
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 3.dp),
                )
            }
            com.bennybar.kitzi.ui.common.AudibleStars(
                itemId = np.itemId,
                title = np.title,
                author = np.author,
                narrator = narrator,
                durationMs = (controller.totalDurationSec()?.let { (it * 1000).toLong() }),
                modifier = Modifier.padding(top = 8.dp),
            )

            // clock pill with the whole-book length
            if (total > 0) {
                Row(
                    Modifier
                        .padding(top = 8.dp)
                        .clip(RoundedCornerShape(20.dp))
                        .background(MaterialTheme.colorScheme.surfaceContainerHigh)
                        .padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Default.Headphones,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(16.dp),
                    )
                    Text(
                        formatClock(total.toLong()),
                        style = MaterialTheme.typography.labelLarge,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }

            // --- progress slider with chapter ticks ---
            // "Primary progress display": the slider can track the whole BOOK
            // (default) or just the CURRENT CHAPTER (ui_progress_primary=chapter),
            // where dragging seeks within the chapter.
            val chapterMode = prefs.getString("ui_progress_primary") == "chapter" &&
                chapter != null && chapter.durationSec > 0
            val sliderMax = if (chapterMode) chapter!!.durationSec else total
            val sliderPos = if (chapterMode) chapter!!.elapsedSec else positionSec
            val sliderValue = scrubbing ?: sliderPos.toFloat()
            // Chapter boundaries as fractions, drawn as subtle notches on the track —
            // only in book mode (they're book-scale) and when the setting is on.
            val tickFractions = if (!chapterMode && chapterizedBar && np.chapters.size > 1 && total > 0) {
                np.chapters.map { (it.startSec / total).toFloat() }.filter { it > 0.008f && it < 0.992f }
            } else emptyList()
            PlayerProgressBar(
                value = sliderValue,
                valueRange = 0f..(sliderMax.toFloat().coerceAtLeast(1f)),
                onValueChange = { scrubbing = it },
                onValueChangeFinished = {
                    scrubbing?.let {
                        val target = if (chapterMode) chapter!!.startSec + it else it.toDouble()
                        controller.seekGlobal(target.toDouble(), reportNow = true)
                    }
                    scrubbing = null
                },
                chapterTicks = tickFractions,
                modifier = Modifier.fillMaxWidth().padding(top = 14.dp),
            )

            // position / -remaining (of the chapter in chapter mode, else the book)
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    formatClock((scrubbing?.toDouble() ?: sliderPos).toLong()),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.SemiBold,
                )
                // Remaining is WALL-CLOCK time to finish at the current speed, so a
                // faster speed shows less time left.
                val remainingContent = (sliderMax - (scrubbing?.toDouble() ?: sliderPos)).coerceAtLeast(0.0)
                Text(
                    "-${formatClock((remainingContent / speed).toLong())}",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.SemiBold,
                )
            }

            // chapter descriptor + chapter time (the "book + chapter progress" setting)
            chapter?.takeIf { com.bennybar.kitzi.ui.UiPrefsState.dualProgress.value }?.let { c ->
                Row(
                    Modifier.fillMaxWidth().padding(top = 8.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.Top,
                ) {
                    Text(
                        "Chapter ${c.index + 1} of ${np.chapters.size} • ${c.title}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).padding(end = 12.dp),
                    )
                    Text(
                        "${formatClock(c.elapsedSec.toLong())} / ${formatClock(c.durationSec.toLong())}",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }

            // --- transport row ---
            Row(
                Modifier.fillMaxWidth().padding(top = 14.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ControlButton(Icons.Default.SkipPrevious, "Previous chapter", 60.dp) { controller.previousChapter() }
                // The rewind/forward glyphs follow the configured seek interval.
                ControlButton(replayIcon(seekBackwardSec), "Back ${seekBackwardSec}s", 60.dp) { controller.seekBackward() }
                // primary filled play/pause
                Box(
                    Modifier
                        .padding(horizontal = 10.dp)
                        .size(76.dp)
                        .clip(RoundedCornerShape(24.dp))
                        .background(MaterialTheme.colorScheme.primary)
                        .clickable {
                            val p = controller.player
                            if (p.isPlaying) p.pause() else p.play()
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                        if (isPlaying) "Pause" else "Play",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(40.dp),
                    )
                }
                ControlButton(forwardIcon(seekForwardSec), "Forward ${seekForwardSec}s", 60.dp) { controller.seekForward() }
                ControlButton(Icons.Default.SkipNext, "Next chapter", 60.dp) { controller.nextChapter() }
            }

            // --- bottom action tiles ---
            Row(
                Modifier.fillMaxWidth().padding(top = 14.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                ActionTile(Icons.AutoMirrored.Filled.List, "Chapters", Modifier.weight(1f), enabled = np.chapters.size > 1) { showChapters = true }
                val dl = downloadState
                val downloading = dl != null && !dl.isComplete &&
                    (dl.status == DownloadStatus.RUNNING || dl.status == DownloadStatus.QUEUED)
                when {
                    downloading -> ActionTile(Icons.Default.Downloading, "Cancel download", Modifier.weight(1f), highlighted = true) {
                        showCancelDownload = true
                    }
                    dl?.isComplete == true -> ActionTile(Icons.Default.DownloadDone, "Downloaded", Modifier.weight(1f), highlighted = true) {
                        showDeleteDownload = true
                    }
                    else -> ActionTile(Icons.Default.Download, "Download", Modifier.weight(1f)) {
                        scope.launch { Services.downloads.download(np.itemId) }
                    }
                }
                ActionTile(
                    Icons.Default.NightsStay,
                    "Sleep",
                    Modifier.weight(1f),
                    highlighted = sleep !is SleepMode.Off,
                ) { showSleep = true }
                ActionTile(Icons.Default.Speed, "Speed", Modifier.weight(1f)) { showSpeed = true }
                ActionTile(Icons.Default.MoreVert, "More", Modifier.weight(1f)) { showMore = true }
            }

            Box(Modifier.height(4.dp))
        }
    }

    if (showCancelDownload) {
        AlertDialog(
            onDismissRequest = { showCancelDownload = false },
            title = { Text("Cancel download?") },
            text = { Text("Stop downloading this book? Tracks already downloaded are kept.") },
            confirmButton = {
                TextButton(onClick = {
                    showCancelDownload = false
                    scope.launch { Services.downloads.cancel(np.itemId) }
                }) { Text("Cancel download") }
            },
            dismissButton = {
                TextButton(onClick = { showCancelDownload = false }) { Text("Keep downloading") }
            },
        )
    }

    if (showDeleteDownload) {
        AlertDialog(
            onDismissRequest = { showDeleteDownload = false },
            title = { Text("Remove download?") },
            text = { Text("Delete this book's downloaded files from your device? You can download it again anytime.") },
            confirmButton = {
                TextButton(onClick = {
                    showDeleteDownload = false
                    scope.launch { Services.downloads.delete(np.itemId) }
                }) { Text("Remove download") }
            },
            dismissButton = {
                TextButton(onClick = { showDeleteDownload = false }) { Text("Keep") }
            },
        )
    }

    if (showSleep) {
        SleepTimerSheet(
            current = sleep,
            // Stay open after starting/cancelling so the running status is visible;
            // the user dismisses the sheet themselves (swipe down / tap outside).
            onDismiss = { showSleep = false },
            onDuration = { Services.sleepTimer.startDuration(it) },
            onEndOfChapter = { Services.sleepTimer.startEndOfChapter() },
            onCancel = { Services.sleepTimer.cancel() },
        )
    }
    if (showSpeed) {
        SpeedSheet(
            current = speed.toFloat(),
            onChange = { controller.setSpeed(it.toDouble()) },
            onDismiss = { showSpeed = false },
        )
    }
    if (showChapters) {
        ChapterSheet(
            chapters = np.chapters,
            currentIndex = chapter?.index ?: -1,
            onPick = { controller.seekGlobal(it.startSec); showChapters = false },
            onDismiss = { showChapters = false },
        )
    }
    if (showInfo) {
        PlayerInfoSheet(itemId = np.itemId, onDismiss = { showInfo = false })
    }
    if (showHistory) {
        PlayHistorySheet(
            itemId = np.itemId,
            bookTitle = np.title,
            onPick = { controller.seekGlobal(it, reportNow = true); showHistory = false },
            onDismiss = { showHistory = false },
        )
    }
    if (showMore) {
        PlayerMoreSheet(
            gradientEnabled = gradientEnabled,
            chapterized = chapterizedBar,
            onPlayHistory = { showMore = false; showHistory = true },
            onToggleGradient = {
                gradientEnabled = !gradientEnabled
                prefs.putBoolean("ui_player_gradient_background", gradientEnabled)
            },
            onToggleChapterized = {
                chapterizedBar = !chapterizedBar
                prefs.putBoolean("ui_progress_bar_chapterized", chapterizedBar)
            },
            onMarkFinished = {
                scope.launch { Services.books.markFinished(np.itemId) }
                showMore = false
            },
            onDismiss = { showMore = false },
        )
    }
}

/**
 * A modern scrubber: a slim rounded track, a primary fill, faint chapter notches
 * cut into it, and a small thumb that swells while dragging. Tap anywhere to seek;
 * drag to scrub. Replaces the stock Material Slider (chunky thumb + a separate tick
 * overlay), which read as dated.
 */
@Composable
private fun PlayerProgressBar(
    value: Float,
    valueRange: ClosedFloatingPointRange<Float>,
    onValueChange: (Float) -> Unit,
    onValueChangeFinished: () -> Unit,
    chapterTicks: List<Float>,
    modifier: Modifier = Modifier,
) {
    val primary = MaterialTheme.colorScheme.primary
    val inactive = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.14f)
    val notch = MaterialTheme.colorScheme.surface
    val span = (valueRange.endInclusive - valueRange.start).coerceAtLeast(0.001f)
    val fraction = ((value - valueRange.start) / span).coerceIn(0f, 1f)
    var dragging by remember { mutableStateOf(false) }
    val thumbRadius by androidx.compose.animation.core.animateDpAsState(
        if (dragging) 9.dp else 6.5.dp, label = "thumb",
    )

    fun posToValue(x: Float, width: Int): Float =
        valueRange.start + (x / width).coerceIn(0f, 1f) * span

    androidx.compose.foundation.Canvas(
        modifier
            .height(28.dp)
            .pointerInput(valueRange) {
                detectTapGestures { offset ->
                    onValueChange(posToValue(offset.x, size.width)); onValueChangeFinished()
                }
            }
            .pointerInput(valueRange) {
                detectHorizontalDragGestures(
                    onDragStart = { dragging = true; onValueChange(posToValue(it.x, size.width)) },
                    onDragEnd = { dragging = false; onValueChangeFinished() },
                    onDragCancel = { dragging = false; onValueChangeFinished() },
                    onHorizontalDrag = { change, _ ->
                        onValueChange(posToValue(change.position.x, size.width))
                    },
                )
            },
    ) {
        val w = size.width
        val cy = size.height / 2
        val trackH = 6.dp.toPx()
        val r = trackH / 2
        // inactive track
        drawRoundRect(
            inactive, topLeft = Offset(0f, cy - r), size = androidx.compose.ui.geometry.Size(w, trackH),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
        )
        // active fill
        drawRoundRect(
            primary, topLeft = Offset(0f, cy - r),
            size = androidx.compose.ui.geometry.Size(w * fraction, trackH),
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(r, r),
        )
        // chapter notches, cut into the track with the background colour
        val nw = 2.dp.toPx()
        chapterTicks.forEach { t ->
            drawRoundRect(
                notch, topLeft = Offset(w * t - nw / 2, cy - r),
                size = androidx.compose.ui.geometry.Size(nw, trackH),
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(nw / 2, nw / 2),
            )
        }
        // thumb
        val cx = (w * fraction).coerceIn(0f, w)
        drawCircle(primary, radius = thumbRadius.toPx(), center = Offset(cx, cy))
    }
}
