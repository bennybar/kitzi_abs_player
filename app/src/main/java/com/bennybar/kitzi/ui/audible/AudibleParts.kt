package com.bennybar.kitzi.ui.audible

import android.content.Context
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.MenuBook
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.StarBorder
import androidx.compose.material.icons.filled.StarHalf
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.ImageLoader
import coil.compose.AsyncImage
import coil.disk.DiskCache
import com.bennybar.kitzi.data.audible.AudibleBook
import com.bennybar.kitzi.data.audible.AudibleGenre
import com.bennybar.kitzi.ui.common.formatCount
import com.bennybar.kitzi.ui.common.formatHm
import java.util.Locale
import kotlin.math.floor

/** A list of Audible books: an author's, a narrator's, or a series' in order. */
sealed interface AudibleListRoute {
    data class Author(val name: String) : AudibleListRoute
    data class Narrator(val name: String) : AudibleListRoute
    data class Series(val asin: String, val title: String) : AudibleListRoute
}

/** Where the Audible screens go: a library book, an Audible book, a genre, a list, Find Book. */
class KitziNav(
    val openBook: (String) -> Unit,
    val openAudible: (AudibleBook) -> Unit,
    val openGenre: (AudibleGenre) -> Unit,
    val openList: (AudibleListRoute) -> Unit,
    val findBook: (String) -> Unit,
    val openAchew: () -> Unit = {},
)

val LocalKitziNav = compositionLocalOf { KitziNav({}, {}, {}, {}, {}) }

/**
 * Audible covers load through their own image loader: the app's loader signs every
 * request for the user's server (the token, any Cloudflare Access headers), and
 * that mustn't go to Amazon.
 */
object AudibleImages {
    @Volatile private var loader: ImageLoader? = null

    fun loader(context: Context): ImageLoader = loader ?: synchronized(this) {
        loader ?: ImageLoader.Builder(context.applicationContext)
            .okHttpClient { okhttp3.OkHttpClient() }
            .diskCache {
                DiskCache.Builder()
                    .directory(context.applicationContext.cacheDir.resolve("audible-covers"))
                    .maxSizeBytes(150L * 1024 * 1024)
                    .build()
            }
            .crossfade(true)
            .build()
            .also { loader = it }
    }
}

@Composable
fun AudibleImage(url: String?, modifier: Modifier = Modifier) {
    val context = LocalContext.current
    Box(modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh), contentAlignment = Alignment.Center) {
        Icon(Icons.AutoMirrored.Filled.MenuBook, null, tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f))
        if (url != null) {
            AsyncImage(
                model = url,
                contentDescription = null,
                imageLoader = AudibleImages.loader(context),
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
    }
}

@Composable
fun AudibleCover(url: String?, size: Dp, modifier: Modifier = Modifier) {
    AudibleImage(url, modifier.size(size).clip(RoundedCornerShape(size * 0.12f)))
}

private val Amber = Color(0xFFF6A609)

/** Stars, the average, and how many rated it (when [count] > 0). */
@Composable
fun StarsRow(stars: Double, count: Int, starSize: Dp = 14.dp, modifier: Modifier = Modifier) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(1.dp)) {
        val full = floor(stars).toInt()
        val frac = stars - full
        val fullCount = if (frac >= 0.75) full + 1 else full
        val half = frac >= 0.25 && frac < 0.75
        for (i in 0 until 5) {
            when {
                i < fullCount -> Icon(Icons.Default.Star, null, tint = Amber, modifier = Modifier.size(starSize))
                i == fullCount && half -> Icon(Icons.Default.StarHalf, null, tint = Amber, modifier = Modifier.size(starSize))
                else -> Icon(Icons.Default.StarBorder, null, tint = Amber.copy(alpha = 0.3f), modifier = Modifier.size(starSize))
            }
        }
        Text(
            String.format(Locale.US, "%.1f", stars),
            fontSize = (starSize.value * 0.9f).sp,
            fontWeight = FontWeight.Bold,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(start = 5.dp),
        )
        if (count > 0) {
            Text(
                "(${formatCount(count)})",
                fontSize = (starSize.value * 0.85f).sp,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 3.dp),
            )
        }
    }
}

/** "In Library", as a small tinted badge. */
@Composable
fun InLibraryBadge() {
    Text(
        "In Library",
        style = MaterialTheme.typography.labelSmall,
        fontWeight = FontWeight.Bold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier
            .clip(RoundedCornerShape(50))
            .background(MaterialTheme.colorScheme.primary.copy(alpha = 0.15f))
            .padding(horizontal = 6.dp, vertical = 2.dp),
    )
}

