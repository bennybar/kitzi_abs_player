package com.bennybar.kitzi.ui.stats

import android.content.Intent
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
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
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Share
import androidx.compose.material.icons.filled.Speed
import androidx.compose.material.icons.filled.WbSunny
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.asAndroidBitmap
import androidx.compose.ui.graphics.layer.drawLayer
import androidx.compose.ui.graphics.rememberGraphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.data.model.arr
import com.bennybar.kitzi.data.model.num
import com.bennybar.kitzi.data.model.obj
import com.bennybar.kitzi.data.model.str
import com.bennybar.kitzi.ui.audible.LocalKitziNav
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.formatHm
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.DayOfWeek
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.TextStyle
import java.time.temporal.ChronoUnit

/**
 * A year of listening, from the server's listening sessions (every device, not
 * only this one): hours, days, streak, the books, authors and narrators, the
 * busiest month and weekday, and a card to share.
 */
private class YearReview(
    val year: Int,
    val totalSec: Double,
    val days: Int,
    val longestStreak: Int,
    val books: List<Entry>,
    val authors: List<Entry>,
    val narrators: List<Entry>,
    val finished: List<Book>,
    /** The finished book read quickest: the book, and the days from its first session to finishing. */
    val fastest: Pair<Book, Int>?,
    val perMonthSec: DoubleArray,
    val busiestWeekday: DayOfWeek?,
    val busiestDay: Pair<LocalDate, Double>?,
) {
    class Entry(val name: String, val sec: Double, val book: Book?)
}

/** Built from the sessions (newest first, paged) and the library; null when the server can't be asked. */
private suspend fun loadYearReview(year: Int): YearReview? {
    val zone = ZoneId.systemDefault()
    val from = LocalDate.of(year, 1, 1)
    val to = from.plusYears(1)
    val perBook = LinkedHashMap<String, Double>()
    val authorsOf = HashMap<String, String>()
    val titles = HashMap<String, String>()
    val perDay = HashMap<LocalDate, Double>()
    val firstSession = HashMap<String, LocalDate>()
    val perMonth = DoubleArray(12)
    var page = 0
    pages@ while (page < 200) {
        val root = Services.books.listeningSessions(page) ?: if (page == 0) return null else break
        val sessions = root["sessions"].arr().orEmpty().mapNotNull { it.obj() }
        if (sessions.isEmpty()) break
        for (s in sessions) {
            val day = s["date"].str()?.let { runCatching { LocalDate.parse(it) }.getOrNull() }
                ?: s["startedAt"].num()?.let { Instant.ofEpochMilli(it.toLong()).atZone(zone).toLocalDate() }
                ?: continue
            // Newest first: past the year's start, done.
            if (day < from) break@pages
            if (day >= to) continue
            val id = s["libraryItemId"].str() ?: continue
            val sec = s["timeListening"].num() ?: 0.0
            if (sec <= 0) continue
            perBook.merge(id, sec, Double::plus)
            perDay.merge(day, sec, Double::plus)
            perMonth[day.monthValue - 1] += sec
            s["displayTitle"].str()?.let { titles.putIfAbsent(id, it) }
            s["displayAuthor"].str()?.let { authorsOf.putIfAbsent(id, it) }
            if (firstSession[id]?.isAfter(day) != false) firstSession[id] = day
        }
        page++
        if (page >= (root["numPages"].num()?.toInt() ?: 1)) break
    }

    // Finished this year, newest first (by when the book was last touched: the
    // server's progress carries no separate finish date here).
    val inYear = { ms: Long -> Instant.ofEpochMilli(ms).atZone(zone).toLocalDate().let { it >= from && it < to } }
    val finishedProgress = Services.books.allProgress().values
        .filter { it.isFinished && inYear(it.lastUpdate) }
        .sortedByDescending { it.lastUpdate }
    val library = Services.books.getBooks(perBook.keys + finishedProgress.map { it.itemId }).associateBy { it.id }

    var best = 0
    var run = 0
    var prev: LocalDate? = null
    for (d in perDay.keys.sorted()) {
        run = if (prev != null && d == prev.plusDays(1)) run + 1 else 1
        best = maxOf(best, run)
        prev = d
    }
    val byAuthor = HashMap<String, Double>()
    val byNarrator = HashMap<String, Double>()
    perBook.forEach { (id, sec) ->
        val b = library[id]
        (b?.authors?.firstOrNull() ?: b?.author ?: authorsOf[id])?.let { byAuthor.merge(it, sec, Double::plus) }
        b?.narrators?.forEach { byNarrator.merge(it, sec, Double::plus) }
    }
    val weekdays = perDay.entries.groupBy { it.key.dayOfWeek }.mapValues { e -> e.value.sumOf { it.value } }
    return YearReview(
        year = year,
        totalSec = perBook.values.sum(),
        days = perDay.values.count { it > 0 },
        longestStreak = best,
        books = perBook.map { (id, sec) -> YearReview.Entry(library[id]?.title ?: titles[id] ?: "Book", sec, library[id]) }.sortedByDescending { it.sec },
        authors = byAuthor.map { YearReview.Entry(it.key, it.value, null) }.sortedByDescending { it.sec },
        narrators = byNarrator.map { YearReview.Entry(it.key, it.value, null) }.sortedByDescending { it.sec },
        finished = finishedProgress.mapNotNull { library[it.itemId] },
        fastest = finishedProgress.mapNotNull { p ->
            val b = library[p.itemId] ?: return@mapNotNull null
            val first = firstSession[p.itemId] ?: return@mapNotNull null
            if ((b.durationMs ?: 0) <= 3_600_000) return@mapNotNull null
            val at = Instant.ofEpochMilli(p.lastUpdate).atZone(zone).toLocalDate()
            b to (ChronoUnit.DAYS.between(first, at).toInt() + 1).coerceAtLeast(1)
        }.minByOrNull { it.second },
        perMonthSec = perMonth,
        busiestWeekday = weekdays.maxByOrNull { it.value }?.takeIf { it.value > 0 }?.key,
        busiestDay = perDay.maxByOrNull { it.value }?.toPair(),
    )
}

