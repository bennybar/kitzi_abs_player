package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Collections
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SecondaryTabRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Tab
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.SeriesRow
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.library.BookCard

private enum class SeriesTab { SERIES, COLLECTIONS }

/** One row in the browse list, whether a series or a collection. */
private data class Group(val name: String, val count: Int, val coverUrls: List<String>)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeriesScreen(onOpenBook: (String) -> Unit, onBack: () -> Unit) {
    var tab by remember { mutableStateOf(SeriesTab.SERIES) }
    var series by remember { mutableStateOf<List<SeriesRow>>(emptyList()) }
    var collections by remember { mutableStateOf<Map<String, List<Book>>>(emptyMap()) }
    var search by remember { mutableStateOf("") }
    var expanded by remember { mutableStateOf<String?>(null) }
    var books by remember { mutableStateOf<List<Book>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }

    val minBooks = Services.prefs.getInt("ui_series_min_books", 1)
    LaunchedEffect(Unit) {
        series = Services.books.seriesWithCovers(minBooks)
        collections = Services.books.collections()
        loading = false
    }
    LaunchedEffect(expanded, tab) {
        books = when (tab) {
            SeriesTab.SERIES -> expanded?.let { Services.books.booksInSeries(it) }.orEmpty()
            SeriesTab.COLLECTIONS -> expanded?.let { collections[it] }.orEmpty()
        }
    }

    val groups = when (tab) {
        SeriesTab.SERIES -> series.map { Group(it.name, it.bookCount, it.coverUrls) }
        SeriesTab.COLLECTIONS -> collections.map { (name, items) ->
            Group(name, items.size, items.take(3).map { it.coverUrl })
        }
    }.filter { it.name.contains(search, ignoreCase = true) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = if (tab == SeriesTab.SERIES) Icons.Default.LibraryBooks else Icons.Default.Collections,
            title = if (tab == SeriesTab.SERIES) "Series" else "Collections",
            subtitle = "${groups.size} in library",
            onBack = onBack,
        )

        SecondaryTabRow(selectedTabIndex = tab.ordinal) {
            SeriesTab.entries.forEach { t ->
                Tab(
                    selected = tab == t,
                    onClick = { tab = t; expanded = null },
                    text = { Text(t.name.lowercase().replaceFirstChar { it.uppercase() }) },
                )
            }
        }

        KitziSearchField(
            search, { search = it },
            if (tab == SeriesTab.SERIES) "Search series…" else "Search collections…",
            Modifier.padding(vertical = 8.dp),
        )

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            groups.isEmpty() -> BrowseEmptyState(
                icon = if (tab == SeriesTab.SERIES) Icons.Default.LibraryBooks else Icons.Default.Collections,
                title = when {
                    search.isNotBlank() -> "No matches"
                    tab == SeriesTab.SERIES -> "No series yet"
                    else -> "No collections yet"
                },
                message = if (search.isNotBlank()) "Try adjusting your search terms"
                else "${if (tab == SeriesTab.SERIES) "Series" else "Collections"} appear when books are grouped together",
            )
            else -> LazyColumn(
                contentPadding = androidx.compose.foundation.layout.PaddingValues(
                    start = 16.dp, top = 16.dp, end = 16.dp,
                    bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(groups, key = { it.name }) { group ->
                    Column {
                        Surface(
                            color = MaterialTheme.colorScheme.surfaceContainer,
                            shape = RoundedCornerShape(18.dp),
                            modifier = Modifier
                                .fillMaxWidth()
                                .clickable { expanded = if (expanded == group.name) null else group.name },
                        ) {
                            Row(
                                Modifier.padding(12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                FannedCover(group.coverUrls)
                                Column(Modifier.weight(1f).padding(start = 14.dp)) {
                                    Text(
                                        group.name,
                                        style = MaterialTheme.typography.titleMedium,
                                        fontWeight = FontWeight.SemiBold,
                                        maxLines = 2,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    Text(
                                        if (group.count == 1) "1 book" else "${group.count} books",
                                        style = MaterialTheme.typography.bodySmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.primary,
                                        modifier = Modifier.padding(top = 4.dp),
                                    )
                                }
                                Icon(
                                    Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                    null,
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                        }

                        if (expanded == group.name) {
                            // A recessed, indented panel so the member books read
                            // clearly as the CONTENTS of the series above them, not as
                            // more series rows: a darker ground, an inset, and a header.
                            Surface(
                                color = MaterialTheme.colorScheme.surfaceContainerLowest,
                                shape = RoundedCornerShape(14.dp),
                                border = androidx.compose.foundation.BorderStroke(
                                    1.dp, MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f),
                                ),
                                modifier = Modifier.padding(top = 8.dp, start = 20.dp).fillMaxWidth(),
                            ) {
                                Column(
                                    Modifier.padding(12.dp),
                                    verticalArrangement = Arrangement.spacedBy(10.dp),
                                ) {
                                    Text(
                                        "In this ${if (tab == SeriesTab.SERIES) "series" else "collection"}",
                                        style = MaterialTheme.typography.labelMedium,
                                        color = MaterialTheme.colorScheme.primary,
                                        fontWeight = FontWeight.SemiBold,
                                    )
                                    books.forEach { book -> BookCard(book) { onOpenBook(book.id) } }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * A fanned deck of book covers: a hero cover with up to two more peeking behind
 * it, offset, tilted and dimmed. Mirrors the Flutter `_FannedCover`.
 */
@Composable
private fun FannedCover(coverUrls: List<String>, heroWidth: Dp = 46.dp) {
    val w = heroWidth
    val h = w * 1.5f
    val extra = if (coverUrls.size > 1) coverUrls.subList(1, minOf(coverUrls.size, 3)) else emptyList()
    val spread = when (extra.size) { 0 -> 0.dp; 1 -> 14.dp; else -> 24.dp }

    Box(Modifier.size(width = w + spread + 4.dp, height = h + 8.dp)) {
        // Farthest painted first so nearer covers overlap them.
        for (i in extra.indices.reversed()) {
            val step = i + 1
            CoverImage(
                extra[i],
                w, h,
                Modifier
                    .offset(x = spread * step / extra.size)
                    .graphicsLayer {
                        rotationZ = 4.9f * step
                        transformOrigin = TransformOrigin(0f, 1f)
                    }
                    .clip(RoundedCornerShape(7.dp)),
                dim = 0.18f + 0.12f * i,
            )
        }
        // Hero on top with a soft drop shadow.
        CoverImage(
            coverUrls.firstOrNull(),
            w, h,
            Modifier.shadow(6.dp, RoundedCornerShape(8.dp)).clip(RoundedCornerShape(8.dp)),
        )
    }
}

@Composable
private fun CoverImage(url: String?, w: Dp, h: Dp, modifier: Modifier = Modifier, dim: Float = 0f) {
    Box(modifier.size(width = w, height = h)) {
        if (url.isNullOrEmpty()) {
            Box(
                Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surfaceContainerHighest),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.LibraryBooks,
                    null,
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.size(w * 0.4f),
                )
            }
        } else {
            AsyncImage(
                model = url,
                contentDescription = null,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
        }
        if (dim > 0f) Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = dim)))
    }
}

/** Shared centered empty state for the browse screens. */
@Composable
fun BrowseEmptyState(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    title: String,
    message: String,
) {
    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Icon(
                icon,
                null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.size(56.dp),
            )
            Text(
                title,
                style = MaterialTheme.typography.titleLarge,
                modifier = Modifier.padding(top = 16.dp),
            )
            Text(
                message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(top = 8.dp),
            )
        }
    }
}
