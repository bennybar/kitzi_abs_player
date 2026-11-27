package com.bennybar.kitzi.ui.audible

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.audible.AudibleBook
import com.bennybar.kitzi.data.audible.AudibleCatalog
import com.bennybar.kitzi.data.audible.AudibleRatingService
import com.bennybar.kitzi.data.audible.AudibleReview
import com.bennybar.kitzi.data.audible.LibraryMatcher
import com.bennybar.kitzi.data.audible.SeriesRung
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.playback.Chapter
import com.bennybar.kitzi.ui.common.Snackbars
import kotlinx.coroutines.launch
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle
import kotlin.math.abs
import kotlin.math.roundToInt

private val dayFormat = DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM)

private fun coming(b: AudibleBook): String? =
    b.releaseDay?.takeIf { it.isAfter(LocalDate.now()) }?.let { "Coming ${it.format(dayFormat)}" }

// MARK: reviews

/** The most helpful Audible reviews. Nothing when there are none or Audible can't be reached. */
@Composable
fun ReviewsCard(asin: String) {
    var reviews by remember(asin) { mutableStateOf<List<AudibleReview>?>(null) }
    var showAll by remember(asin) { mutableStateOf(false) }
    LaunchedEffect(asin) { reviews = runCatching { AudibleCatalog.reviews(asin) }.getOrDefault(emptyList()) }
    val r = reviews
    when {
        r == null -> LoadingBlock(220.dp)
        r.isNotEmpty() -> Card {
            Text("Reviews", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            // Two to start with (five long reviews ran two screens); the rest on demand.
            (if (showAll) r else r.take(2)).forEachIndexed { i, review ->
                if (i > 0) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                Review(review)
            }
            if (!showAll && r.size > 2) {
                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant.copy(alpha = 0.5f))
                TextButton(onClick = { showAll = true }, contentPadding = PaddingValues(0.dp)) { Text("Show ${r.size - 2} more reviews") }
            }
        }
    }
}

