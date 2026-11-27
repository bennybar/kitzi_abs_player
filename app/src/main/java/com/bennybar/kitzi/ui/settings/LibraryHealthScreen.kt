package com.bennybar.kitzi.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.automirrored.filled.Notes
import androidx.compose.material.icons.filled.HealthAndSafety
import androidx.compose.material.icons.filled.Image
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.audible.AudibleRatingService
import com.bennybar.kitzi.data.audible.SeriesSync
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.audible.AudibleChaptersDialog
import com.bennybar.kitzi.ui.audible.LocalKitziNav
import com.bennybar.kitzi.ui.browse.BrowseEmptyState
import com.bennybar.kitzi.ui.common.KitziLoading
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.Snackbars
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

private enum class Issue(val title: String, val icon: ImageVector, val fix: String, val explain: String) {
    COVER("No Cover", Icons.Default.Image, "Quick Match", QUICK_MATCH),
    DESCRIPTION("No Description", Icons.AutoMirrored.Filled.Notes, "Quick Match", QUICK_MATCH),
    NARRATOR("No Narrator", Icons.Default.Mic, "Quick Match", QUICK_MATCH),
    ASIN(
        "Not Matched to Audible", Icons.Default.Link, "Match",
        "Finds the book on Audible and saves its id to your server, so ratings, reviews and series work directly.",
    ),
    CHAPTERS(
        "No Chapters", Icons.AutoMirrored.Filled.List, "Chapters",
        "Long books with one chapter or none. Shows Audible's chapters to compare before you apply them.",
    ),
    NO_SERIES(
        "No Series", Icons.AutoMirrored.Filled.LibraryBooks, "Sync",
        "Audible puts these in a series your server doesn't have for them. Sync saves Audible's series and book number to your server.",
    ),
    SERIES(
        "Series Differs from Audible", Icons.Default.SwapHoriz, "Sync",
        "Your server and Audible disagree on these (before → after). Sync changes them to Audible's. Check them: Audible " +
            "sometimes numbers by publication rather than reading order. Series Audible doesn't list are kept.",
    );

    fun applies(b: Book, series: Map<String, SeriesSync.Change>?): Boolean = when (this) {
        COVER -> b.hasCover == false
        DESCRIPTION -> b.description.isNullOrBlank()
        NARRATOR -> b.narrators.isEmpty()
        ASIN -> b.asin == null
        CHAPTERS -> (b.chapterCount ?: 2) <= 1 && (b.durationMs ?: 0) > 2 * 3600_000L
        NO_SERIES -> series?.get(b.id)?.before?.isEmpty() == true
        SERIES -> series?.get(b.id)?.before?.isNotEmpty() == true
    }
}

/** Fix All runs here, as Radar's checks do, so leaving the screen doesn't stop it halfway (and skip the sync). */
private val fixAllScope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

private const val QUICK_MATCH = "Quick Match asks your server to fill in what's missing from Audible. What the book already has is kept."

