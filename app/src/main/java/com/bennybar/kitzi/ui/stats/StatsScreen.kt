package com.bennybar.kitzi.ui.stats

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material3.Card
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.ListeningStats
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.ui.common.ScreenHeader
import kotlin.math.roundToInt

@Composable
fun StatsScreen(onBack: () -> Unit = {}) {
    var stats by remember { mutableStateOf<ListeningStats?>(null) }
    var detailed by remember { mutableStateOf<com.bennybar.kitzi.data.DetailedStats?>(null) }
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        stats = Services.books.listeningStats()
        detailed = Services.books.detailedStats()
        loaded = true
    }

    val s = stats
    if (s == null) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            Text(
                if (loaded) "Stats unavailable" else "Loading…",
                Modifier.fillMaxWidth(),
                style = MaterialTheme.typography.bodyLarge,
            )
        }
        return
    }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp)
            .padding(bottom = com.bennybar.kitzi.LocalMiniPlayerInset.current),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ScreenHeader(
            icon = Icons.Default.BarChart,
            title = "Listening",
            onBack = onBack,
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("Total", humanDuration(s.totalSec), Modifier.weight(1f))
            StatTile("Finished", "${s.itemsFinished}", Modifier.weight(1f))
            detailed?.let {
                StatTile("Streak", if (it.currentStreakDays == 1) "1 day" else "${it.currentStreakDays} days", Modifier.weight(1f))
            }
        }

        if (s.perDaySec.isNotEmpty()) {
            Text("Last 14 days", style = MaterialTheme.typography.titleMedium)
            DailyBars(s.perDaySec)
        }

        val d = detailed
        if (d != null && d.topBooks.isEmpty()) {
            Card(Modifier.fillMaxWidth()) {
                Text(
                    if (com.bennybar.kitzi.data.PlayHistoryStore.enabled())
                        "No detailed history yet — keep listening and your top books, authors and narrators will show up here."
                    else
                        "Enable \"Detailed listening history\" in Settings to see your top books, authors and narrators.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(16.dp),
                )
            }
        }
        d?.takeIf { it.topBooks.isNotEmpty() }?.let { TopList("Top books", it.topBooks, showCovers = true) }
        d?.takeIf { it.topAuthors.isNotEmpty() }?.let { TopList("Top authors", it.topAuthors, showCovers = false) }
        d?.takeIf { it.topNarrators.isNotEmpty() }?.let { TopList("Top narrators", it.topNarrators, showCovers = false) }

        YearWrapped(s, detailed)
    }
}

@Composable
private fun TopList(title: String, entries: List<com.bennybar.kitzi.data.TopEntry>, showCovers: Boolean) {
    Text(title, style = MaterialTheme.typography.titleMedium)
    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(vertical = 6.dp)) {
            entries.forEachIndexed { i, e ->
                Row(
                    Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        "${i + 1}",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.width(24.dp),
                    )
                    if (showCovers && e.coverUrl != null) {
                        coil.compose.AsyncImage(
                            model = e.coverUrl,
                            contentDescription = null,
                            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
                            modifier = Modifier.size(40.dp).clip(RoundedCornerShape(8.dp)),
                        )
                    }
                    Text(
                        e.label,
                        style = MaterialTheme.typography.bodyLarge,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        modifier = Modifier.weight(1f).padding(horizontal = 12.dp),
                    )
                    Text(
                        humanDuration(e.listenedSec),
                        style = MaterialTheme.typography.labelLarge,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}

@Composable
private fun StatTile(label: String, value: String, modifier: Modifier = Modifier) {
    Card(modifier) {
        Column(Modifier.padding(16.dp)) {
            Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(value, style = MaterialTheme.typography.headlineSmall)
        }
    }
}

/** A plain bar chart — no chart library, and none is warranted for 14 bars. */
@Composable
private fun DailyBars(perDay: Map<String, Double>) {
    // Always the last 14 calendar days ending today, each mapped to its seconds
    // (zero if absent). Laying the row out only from days that have data made a
    // single day of listening fill the whole width at full height — a solid block,
    // not a chart. A fixed window shows sparse data as short bars among empty days.
    val fmt = java.time.format.DateTimeFormatter.ISO_LOCAL_DATE
    val today = java.time.LocalDate.now()
    val days = (13 downTo 0).map { offset ->
        val date = today.minusDays(offset.toLong())
        date to (perDay[date.format(fmt)] ?: 0.0)
    }
    val max = days.maxOfOrNull { it.second }?.takeIf { it > 0 } ?: 1.0

    // The bar height is given in dp rather than as a fraction of the column: at
    // 100% a fractional height consumes the whole column and shoves the date label
    // out of the chart.
    val maxBarHeight = 100.dp

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        days.forEach { (date, seconds) ->
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.Bottom,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        // A day with any listening gets a visible sliver; a day with
                        // none gets no bar at all, just its date label.
                        .height(if (seconds <= 0) 0.dp else maxBarHeight * (seconds / max).toFloat().coerceIn(0.04f, 1f))
                        .clip(RoundedCornerShape(4.dp))
                        .background(MaterialTheme.colorScheme.primary),
                )
                Text(
                    date.dayOfMonth.toString(),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun YearWrapped(s: ListeningStats, detailed: com.bennybar.kitzi.data.DetailedStats?) {
    val hours = (s.totalSec / 3600).roundToInt()
    val busiest = s.perDaySec.maxByOrNull { it.value }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Year Wrapped", style = MaterialTheme.typography.titleLarge)
            Text("You listened for about $hours hours.", style = MaterialTheme.typography.bodyLarge)
            Text("You finished ${s.itemsFinished} ${if (s.itemsFinished == 1) "book" else "books"}.", style = MaterialTheme.typography.bodyLarge)
            detailed?.takeIf { it.daysListened > 0 }?.let {
                Text("You listened on ${it.daysListened} different ${if (it.daysListened == 1) "day" else "days"}.", style = MaterialTheme.typography.bodyLarge)
                if (it.currentStreakDays > 1) {
                    Text("You're on a ${it.currentStreakDays}-day streak.", style = MaterialTheme.typography.bodyLarge)
                }
            }
            detailed?.topBooks?.firstOrNull()?.let {
                Text("Your top book was “${it.label}”.", style = MaterialTheme.typography.bodyLarge)
            }
            busiest?.let {
                Text(
                    "Your biggest day was ${it.key} — ${humanDuration(it.value)}.",
                    style = MaterialTheme.typography.bodyLarge,
                )
            }
        }
    }
}

private fun humanDuration(seconds: Double): String {
    val total = seconds.roundToInt()
    val h = total / 3600
    val m = (total % 3600) / 60
    return when {
        h > 0 -> "${h}h ${m}m"
        m > 0 -> "${m}m"
        total > 0 -> "<1m"
        else -> "0m"
    }
}
