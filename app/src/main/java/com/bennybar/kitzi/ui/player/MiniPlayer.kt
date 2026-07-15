package com.bennybar.kitzi.ui.player

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Forward30
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Replay30
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import kotlin.math.abs
import kotlin.math.sin
import kotlinx.coroutines.delay

/**
 * The floating "Aurora Glass" mini-player, matching the Flutter widget: a
 * rounded pill tinted from the cover palette, hovering above the nav bar. The
 * cover is circular; tapping it collapses the bar into a left-aligned orb (cover
 * with a progress ring + a play button), and tapping the orb expands it again.
 * Tapping the bar body opens the full player. The collapsed/expanded choice is
 * persisted in the same pref the Flutter app used.
 */
@Composable
fun MiniPlayer(onExpand: () -> Unit) {
    val controller = Services.playback
    val nowPlaying by controller.nowPlaying.collectAsStateWithLifecycle()
    val np = nowPlaying ?: return

    var isPlaying by remember { mutableStateOf(false) }
    var fraction by remember { mutableStateOf(0f) }
    var collapsed by remember { mutableStateOf(Services.prefs.getBoolean("ui_mini_player_collapsed", false)) }

    LaunchedEffect(np.itemId) {
        while (true) {
            isPlaying = runCatching { controller.player.isPlaying }.getOrDefault(false)
            val pos = controller.globalPositionSec() ?: 0.0
            val total = controller.totalDurationSec() ?: 0.0
            fraction = if (total > 0) (pos / total).toFloat().coerceIn(0f, 1f) else 0f
            delay(700)
        }
    }

    fun setCollapsed(value: Boolean) {
        collapsed = value
        Services.prefs.putBoolean("ui_mini_player_collapsed", value)
    }

    // Theme-aware tinted surface: start from the theme's own container colour (so
    // it's light in light mode, dark in dark mode) and wash it faintly with the
    // cover's colour. Text stays onSurface, which contrasts in both themes.
    val palette by rememberCoverPalette(np.coverUrl)
    val base = MaterialTheme.colorScheme.surfaceContainerHigh
    val seed = palette?.primary ?: MaterialTheme.colorScheme.primary
    val glassA = blend(seed, base, 0.16f)
    val glassB = blend(seed, base, 0.06f)
    val glass = Brush.linearGradient(listOf(glassA, glassB))
    val onGlass = MaterialTheme.colorScheme.onSurface
    val onGlassMuted = MaterialTheme.colorScheme.onSurfaceVariant

    val togglePlay = {
        val p = controller.player
        if (p.isPlaying) p.pause() else p.play()
    }

    if (collapsed) {
        // Left-aligned orb: circular cover with a progress ring + a round play button.
        Row(
            Modifier.padding(start = 12.dp, end = 12.dp, top = 4.dp, bottom = 4.dp),
        ) {
            Row(
                Modifier
                    .shadow(12.dp, RoundedCornerShape(37.dp))
                    .clip(RoundedCornerShape(37.dp))
                    .background(glass)
                    .clickable { setCollapsed(false) }
                    .padding(horizontal = 12.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(56.dp), contentAlignment = Alignment.Center) {
                    ProgressRing(fraction, Modifier.size(56.dp))
                    AsyncImage(
                        model = np.coverUrl,
                        contentDescription = np.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.size(48.dp).clip(CircleShape),
                    )
                }
                RoundPlayButton(isPlaying, Modifier.padding(start = 12.dp), togglePlay)
            }
        }
        return
    }

    Box(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp)) {
        Row(
            Modifier
                .fillMaxWidth()
                .shadow(14.dp, RoundedCornerShape(28.dp))
                .clip(RoundedCornerShape(28.dp))
                .background(glass)
                .clickable(onClick = onExpand)
                .padding(start = 13.dp, end = 12.dp, top = 8.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Tap the cover to collapse to the orb.
            AsyncImage(
                model = np.coverUrl,
                contentDescription = np.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier
                    .size(50.dp)
                    .clip(CircleShape)
                    .clickable { setCollapsed(true) },
            )
            Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                Text(
                    np.title,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                    color = onGlass,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Waveform(
                    fraction = fraction,
                    seed = np.title.hashCode(),
                    played = MaterialTheme.colorScheme.primary,
                    rest = onGlassMuted.copy(alpha = 0.35f),
                    modifier = Modifier.fillMaxWidth().height(20.dp).padding(top = 2.dp),
                )
            }
            Icon(
                Icons.Default.Replay30,
                "Rewind",
                tint = onGlass,
                modifier = Modifier.size(26.dp).clip(CircleShape).clickable { controller.seekBackward() },
            )
            RoundPlayButton(isPlaying, Modifier.padding(horizontal = 6.dp), togglePlay)
            Icon(
                Icons.Default.Forward30,
                "Forward",
                tint = onGlass,
                modifier = Modifier.size(26.dp).clip(CircleShape).clickable { controller.seekForward() },
            )
        }
    }
}

@Composable
private fun RoundPlayButton(isPlaying: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .size(46.dp)
            .clip(CircleShape)
            .background(MaterialTheme.colorScheme.primary)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
            if (isPlaying) "Pause" else "Play",
            tint = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier.size(24.dp),
        )
    }
}

@Composable
private fun ProgressRing(fraction: Float, modifier: Modifier = Modifier) {
    val track = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.18f)
    val active = MaterialTheme.colorScheme.primary
    Canvas(modifier) {
        val stroke = 3.dp.toPx()
        drawArc(track, -90f, 360f, false, style = Stroke(stroke, cap = StrokeCap.Round))
        drawArc(active, -90f, 360f * fraction.coerceIn(0f, 1f), false, style = Stroke(stroke, cap = StrokeCap.Round))
    }
}

/** A slim audio-style waveform doubling as the progress indicator. */
@Composable
private fun Waveform(
    fraction: Float,
    seed: Int,
    played: Color,
    rest: Color,
    modifier: Modifier = Modifier,
) {
    Canvas(modifier) {
        val bars = 44
        val gap = size.width / bars
        val barWidth = gap * 0.5f
        for (i in 0 until bars) {
            // Deterministic pseudo-waveform so a book's bars are stable frame to frame.
            val h = (0.35f + 0.65f * abs(sin((i * 12.9898 + seed) * 0.5)).toFloat())
            val barHeight = size.height * h
            val x = i * gap + gap / 2
            val top = (size.height - barHeight) / 2
            drawLine(
                color = if (i.toFloat() / bars <= fraction) played else rest,
                start = Offset(x, top),
                end = Offset(x, top + barHeight),
                strokeWidth = barWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}