/**
 * Settings › Library Health: what the library's books are missing (a cover, a
 * description, the narrator, Audible's id, chapters, their series), each with a
 * fix from Audible: the server's Quick Match (fills only what's missing),
 * Audible's id, Audible's chapters, or Audible's series.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryHealthScreen(onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    val scope = rememberCoroutineScope()
    var reload by remember { mutableIntStateOf(0) }
    var refreshing by remember { mutableStateOf(false) }
    var books by remember { mutableStateOf<List<Book>?>(null) }
    /** Books whose series differ from Audible's (null while checking). */
    var seriesChanges by remember { mutableStateOf<Map<String, SeriesSync.Change>?>(null) }
    var working by remember { mutableStateOf(emptySet<String>()) }
    var done by remember { mutableStateOf(emptySet<String>()) }
    var chaptersFor by remember { mutableStateOf<Book?>(null) }
    var confirmAll by remember { mutableStateOf<Issue?>(null) }

    LaunchedEffect(reload) {
        val all = Services.books.allAudiobooks()
        books = all
        seriesChanges = null
        seriesChanges = SeriesSync.check(all)
    }

    fun key(b: Book, i: Issue) = "${i.name}|${b.id}"
    val groups = remember(books, seriesChanges, done) {
        Issue.entries.map { i -> i to books.orEmpty().filter { key(it, i) !in done && i.applies(it, seriesChanges) } }
    }

    /** Null, or why it couldn't. */
    suspend fun fix(b: Book, issue: Issue, quiet: Boolean = false): String? {
        val k = key(b, issue)
        working = working + k
        val why = try {
            when (issue) {
                Issue.SERIES, Issue.NO_SERIES -> SeriesSync.apply(b)
                Issue.ASIN -> AudibleRatingService.asin(b)?.let { asin ->
                    if (Services.books.saveAsinIfMissing(b.id, asin)) null else "Couldn't save Audible's id for ${b.title}."
                } ?: "Audible doesn't have ${b.title}."
                else -> Services.books.quickMatch(b.id, b.title, b.authors.firstOrNull() ?: b.author, b.asin)
            }
        } finally {
            working = working - k
        }
        if (why == null) done = done + k else if (!quiet) Snackbars.show(why)
        return why
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.HealthAndSafety, title = "Library Health", onBack = onBack)
        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = { scope.launch { refreshing = true; Services.books.syncAll(); reload++; refreshing = false } },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (books != null && seriesChanges != null && groups.all { it.second.isEmpty() }) {
                BrowseEmptyState(Icons.Default.Verified, "All in order", "Every book has a cover, a description, its narrator, Audible's id and chapters.")
            } else LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp, top = 8.dp, end = 16.dp,
                    bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                ),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                if (seriesChanges == null) {
                    item {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            KitziLoading(Modifier.size(22.dp))
                            Text(
                                "Comparing series with Audible…",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                modifier = Modifier.padding(start = 10.dp),
                            )
                        }
                    }
                }
                for ((issue, list) in groups) {
                    if (list.isEmpty()) continue
                    item(key = issue.name) {
                        Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(issue.icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                            Text(
                                "${issue.title} · ${list.size}",
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                modifier = Modifier.weight(1f).padding(start = 10.dp),
                            )
                            if (issue != Issue.CHAPTERS && list.size > 1) {
                                TextButton(onClick = { confirmAll = issue }) { Text("Fix All") }
                            }
                        }
                    }
                    items(list.take(50), key = { key(it, issue) }) { b ->
                        Surface(
                            color = MaterialTheme.colorScheme.surfaceContainer,
                            shape = RoundedCornerShape(18.dp),
                            modifier = Modifier.fillMaxWidth().clickable { nav.openBook(b.id) },
                        ) {
                            Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
                                AsyncImage(
                                    model = b.coverUrl,
                                    contentDescription = null,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.size(44.dp).clip(RoundedCornerShape(8.dp)),
                                )
                                Column(Modifier.weight(1f).padding(horizontal = 12.dp)) {
                                    Text(b.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    val change = seriesChanges?.get(b.id)?.takeIf { issue == Issue.SERIES || issue == Issue.NO_SERIES }
                                    if (change != null) {
                                        Text(change.summary, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                    } else {
                                        b.author?.let {
                                            Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                        }
                                    }
                                }
                                if (key(b, issue) in working) {
                                    KitziLoading(Modifier.size(32.dp))
                                } else {
                                    FilledTonalButton(onClick = {
                                        if (issue == Issue.CHAPTERS) chaptersFor = b else scope.launch { fix(b, issue) }
                                    }) { Text(issue.fix) }
                                }
                            }
                        }
                    }
                    item {
                        if (list.size > 50) {
                            Text("and ${list.size - 50} more", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                        Text(issue.explain, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        }
    }

    chaptersFor?.let { b ->
        AudibleChaptersDialog(b, onDismiss = { chaptersFor = null }) { done = done + key(b, Issue.CHAPTERS) }
    }

    confirmAll?.let { issue ->
        val list = groups.first { it.first == issue }.second
        AlertDialog(
            onDismissRequest = { confirmAll = null },
            title = { Text("Fix all of them?") },
            text = {
                Text(
                    when (issue) {
                        Issue.ASIN -> "Each book is looked up on Audible, and the id is saved to your server when it's found."
                        Issue.NO_SERIES -> "Audible's series and book numbers are added to these books on your server."
                        Issue.SERIES -> "These books' series and numbers on your server are changed to Audible's. It can't be undone from Kitzi."
                        else -> "Your server fills in what each book is missing from Audible. What they already have is kept."
                    }
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    confirmAll = null
                    fixAllScope.launch {
                        var failed = 0
                        for (b in list) if (fix(b, issue, quiet = true) != null) failed++
                        Snackbars.show(if (failed == 0) "Fixed ${list.size} books" else "Fixed ${list.size - failed} of ${list.size}")
                        // The server's changes, into the library.
                        Services.books.syncAll()
                        done = emptySet()
                        reload++
                    }
                }) { Text("Fix ${list.size} Books") }
            },
            dismissButton = { TextButton(onClick = { confirmAll = null }) { Text("Cancel") } },
        )
    }
}
