package com.bennybar.kitzi.ui.player

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.BookmarkAdd
import androidx.compose.material.icons.filled.Download
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
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
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
import com.bennybar.kitzi.playback.PlaybackController.Companion.KEY_LAST_ITEM
import com.bennybar.kitzi.playback.SleepMode
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

@Composable
fun PlayerScreen() {
    val controller = Services.playback
    val nowPlaying by controller.nowPlaying.collectAsStateWithLifecycle()

    var positionSec by remember { mutableStateOf(0.0) }
    var isPlaying by remember { mutableStateOf(false) }
    var scrubbing by remember { mutableStateOf<Float?>(null) }
    var showSleep by remember { mutableStateOf(false) }
    var showChapters by remember { mutableStateOf(false) }
    var showSpeed by remember { mutableStateOf(false) }
    val sleep by Services.sleepTimer.mode.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    LaunchedEffect(nowPlaying?.itemId) {
        while (true) {
            positionSec = controller.globalPositionSec() ?: 0.0
            isPlaying = runCatching { controller.player.isPlaying }.getOrDefault(false)
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

    // Player-affecting settings, read live so the screen reflects them.
    val prefs = Services.prefs
    val gradientEnabled = prefs.getBoolean("ui_player_gradient_background", true)
    val chapterizedBar = prefs.getBoolean("ui_progress_bar_chapterized", true)
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
                    blend(palette!!.primary, surface, 0.22f),
                    blend(palette!!.secondary, surface, 0.10f),
                    surface,
                ),
            )
        )
    } else {
        Modifier.background(surface)
    }

    Box(Modifier.fillMaxSize().then(background)) {
        Column(
            Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // --- cover with overlay buttons ---
            Box(
                Modifier
                    .widthIn(max = coverMax)
                    .fillMaxWidth()
                    .aspectRatio(1f)
                    .padding(top = 8.dp),
            ) {
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
                        onClick = { /* resume-from-history is a stored journal position */ },
                    )
                }
                CoverButton(
                    icon = Icons.Default.Info,
                    label = "More info",
                    modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp),
                    onClick = { showChapters = false },
                )
            }

            // --- metadata, centered ---
            Text(
                np.title,
                style = MaterialTheme.typography.headlineSmall,
                fontWeight = FontWeight.ExtraBold,
                textAlign = TextAlign.Center,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.padding(top = 20.dp),
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

            // clock pill with the whole-book length
            if (total > 0) {
                Row(
                    Modifier
                        .padding(top = 12.dp)
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
            val sliderValue = scrubbing ?: positionSec.toFloat()
            Box(Modifier.fillMaxWidth().padding(top = 24.dp)) {
                Slider(
                    value = sliderValue,
                    onValueChange = { scrubbing = it },
                    onValueChangeFinished = {
                        scrubbing?.let { controller.seekGlobal(it.toDouble(), reportNow = true) }
                        scrubbing = null
                    },
                    valueRange = 0f..(total.toFloat().coerceAtLeast(1f)),
                    colors = SliderDefaults.colors(
                        thumbColor = MaterialTheme.colorScheme.primary,
                        activeTrackColor = MaterialTheme.colorScheme.primary,
                        inactiveTrackColor = MaterialTheme.colorScheme.surfaceContainerHighest,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                // Chapter ticks only when the setting is on (ui_progress_bar_chapterized).
                if (chapterizedBar && np.chapters.size > 1 && total > 0) {
                    ChapterTicks(
                        chapters = np.chapters,
                        totalSec = total,
                        progress = (sliderValue / total.toFloat()).coerceIn(0f, 1f),
                        modifier = Modifier.fillMaxWidth().height(30.dp).align(Alignment.Center),
                    )
                }
            }

            // position / -remaining
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                Text(
                    formatClock((scrubbing?.toDouble() ?: positionSec).toLong()),
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    fontWeight = FontWeight.SemiBold,
                )
                Text(
                    "-${formatClock((total - (scrubbing?.toDouble() ?: positionSec)).coerceAtLeast(0.0).toLong())}",
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
                Modifier.fillMaxWidth().padding(top = 20.dp),
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
                Modifier.fillMaxWidth().padding(top = 20.dp),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                ActionTile(Icons.AutoMirrored.Filled.List, "Chapters", Modifier.weight(1f), enabled = np.chapters.size > 1) { showChapters = true }
                ActionTile(Icons.Default.Download, "Download", Modifier.weight(1f)) {
                    scope.launch { Services.downloads.download(np.itemId) }
                }
                ActionTile(
                    Icons.Default.NightsStay,
                    "Sleep",
                    Modifier.weight(1f),
                    highlighted = sleep !is SleepMode.Off,
                ) { showSleep = true }
                ActionTile(Icons.Default.Speed, "Speed", Modifier.weight(1f)) { showSpeed = true }
                ActionTile(Icons.Default.MoreVert, "More", Modifier.weight(1f)) {}
            }

            Box(Modifier.height(16.dp))
        }
    }

    if (showSleep) {
        SleepTimerSheet(
            onDismiss = { showSleep = false },
            onDuration = { Services.sleepTimer.startDuration(it); showSleep = false },
            onEndOfChapter = { Services.sleepTimer.startEndOfChapter(); showSleep = false },
            onCancel = { Services.sleepTimer.cancel(); showSleep = false },
        )
    }
    if (showSpeed) {
        SpeedSheet(
            current = runCatching { controller.player.playbackParameters.speed }.getOrDefault(1f),
            onPick = { controller.setSpeed(it.toDouble()); showSpeed = false },
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
}