@Composable
private fun Review(r: AudibleReview) {
    var open by remember { mutableStateOf(false) }
    Column(
        Modifier.fillMaxWidth().clickable { open = !open }.animateContentSize(),
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        r.stars?.let { StarsRow(it, 0, 12.dp) }
        r.title?.takeIf { it.isNotBlank() }?.let { Text(it, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold) }
        Text(r.body, style = MaterialTheme.typography.bodyMedium, maxLines = if (open) Int.MAX_VALUE else 5, overflow = TextOverflow.Ellipsis)
        val line = listOfNotNull(r.author, r.date?.format(dayFormat), r.helpful.takeIf { it > 0 }?.let { "$it found helpful" }).joinToString(" · ")
        if (line.isNotEmpty()) Text(line, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

/** Reviews on a library book's page: its Audible match's (none when Audible has no match). */
@Composable
fun LibraryBookReviews(book: Book) {
    var asin by remember(book.id) { mutableStateOf<String?>(null) }
    var matched by remember(book.id) { mutableStateOf(false) }
    LaunchedEffect(book.id) {
        asin = AudibleRatingService.asin(book)
        matched = true
    }
    when {
        asin != null -> ReviewsCard(asin!!)
        !matched -> LoadingBlock(220.dp)
    }
}

// MARK: similar books

/** "Listeners Also Enjoyed": Audible's similar books, in the carousel. Hidden when there are none. */
@Composable
fun SimilarBooksRow(book: Book) {
    val nav = LocalKitziNav.current
    var similar by remember(book.id) { mutableStateOf<List<AudibleBook>?>(null) }
    LaunchedEffect(book.id) {
        val asin = AudibleRatingService.asin(book)
        similar = asin?.let { a -> runCatching { AudibleCatalog.similar(a, AudibleRatingService.language(book)) }.getOrNull() }.orEmpty()
    }
    val inLibrary = rememberInLibrary(similar)
    val s = similar
    if (s != null && s.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        SectionTitle("Listeners Also Enjoyed")
        if (s == null) LoadingBlock(190.dp, radius = 28.dp)
        // Edge to edge: the page's own padding is undone.
        else Column(Modifier.fillMaxWidth().layoutWide()) {
            AudibleCarousel(s, inLibrary.keys) { nav.openAudible(it) }
        }
    }
}

/** Widens a child by the page's 16dp side padding, so a carousel runs to the screen edges. */
private fun Modifier.layoutWide() = layout { measurable, constraints ->
    val extra = 32.dp.roundToPx()
    val placeable = measurable.measure(constraints.copy(minWidth = constraints.maxWidth + extra, maxWidth = constraints.maxWidth + extra))
    layout(constraints.maxWidth, placeable.height) { placeable.place(-extra / 2, 0) }
}

// MARK: series

/**
 * On a library book's page: the next book of its series on Audible. Opens the
 * library's copy when it's here, else its Audible page (with Send to Shelfarr under
 * the card). A book the server has no series (or number) for uses Audible's.
 */
@Composable
fun NextInSeriesCard(book: Book) {
    val nav = LocalKitziNav.current
    var next by remember(book.id) { mutableStateOf<AudibleBook?>(null) }
    var number by remember(book.id) { mutableStateOf<String?>(null) }
    var mine by remember(book.id) { mutableStateOf<Book?>(null) }
    /** The series' name: the server's, else Audible's. */
    var seriesName by remember(book.id) { mutableStateOf(book.series) }
    var looked by remember(book.id) { mutableStateOf(false) }
    LaunchedEffect(book.id) {
        try {
            val name = book.series
            val sequence = book.seriesSequence
            val found: Pair<AudibleBook.SeriesRef, String?>
            val current: Double
            if (name != null && sequence != null) {
                val inSeries = Services.books.booksInSeries(name)
                found = runCatching { AudibleCatalog.seriesFor(name, listOf(book) + inSeries.filter { it.id != book.id }) }.getOrNull() ?: return@LaunchedEffect
                current = sequence
            } else {
                // No series (or no number) on the server: Audible's own, from the book's Audible match.
                val asin = AudibleRatingService.asin(book) ?: return@LaunchedEffect
                val product = runCatching { AudibleCatalog.product(asin) }.getOrNull() ?: return@LaunchedEffect
                val ref = product.seriesRefs.firstOrNull() ?: return@LaunchedEffect
                current = AudibleCatalog.numbers(ref.sequence).firstOrNull() ?: return@LaunchedEffect
                found = ref to product.language
                seriesName = ref.title
            }
            val all = runCatching { AudibleCatalog.seriesBooks(found.first, found.second) }.getOrNull() ?: return@LaunchedEffect
            // The first single book numbered after this one (not a box set, not a placeholder date).
            val today = LocalDate.now()
            val candidate = all.firstOrNull { b ->
                val ns = AudibleCatalog.numbers(AudibleCatalog.sequenceLabel(b, found.first.asin))
                !AudibleCatalog.farFuture(b, today) && ns.size == 1 && ns[0] > current
            } ?: return@LaunchedEffect
            val n = AudibleCatalog.sequenceLabel(candidate, found.first.asin)
            number = n
            // The library's copy: the same book, or another edition with that number.
            mine = LibraryMatcher.match(candidate)
                ?: n?.toDoubleOrNull()?.let { num -> seriesName?.let { Services.books.booksInSeries(it) }?.firstOrNull { it.seriesSequence == num } }
            next = candidate
        } finally {
            looked = true
        }
    }
    val n = next
    when {
        // A placeholder only for a book the server knows is in a series (most aren't
        // in one: a placeholder would come and go on every page).
        !looked -> if (book.series != null) LoadingBlock(92.dp)
        n != null -> Surface(
            color = MaterialTheme.colorScheme.surfaceContainer,
            shape = RoundedCornerShape(20.dp),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    Modifier.fillMaxWidth().clickable { mine?.let { nav.openBook(it.id) } ?: nav.openAudible(n) },
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    AudibleCover(n.thumbUrl, 64.dp)
                    Column(Modifier.weight(1f).padding(start = 14.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Next in ${seriesName ?: "Series"}", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1, overflow = TextOverflow.Ellipsis)
                        Text(n.title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                        val status = if (mine != null) "In your library" else coming(n) ?: "Not in your library"
                        Text(listOfNotNull(number?.let { "Book $it" }, status).joinToString(" · "), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
                    }
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                // Not here: straight to Shelfarr from the card.
                if (mine == null) com.bennybar.kitzi.ui.services.SendToShelfarr(n.title, n.authors.firstOrNull(), compact = true)
            }
        }
    }
}

/**
 * A series' books as a ladder: every book in order, yours and the ones Audible has
 * that aren't here (or are coming), each of those opening its Audible page, with
 * Send to Shelfarr on the ones already out. Your books alone until Audible answers.
 */
@Composable
fun SeriesLadder(
    series: String,
    books: List<Book>,
    progress: Map<String, com.bennybar.kitzi.data.db.MediaProgressEntity>,
    onOpenBook: (String) -> Unit,
) {
    val nav = LocalKitziNav.current
    var missing by remember(series) { mutableStateOf<List<SeriesRung.Missing>?>(null) }
    var done by remember(series) { mutableStateOf(false) }
    val today = remember { LocalDate.now() }
    LaunchedEffect(series, books.size) {
        if (books.isEmpty() || missing != null) return@LaunchedEffect
        try {
            val found = runCatching { AudibleCatalog.seriesFor(series, books) }.getOrNull() ?: return@LaunchedEffect
            val all = runCatching { AudibleCatalog.seriesBooks(found.first, found.second) }.getOrNull() ?: return@LaunchedEffect
            missing = AudibleCatalog.missingFromSeries(
                all, found.first.asin, LibraryMatcher.matchAll(all).keys, books.mapNotNull { it.seriesSequence }.toSet(), today,
            )
        } finally {
            done = true
        }
    }
    val m = missing
    if (m != null) {
        val out = m.count { it.book.releaseDay?.isAfter(today) != true }
        val coming = m.size - out
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                if (m.isEmpty()) Icons.Default.Verified else Icons.AutoMirrored.Filled.LibraryBooks, null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp),
            )
            Text(
                if (m.isEmpty()) "You have every book in this series"
                else listOfNotNull("You have ${books.size} of ${books.size + out}", "$coming coming".takeIf { coming > 0 }).joinToString(" · "),
                style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 6.dp),
            )
        }
    } else if (!done) {
        LoadingRow()
    }
    AudibleCatalog.ladder(books, m.orEmpty()).forEach { rung ->
        when (rung) {
            is SeriesRung.Mine -> com.bennybar.kitzi.ui.library.BookCard(rung.book, progress = progress[rung.book.id]) { onOpenBook(rung.book.id) }
            is SeriesRung.Missing -> Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                val b = rung.book
                // "Book 4 · Not in your library", or "Books 1-3 · Coming 12 Mar 2027".
                val seq = b.seriesRefs.firstNotNullOfOrNull { it.sequence }?.let { if (it.contains("-")) "Books $it" else "Book $it" }
                AudibleRow(b, false, note = listOfNotNull(seq, coming(b) ?: "Not in your library").joinToString(" · ")) { nav.openAudible(b) }
                // Out already: straight to Shelfarr from here.
                if (b.releaseDay?.isAfter(today) != true) {
                    Box(Modifier.padding(horizontal = 16.dp)) {
                        com.bennybar.kitzi.ui.services.SendToShelfarr(b.title, b.authors.firstOrNull(), compact = true)
                    }
                }
            }
        }
    }
}

