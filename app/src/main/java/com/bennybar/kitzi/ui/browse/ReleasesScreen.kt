package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.NewReleases
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bennybar.kitzi.data.Radar
import com.bennybar.kitzi.data.RadarFind
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.ui.audible.AudibleCover
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.SectionHeader
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * The radar's finds: books just out or coming from your authors, series and
 * followed narrators that aren't in the library. Each opens its Audible page
 * (Send to Shelfarr is there).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReleasesScreen(onBack: () -> Unit, onOpen: (String) -> Unit) {
    val finds by Radar.finds.collectAsStateWithLifecycle()
    val checking by Radar.checking.collectAsStateWithLifecycle()
    LaunchedEffect(Unit) {
        if (Services.prefs.getBoolean(Radar.KEY_ON, false) && finds.isEmpty()) Radar.checkSoon(force = true)
    }
    val today = LocalDate.now()
    // Newest release first; the coming ones soonest first.
    val out = finds.filter { !it.isUpcoming(today) }.sortedByDescending { it.releaseDay }
    val coming = finds.filter { it.isUpcoming(today) }.sortedBy { it.releaseDay }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.NewReleases, title = "New Releases", onBack = onBack)
        PullToRefreshBox(
            isRefreshing = checking,
            onRefresh = { Radar.checkSoon(force = true) },
            modifier = Modifier.fillMaxSize(),
        ) {
            if (finds.isEmpty()) {
                BrowseEmptyState(
                    Icons.Default.NewReleases,
                    if (checking) "Checking Audible…" else "Nothing new right now",
                    "New and upcoming books from your authors, the next books of the series you're listening to, and narrators you follow.",
                )
            } else LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp, top = 8.dp, end = 16.dp,
                    bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                for ((title, list) in listOf("Just Out" to out, "Coming Soon" to coming)) {
                    if (list.isEmpty()) continue
                    item(key = title) { SectionHeader(Icons.Default.NewReleases, title) }
                    items(list, key = { it.asin }) { f -> FindRow(f, today) { onOpen(f.asin) } }
                }
            }
        }
    }
}

@Composable
private fun FindRow(f: RadarFind, today: LocalDate, onClick: () -> Unit) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(18.dp),
        modifier = Modifier.fillMaxWidth(),
        onClick = onClick,
    ) {
        Row(Modifier.padding(10.dp), verticalAlignment = Alignment.CenterVertically) {
            AudibleCover(f.cover, 56.dp)
            Column(Modifier.weight(1f).padding(start = 12.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(f.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                Text(f.reason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary, maxLines = 1, overflow = TextOverflow.Ellipsis)
                f.releaseDay?.let { d ->
                    val date = d.format(DateTimeFormatter.ofLocalizedDate(FormatStyle.MEDIUM))
                    Text(
                        if (f.isUpcoming(today)) "Out $date" else "Released $date",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }
    }
}