@Composable
fun YearInReviewScreen(onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    val context = LocalContext.current
    val locale = LocalConfiguration.current.locales[0]
    val scope = rememberCoroutineScope()
    val now = remember { LocalDate.now().year }
    var year by rememberSaveable { mutableIntStateOf(now) }
    var review by remember { mutableStateOf<YearReview?>(null) }
    var failed by remember { mutableStateOf(false) }
    var showYears by remember { mutableStateOf(false) }
    // The month bars grow in once the year is shown.
    var grown by remember { mutableStateOf(false) }
    // The card, recorded as it's drawn, so it can be shared as an image.
    val cardLayer = rememberGraphicsLayer()

    LaunchedEffect(year) {
        // The previous year stays (dimmed) until the new one is in: no blank page.
        failed = false
        grown = false
        val r = loadYearReview(year)
        if (r == null) { review = null; failed = true } else { review = r; grown = true }
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = Icons.Default.AutoAwesome,
            title = "$year in Review",
            onBack = onBack,
            trailing = {
                Box {
                    IconButton(onClick = { showYears = true }) { Icon(Icons.Default.CalendarMonth, "Year") }
                    DropdownMenu(showYears, onDismissRequest = { showYears = false }) {
                        (now downTo now - 4).forEach { y ->
                            DropdownMenuItem(text = { Text("$y") }, onClick = { year = y; showYears = false })
                        }
                    }
                }
                val r = review
                if (r != null && r.year == year) {
                    IconButton(onClick = {
                        scope.launch {
                            val image = cardLayer.toImageBitmap().asAndroidBitmap()
                            val file = java.io.File(context.cacheDir, "share/year-${r.year}.png")
                            withContext(Dispatchers.IO) {
                                file.parentFile?.mkdirs()
                                file.outputStream().use { image.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it) }
                            }
                            val uri = androidx.core.content.FileProvider.getUriForFile(context, "${context.packageName}.files", file)
                            val send = Intent(Intent.ACTION_SEND)
                                .setType("image/png")
                                .putExtra(Intent.EXTRA_STREAM, uri)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            context.startActivity(Intent.createChooser(send, "My ${r.year} in audiobooks"))
                        }
                    }) { Icon(Icons.Default.Share, "Share") }
                }
            },
        )
        val r = review
        when {
            r != null -> Column(
                Modifier.verticalScroll(rememberScrollState()).padding(16.dp)
                    .padding(bottom = com.bennybar.kitzi.LocalMiniPlayerInset.current)
                    .alpha(if (r.year == year) 1f else 0.4f),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                YearCard(r, Modifier.drawWithContent {
                    cardLayer.record { this@drawWithContent.drawContent() }
                    drawLayer(cardLayer)
                })
                if (r.totalSec > 0) {
                    YearSection("By Month") { MonthBars(r.perMonthSec, grown, locale) }
                    YearSection(null) {
                        r.busiestDay?.let { (d, sec) ->
                            Moment(Icons.Default.WbSunny, "Biggest day", "${d.format(DateTimeFormatter.ofPattern("MMMM d", locale))} · ${formatHm(sec.toLong())}")
                        }
                        r.busiestWeekday?.let { Moment(Icons.Default.CalendarMonth, "Favourite day", it.getDisplayName(TextStyle.FULL, locale)) }
                        if (r.days > 0) Moment(Icons.Default.Schedule, "On a listening day", formatHm((r.totalSec / r.days).toLong()))
                        r.fastest?.let { (b, days) ->
                            Moment(Icons.Default.Speed, "Fastest finish", "${b.title} · ${com.bennybar.kitzi.ui.common.plural(days, "day")}")
                        }
                    }
                    TopEntries("Most Listened", r.books.take(5), covers = true)
                    TopEntries("Top Authors", r.authors.take(5), covers = false)
                    TopEntries("Top Narrators", r.narrators.take(5), covers = false)
                    if (r.finished.isNotEmpty()) {
                        YearSection("Finished in ${r.year}") {
                            LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                                items(r.finished, key = { it.id }) { b ->
                                    AsyncImage(
                                        model = b.coverUrl,
                                        contentDescription = b.title,
                                        contentScale = ContentScale.Crop,
                                        modifier = Modifier.size(84.dp).clip(RoundedCornerShape(12.dp)).clickable { nav.openBook(b.id) },
                                    )
                                }
                            }
                        }
                    }
                }
            }
            failed -> com.bennybar.kitzi.ui.browse.BrowseEmptyState(
                Icons.Default.CalendarMonth,
                "Couldn't load $year",
                "Your listening history comes from the server. Check your connection.",
            )
            else -> Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center, horizontalAlignment = Alignment.CenterHorizontally) {
                com.bennybar.kitzi.ui.common.KitziLoading()
                Text("Adding up $year…", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(top = 8.dp))
            }
        }
    }
}