// MARK: because you finished

/** On the home screen: Audible's books like the one finished last, not in the library. */
@Composable
fun BecauseYouFinishedRow(progress: Map<String, com.bennybar.kitzi.data.db.MediaProgressEntity>) {
    val nav = LocalKitziNav.current
    val lastId = remember(progress) { progress.values.filter { it.isFinished }.maxByOrNull { it.lastUpdate }?.itemId }
    var finished by remember { mutableStateOf<Book?>(null) }
    var similar by remember { mutableStateOf<List<AudibleBook>>(emptyList()) }
    LaunchedEffect(lastId) {
        val b = lastId?.let { Services.books.getBook(it) }
        if (b == null) { finished = null; similar = emptyList(); return@LaunchedEffect }
        val asin = AudibleRatingService.asin(b) ?: return@LaunchedEffect
        val found = runCatching { AudibleCatalog.similar(asin, AudibleRatingService.language(b)) }.getOrNull() ?: return@LaunchedEffect
        val owned = LibraryMatcher.matchAll(found)
        similar = found.filter { it.asin !in owned }
        finished = b
    }
    val f = finished ?: return
    if (similar.isEmpty()) return
    Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 8.dp)) {
        Text(
            "Because You Finished ${f.title}",
            style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold,
            maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(horizontal = 16.dp),
        )
        AudibleCarousel(similar, emptySet()) { nav.openAudible(it) }
    }
}

// MARK: rating sort

/** "Getting Audible ratings… 120 of 800" while the "Highest rated" sort fills in. */
@Composable
fun RatingFillBanner() {
    val fill by AudibleRatingService.fill.collectAsState()
    val (done, total) = fill
    if (total <= 0) return
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 6.dp),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        com.bennybar.kitzi.ui.common.KitziLoading(Modifier.size(22.dp))
        Text("Getting Audible ratings… $done of $total", style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(start = 8.dp))
    }
}