/** An Audible book in a list: cover, title, author, stars, length · format · year. */
@Composable
fun AudibleRow(
    book: AudibleBook,
    inLibrary: Boolean,
    modifier: Modifier = Modifier,
    /** A line under the row ("Book 4 · Coming 12 Mar 2027"). */
    note: String? = null,
    /** Its place in a ranked list. */
    rank: Int? = null,
    onClick: () -> Unit,
) {
    Row(
        modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        rank?.let {
            Text(
                "$it",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = androidx.compose.ui.text.style.TextAlign.End,
                modifier = Modifier.width(28.dp).padding(end = 6.dp),
            )
        }
        AudibleCover(book.thumbUrl, 64.dp)
        Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(book.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            book.author?.let {
                Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            book.stars?.let { StarsRow(it, book.ratingCount, 12.dp) }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                val meta = listOfNotNull(book.minutes?.let { formatHm(it * 60L) }, book.format, book.year).joinToString(" · ")
                if (meta.isNotEmpty()) {
                    Text(meta, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                }
                if (inLibrary) InLibraryBadge()
            }
            note?.let {
                Text(it, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary)
            }
        }
    }
}

/** A gently pulsing block holding a section's place while it loads. */
@Composable
fun LoadingBlock(height: Dp, modifier: Modifier = Modifier, radius: Dp = 20.dp) {
    val t = rememberInfiniteTransition(label = "pulse")
    val a by t.animateFloat(0.45f, 0.9f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha")
    Box(
        modifier.fillMaxWidth().height(height).graphicsLayer { alpha = a }
            .clip(RoundedCornerShape(radius)).background(MaterialTheme.colorScheme.surfaceContainer),
    )
}

/** A row-shaped placeholder for a list that's loading. */
@Composable
fun LoadingRow() {
    val t = rememberInfiniteTransition(label = "pulse")
    val a by t.animateFloat(0.45f, 0.9f, infiniteRepeatable(tween(900), RepeatMode.Reverse), label = "alpha")
    Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).graphicsLayer { alpha = a }, verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.size(64.dp).clip(RoundedCornerShape(8.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh))
        Column(Modifier.padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Box(Modifier.size(180.dp, 14.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh))
            Box(Modifier.size(120.dp, 12.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh))
            Box(Modifier.size(90.dp, 10.dp).clip(RoundedCornerShape(4.dp)).background(MaterialTheme.colorScheme.surfaceContainerHigh))
        }
    }
}

/**
 * Audible books in the Material 3 Expressive carousel (as the home shelves): the
 * cover, and over it the title, stars and author; a check on books in the library.
 */
@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun AudibleCarousel(books: List<AudibleBook>, inLibrary: Set<String>, onOpen: (AudibleBook) -> Unit) {
    val state = androidx.compose.material3.carousel.rememberCarouselState { books.size }
    androidx.compose.material3.carousel.HorizontalMultiBrowseCarousel(
        state = state,
        preferredItemWidth = 170.dp,
        modifier = Modifier.fillMaxWidth().height(190.dp),
        itemSpacing = 8.dp,
        contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 16.dp),
    ) { i ->
        val book = books[i]
        val info = carouselItemDrawInfo
        val textAlpha = if (info.maxSize > info.minSize) {
            ((info.size - info.minSize) / (info.maxSize - info.minSize) * 1.6f - 0.6f).coerceIn(0f, 1f)
        } else 1f
        Box(Modifier.fillMaxSize().maskClip(MaterialTheme.shapes.extraLarge).clickable { onOpen(book) }) {
            AudibleImage(book.coverUrl, Modifier.fillMaxSize())
            Column(
                Modifier
                    .align(Alignment.BottomStart)
                    .fillMaxWidth()
                    .graphicsLayer { alpha = textAlpha }
                    .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.82f))))
                    .padding(start = 12.dp, end = 12.dp, top = 28.dp, bottom = 12.dp),
            ) {
                Text(book.title, style = MaterialTheme.typography.bodyLarge, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Row(verticalAlignment = Alignment.CenterVertically) {
                    book.stars?.let {
                        Icon(Icons.Default.Star, null, tint = Amber, modifier = Modifier.size(13.dp))
                        Text(String.format(Locale.US, "%.1f", it), style = MaterialTheme.typography.bodySmall, fontWeight = FontWeight.SemiBold,
                            color = Color.White.copy(alpha = 0.85f), modifier = Modifier.padding(start = 2.dp, end = 4.dp))
                    }
                    book.authors.firstOrNull()?.let {
                        Text(if (book.stars != null) "· $it" else it, style = MaterialTheme.typography.bodySmall,
                            color = Color.White.copy(alpha = 0.85f), maxLines = 1, overflow = TextOverflow.Ellipsis)
                    }
                }
            }
            if (book.asin in inLibrary) {
                Icon(
                    Icons.Default.CheckCircle, "In your library",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.align(Alignment.TopEnd).padding(8.dp).size(24.dp)
                        .graphicsLayer { alpha = textAlpha }.clip(RoundedCornerShape(50)).background(Color.White),
                )
            }
        }
    }
}

/** A titled section on a page ("Listeners Also Enjoyed"). */
@Composable
fun SectionTitle(text: String, modifier: Modifier = Modifier) {
    Text(text, style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold, modifier = modifier)
}
