package com.bennybar.kitzi.ui.common

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
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
 * A book's Audible community stars: the saved value at once, refreshed in place
 * when it's old. Nothing until Audible has a rating for it.
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
        val book = com.bennybar.kitzi.data.Services.books.getBook(itemId)
            ?: com.bennybar.kitzi.data.model.Book(
                id = itemId, title = title, author = author, coverUrl = "", description = null,
                durationMs = durationMs, sizeBytes = null, updatedAt = null, addedAt = null, series = null,
                seriesSequence = null, collection = null, collectionSequence = null, isAudioBook = true,
                mediaKind = null, libraryId = null, authors = emptyList(), narrators = emptyList(),
                publisher = null, publishYear = null, genres = emptyList(),
            )
        AudibleRatingService.lookup(book)?.let { rating = it }
    }

    val r = rating ?: return
    if (r.stars <= 0.0) return
    val stars = r.stars
    val count = r.count
    val asin = r.asin.takeIf { it.isNotEmpty() }

    val amber = Color(0xFFF6A609)
    val muted = MaterialTheme.colorScheme.onSurfaceVariant

    // Tapping the rating opens the book's Audible page (or a search for it) in the
    // browser — toggleable in Settings, on by default.
    val context = LocalContext.current
    val linkMod = if (com.bennybar.kitzi.ui.UiPrefsState.audibleLink.value) {
        val url = asin?.let { "https://www.audible.com/pd/$it" }
            ?: ("https://www.audible.com/search?keywords=" +
                Uri.encode(listOfNotNull(title, author).joinToString(" ")))
        Modifier
            .clip(RoundedCornerShape(8.dp))
            .clickable {
                runCatching {
                    context.startActivity(
                        Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                    )
                }
            }
    } else Modifier

    Row(modifier.then(linkMod), horizontalArrangement = Arrangement.spacedBy(1.dp), verticalAlignment = Alignment.CenterVertically) {
        val full = floor(stars).toInt()
        val frac = stars - full
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
            String.format(Locale.US, "%.1f", stars),
            fontSize = (starSize.value * 0.85f).sp,
            fontWeight = FontWeight.Bold,
            color = muted,
            modifier = Modifier.padding(start = 6.dp),
        )
        if (showCount && count > 0) {
            Text(
                "(${formatCount(count)})",
                fontSize = (starSize.value * 0.78f).sp,
                color = muted.copy(alpha = 0.85f),
                modifier = Modifier.padding(start = 4.dp),
            )
        }
    }
}

fun formatCount(n: Int): String =
    if (n >= 1000) String.format(Locale.US, "%.1fk", n / 1000.0).replace(".0k", "k") else n.toString()