// MARK: chapters from Audible

/**
 * Audible's chapters for a library book (through the server, from Audnexus),
 * compared with the book's, and saved to the server on Apply. When the server has
 * no ASIN for the book (Kitzi matched it by title), Apply saves that too.
 */
@Composable
fun AudibleChaptersDialog(book: Book, onDismiss: () -> Unit, onApplied: () -> Unit) {
    var loading by remember { mutableStateOf(true) }
    var found by remember { mutableStateOf<Pair<List<Chapter>, Double?>?>(null) }
    var current by remember { mutableStateOf(0) }
    var asin by remember { mutableStateOf<String?>(null) }
    var savesAsin by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var saving by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(book.id) {
        try {
            val a = AudibleRatingService.asin(book)
            if (a == null) { error = "Audible doesn't have this book."; return@LaunchedEffect }
            asin = a
            savesAsin = Services.books.serverAsin(book.id).isNullOrEmpty()
            current = Services.books.chapters(book.id).size
            found = Services.books.audibleChapters(a)
        } finally {
            loading = false
        }
    }
    val f = found
    val durationSec = book.durationMs?.let { it / 1000.0 }
    AlertDialog(
        onDismissRequest = { if (!saving) onDismiss() },
        title = { Text("Chapters from Audible") },
        text = {
            when {
                loading -> Row(verticalAlignment = Alignment.CenterVertically) {
                    com.bennybar.kitzi.ui.common.KitziLoading(Modifier.size(32.dp))
                    Text("Asking Audible…", modifier = Modifier.padding(start = 10.dp))
                }
                f == null -> Text(error ?: "Audible has no chapters for this book, or it couldn't be matched.")
                else -> Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    mismatch(f.second, durationSec)?.let { warning ->
                        Row {
                            Icon(Icons.Default.Warning, null, tint = androidx.compose.ui.graphics.Color(0xFFF59E0B), modifier = Modifier.size(18.dp))
                            Text(warning, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.padding(start = 6.dp))
                        }
                    }
                    Text("${f.first.size} chapters on Audible · $current now", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (savesAsin && asin != null) {
                        Text("Also saves Audible's ID ($asin) for this book to your server, so it's matched directly from now on.",
                            style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                    error?.let { Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        itemsIndexed(f.first) { i, c ->
                            Row(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                                Text(c.title.ifEmpty { "Chapter ${i + 1}" }, style = MaterialTheme.typography.bodyMedium, maxLines = 2, modifier = Modifier.weight(1f))
                                Text(clock(c.startSec), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 8.dp))
                            }
                        }
                    }
                }
            }
        },
        confirmButton = {
            if (f != null) {
                TextButton(enabled = !saving, onClick = {
                    scope.launch {
                        saving = true
                        val d = durationSec ?: f.first.last().startSec
                        // Chapters past the end of this edition are dropped.
                        val fitting = f.first.filter { it.startSec < d }
                        val why = Services.books.saveChapters(book.id, fitting, d)
                        if (why != null) { error = why; saving = false; return@launch }
                        // The chapters fit, so the match is right: the server keeps the
                        // ASIN too (only if it still has none).
                        val savedAsin = savesAsin && asin != null && Services.books.saveAsinIfMissing(book.id, asin!!)
                        Snackbars.show(if (savedAsin) "Chapters and Audible ID saved" else "Chapters updated from Audible")
                        saving = false
                        onApplied()
                        onDismiss()
                    }
                }) { Text("Apply") }
            }
        },
        dismissButton = { TextButton(enabled = !saving, onClick = onDismiss) { Text("Cancel") } },
    )
}

/** Audible's edition being a different length means its chapter times may not fit. */
private fun mismatch(runtime: Double?, duration: Double?): String? {
    if (runtime == null || duration == null || duration <= 0) return null
    val diff = runtime - duration
    if (abs(diff) <= maxOf(30.0, duration * 0.01)) return null
    val mins = (abs(diff) / 60).roundToInt()
    return "Audible's edition is $mins min ${if (diff > 0) "longer" else "shorter"} than yours, so its chapters may not line up."
}

private fun clock(sec: Double): String {
    val s = sec.toLong()
    return if (s >= 3600) "%d:%02d:%02d".format(s / 3600, s % 3600 / 60, s % 60) else "%d:%02d".format(s / 60, s % 60)
}