/** The year on one card (shown at the top, and shared as an image). */
@Composable
private fun YearCard(r: YearReview, modifier: Modifier) {
    val accent = MaterialTheme.colorScheme.primary
    Column(
        modifier.fillMaxWidth()
            .clip(RoundedCornerShape(26.dp))
            .background(Brush.linearGradient(listOf(accent, accent.copy(alpha = 0.65f), Color(0xFF8E44AD).copy(alpha = 0.8f))))
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text("My ${r.year} in audiobooks", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = Color.White.copy(alpha = 0.85f))
        if (r.totalSec <= 0) {
            Text("Nothing listened yet", style = MaterialTheme.typography.headlineMedium, fontWeight = FontWeight.Bold, color = Color.White)
            return@Column
        }
        Text("${Math.round(r.totalSec / 3600)} hours", fontSize = 44.sp, fontWeight = FontWeight.Black, color = Color.White)
        Row(horizontalArrangement = Arrangement.spacedBy(18.dp)) {
            listOf("${r.finished.size}" to "finished", "${r.days}" to "days", "${r.longestStreak}" to "day streak").forEach { (value, label) ->
                Column {
                    Text(value, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = Color.White)
                    Text(label, style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.8f))
                }
            }
        }
        r.books.firstOrNull()?.let { top ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                top.book?.let { b ->
                    AsyncImage(
                        // A software bitmap: the card is drawn again into the shared image.
                        model = coil.request.ImageRequest.Builder(LocalContext.current).data(b.coverUrl).allowHardware(false).build(),
                        contentDescription = null,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier.padding(end = 12.dp).size(54.dp).clip(RoundedCornerShape(10.dp)),
                    )
                }
                Column {
                    Text("Most listened", style = MaterialTheme.typography.labelMedium, color = Color.White.copy(alpha = 0.75f))
                    Text(top.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
                }
            }
        }
        r.authors.firstOrNull()?.let {
            Text("Top author: ${it.name}", style = MaterialTheme.typography.bodyMedium, color = Color.White.copy(alpha = 0.9f))
        }
    }
}

@Composable
private fun YearSection(title: String?, content: @Composable () -> Unit) {
    androidx.compose.material3.Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(20.dp),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            title?.let { Text(it, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold) }
            content()
        }
    }
}

/** Hours per month as bars, on a fixed scale so they grow instead of the scale jumping. */
@Composable
private fun MonthBars(perMonthSec: DoubleArray, grown: Boolean, locale: java.util.Locale) {
    val grow by animateFloatAsState(if (grown) 1f else 0f, spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessLow), label = "months")
    val max = perMonthSec.max().coerceAtLeast(3600.0)
    Row(Modifier.fillMaxWidth().height(150.dp), horizontalArrangement = Arrangement.spacedBy(4.dp), verticalAlignment = Alignment.Bottom) {
        perMonthSec.forEachIndexed { i, sec ->
            Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Bottom) {
                Box(
                    Modifier.fillMaxWidth()
                        .height(120.dp * (sec / max).toFloat() * grow)
                        .clip(RoundedCornerShape(4.dp))
                        .background(MaterialTheme.colorScheme.primary),
                )
                Text(
                    java.time.Month.of(i + 1).getDisplayName(TextStyle.SHORT, locale),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    softWrap = false,
                    textAlign = TextAlign.Center,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun Moment(icon: ImageVector, label: String, value: String) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(start = 10.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, textAlign = TextAlign.End, maxLines = 2, overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f).padding(start = 12.dp))
    }
}

@Composable
private fun TopEntries(title: String, entries: List<YearReview.Entry>, covers: Boolean) {
    if (entries.isEmpty()) return
    YearSection(title) {
        entries.forEachIndexed { i, e ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                val b = e.book
                if (covers && b != null) {
                    AsyncImage(
                        model = b.coverUrl, contentDescription = null, contentScale = ContentScale.Crop,
                        modifier = Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)),
                    )
                } else {
                    Text("${i + 1}", style = MaterialTheme.typography.titleMedium, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        textAlign = TextAlign.Center, modifier = Modifier.width(40.dp))
                }
                Text(e.name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f).padding(horizontal = 12.dp))
                Text(formatHm(e.sec.toLong()), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
