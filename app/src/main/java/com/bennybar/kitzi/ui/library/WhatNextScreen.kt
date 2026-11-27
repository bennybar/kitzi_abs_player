package com.bennybar.kitzi.ui.library

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.Casino
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.audible.LocalKitziNav
import com.bennybar.kitzi.ui.browse.BrowseEmptyState
import com.bennybar.kitzi.ui.common.ScreenHeader

/** Everything What Next? picks from, loaded once. */
private class WhatNextData(
    val books: List<Book>,
    val progress: Map<String, MediaProgressEntity>,
    val nextInSeries: List<Book>,
    val stars: Map<String, com.bennybar.kitzi.data.db.AudibleEntity>,
)

/**
 * "What next?": picks from the library, no searching. After a book is finished,
 * what follows it first (the next in its series, more by its author and narrator);
 * then the series you're in the middle of, the quickest listens, the best rated and
 * the ones that have waited longest.
 */
@Composable
fun WhatNextScreen(onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var data by remember { mutableStateOf<WhatNextData?>(null) }
    LaunchedEffect(Unit) {
        data = WhatNextData(
            Services.books.allAudiobooks(),
            Services.books.allProgress(),
            Services.books.continueSeries(),
            Services.books.audibleRatings(),
        )
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.AutoAwesome, title = "What Next?", onBack = onBack)
        val d = data ?: run {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { com.bennybar.kitzi.ui.common.KitziLoading() }
            return@Column
        }
        fun unstarted(b: Book) = d.progress[b.id]?.let { !it.isFinished && it.progress <= 0 } ?: true
        val nextIds = d.nextInSeries.map { it.id }.toSet()
        // Worth starting cold: not started, and not the middle of a series (its next book is fine).
        val startable = d.books.filter { b ->
            unstarted(b) && (b.series == null || (b.seriesSequence ?: 1.0) <= 1 || b.id in nextIds)
        }
        // The book finished most recently, if that was in the last two weeks.
        val done = d.progress.values.filter { it.isFinished }.maxByOrNull { it.lastUpdate }
            ?.takeIf { System.currentTimeMillis() - it.lastUpdate < 14 * 86_400_000L }
            ?.let { p -> d.books.firstOrNull { it.id == p.itemId } }
        val surprise = remember(d) { startable.randomOrNull() }
        val quick = startable.filter { (it.durationMs ?: 0) > 600_000 }.sortedBy { it.durationMs }
        // (Ratings already known: looked up as books are seen, or by the "Highest rated" sort.)
        val rated = startable.filter { (d.stars[it.id]?.count ?: 0) >= 50 }.sortedByDescending { d.stars[it.id]?.stars }
        val waiting = startable.filter { it.addedAt != null }.sortedBy { it.addedAt }

        if (startable.isEmpty() && d.nextInSeries.isEmpty() && done == null) {
            BrowseEmptyState(Icons.Default.Verified, "Nothing waiting", "Every book here is started or finished. Find Book has more.")
            return@Column
        }
        LazyColumn(
            contentPadding = PaddingValues(start = 16.dp, top = 8.dp, end = 16.dp, bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            surprise?.let { b ->
                item(key = "surprise") {
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier.fillMaxWidth().clickable { nav.openBook(b.id) },
                    ) {
                        Column(Modifier.padding(16.dp)) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Icon(Icons.Default.Casino, null)
                                Text("Surprise Me", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold,
                                    modifier = Modifier.padding(start = 10.dp))
                            }
                            Text("Opens a book you haven't started, picked at random.", style = MaterialTheme.typography.bodySmall,
                                modifier = Modifier.padding(top = 4.dp))
                        }
                    }
                }
            }
            if (done != null) {
                header("Because You Finished ${done.title}")
                // The next of its series: your copy, or Audible's with Send to Shelfarr.
                item(key = "next-in-series") { com.bennybar.kitzi.ui.audible.NextInSeriesCard(done) }
                val author = done.authors.firstOrNull() ?: done.author
                val byAuthor = author?.let { a ->
                    d.books.filter { b ->
                        b.id != done.id && unstarted(b) &&
                            (a in b.authors || b.author?.split(",")?.any { it.trim() == a } == true)
                    }
                }.orEmpty()
                if (author != null) rows(byAuthor, "More by $author", "author", d.progress, nav.openBook)
                done.narrators.firstOrNull()?.let { n ->
                    val byNarrator = d.books.filter { b -> b.id != done.id && unstarted(b) && n in b.narrators && b !in byAuthor }
                    rows(byNarrator, "More read by $n", "narrator", d.progress, nav.openBook)
                }
            }
            if (d.nextInSeries.isNotEmpty()) {
                header("Carry On a Series")
                rows(d.nextInSeries, null, "series", d.progress, nav.openBook)
            }
            if (quick.isNotEmpty()) {
                header("Quick Listens")
                rows(quick, null, "quick", d.progress, nav.openBook)
            }
            if (rated.isNotEmpty()) {
                header("Best Rated, Not Started")
                rows(rated, null, "rated", d.progress, nav.openBook, rating = true)
            }
            if (waiting.isNotEmpty()) {
                header("Waiting the Longest")
                rows(waiting, null, "waiting", d.progress, nav.openBook)
            }
        }
    }
}

private fun LazyListScope.header(title: String) {
    item(key = "h-$title") {
        Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold, modifier = Modifier.padding(top = 12.dp))
    }
}

/** Up to five of them, under an optional caption. */
private fun LazyListScope.rows(
    books: List<Book>,
    caption: String?,
    key: String,
    progress: Map<String, MediaProgressEntity>,
    open: (String) -> Unit,
    rating: Boolean = false,
) {
    if (books.isEmpty()) return
    caption?.let {
        item(key = "c-$key") {
            Text(it, style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
    items(books.take(5), key = { "$key-${it.id}" }) { b ->
        BookCard(b, progress = progress[b.id], showRating = rating) { open(b.id) }
    }
}
