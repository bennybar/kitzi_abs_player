package com.bennybar.kitzi.ui.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.StarHalf
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.bennybar.kitzi.data.audible.AudibleRatingService
import java.util.Locale
import kotlin.math.floor

/**
 * A cached Audible community star rating for a book: shows the cached value
 * immediately and refreshes in place when it's stale (>24h). Renders nothing
 * until a confident rating exists — matching the Flutter widget.
 */
@Composable
fun AudibleStars(
    itemId: String,
    title: String,
    author: String? = null,
    narrator: String? = null,
    durationMs: Long? = null,
    starSize: Dp = 16.dp,
    showCount: Boolean = true,
    modifier: Modifier = Modifier,
) {
    var rating by remember(itemId) { mutableStateOf(AudibleRatingService.peek(itemId)) }
    LaunchedEffect(itemId) {
        AudibleRatingService.loadCached(itemId)?.let { rating = it }
        AudibleRatingService.resolve(itemId, title, author, narrator, durationMs)?.let { rating = it }
    }

    val r = rating ?: return
    if (!r.found || r.rating <= 0.0) return

    val amber = Color(0xFFF6A609)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.CenterVertically) {
        val full = floor(r.rating).toInt()
        val frac = r.rating - full
        val fullCount = if (frac >= 0.75) full + 1 else full
        val hasHalf = frac >= 0.25 && frac < 0.75
        for (i in 0 until 5) {
            when {
                i < fullCount -> Icon(Icons.Default.Star, null, tint = amber, modifier = Modifier.size(starSize))
                i == fullCount && hasHalf -> Icon(Icons.Default.StarHalf, null, tint = amber, modifier = Modifier.size(starSize))
                else -> Icon(Icons.Default.StarBorder, null, tint = amber.copy(alpha = 0.30f), modifier = Modifier.size(starSize))
            }
        }
        Text(
            String.format(Locale.US, "%.1f", r.rating),
            fontSize = (starSize.value * 0.85f).sp,
            fontWeight = FontWeight.Bold,
            color = muted,
            modifier = Modifier.padding(start = 6.dp),
        )
        if (showCount && (r.count ?: 0) > 0) {
            Text(
                "(${formatCount(r.count!!)})",
                fontSize = (starSize.value * 0.78f).sp,
                color = muted.copy(alpha = 0.85f),
                modifier = Modifier.padding(start = 4.dp),
            )
        }
    }
}

private fun formatCount(n: Int): String =
    if (n >= 1000) String.format(Locale.US, "%.1fk", n / 1000.0).replace(".0k", "k") else n.toString()
