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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
    var loaded by remember { mutableStateOf(false) }

    LaunchedEffect(Unit) {
        stats = Services.books.listeningStats()
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
        Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        ScreenHeader(
            icon = Icons.Default.BarChart,
            title = "Listening",
            trailing = {
                IconButton(onClick = onBack) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
            },
        )

        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            StatTile("Total", humanDuration(s.totalSec), Modifier.weight(1f))
            StatTile("Finished", "${s.itemsFinished}", Modifier.weight(1f))
        }

        if (s.perDaySec.isNotEmpty()) {
            Text("Last 14 days", style = MaterialTheme.typography.titleMedium)
            DailyBars(s.perDaySec)
        }

        YearWrapped(s)
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
    val days = perDay.entries.sortedBy { it.key }.takeLast(14)
    val max = days.maxOfOrNull { it.value }?.takeIf { it > 0 } ?: 1.0

    // The bar height is given in dp rather than as a fraction of the column: at
    // 100% a fractional height consumes the whole column and shoves the date label
    // out of the chart.
    val maxBarHeight = 100.dp

    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.Bottom,
    ) {
        days.forEach { (day, seconds) ->
            Column(
                Modifier.weight(1f),
                verticalArrangement = Arrangement.Bottom,
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Box(
                    Modifier
                        .fillMaxWidth()
                        // A day with any listening at all gets a visible sliver.
                        .height(maxBarHeight * (seconds / max).toFloat().coerceIn(0.02f, 1f))
                        .clip(RoundedCornerShape(4.dp))
                        .background(MaterialTheme.colorScheme.primary),
                )
                Text(
                    day.takeLast(2),
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.padding(top = 4.dp),
                )
            }
        }
    }
}

@Composable
private fun YearWrapped(s: ListeningStats) {
    val hours = (s.totalSec / 3600).roundToInt()
    val busiest = s.perDaySec.maxByOrNull { it.value }

    Card(Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("Year Wrapped", style = MaterialTheme.typography.titleLarge)
            Text("You listened for about $hours hours.", style = MaterialTheme.typography.bodyLarge)
            Text("You finished ${s.itemsFinished} books.", style = MaterialTheme.typography.bodyLarge)
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
    return if (h > 0) "${h}h ${m}m" else "${m}m"
}
