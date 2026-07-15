package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Collections
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.library.BookCard

private enum class SeriesTab { SERIES, COLLECTIONS }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SeriesScreen(onOpenBook: (String) -> Unit, onBack: () -> Unit) {
    var tab by remember { mutableStateOf(SeriesTab.SERIES) }
    var series by remember { mutableStateOf<List<Pair<String, Int>>>(emptyList()) }
    var collections by remember { mutableStateOf<Map<String, List<Book>>>(emptyMap()) }
    var search by remember { mutableStateOf("") }
    var expanded by remember { mutableStateOf<String?>(null) }
    var books by remember { mutableStateOf<List<Book>>(emptyList()) }

    val minBooks = Services.prefs.getInt("ui_series_min_books", 1)
    LaunchedEffect(Unit) {
        series = Services.books.series(minBooks)
        collections = Services.books.collections()
    }
    LaunchedEffect(expanded, tab) {
        books = when (tab) {
            SeriesTab.SERIES -> expanded?.let { Services.books.booksInSeries(it) }.orEmpty()
            SeriesTab.COLLECTIONS -> expanded?.let { collections[it] }.orEmpty()
        }
    }

    val groups = when (tab) {
        SeriesTab.SERIES -> series
        SeriesTab.COLLECTIONS -> collections.map { it.key to it.value.size }
    }.filter { it.first.contains(search, ignoreCase = true) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = if (tab == SeriesTab.SERIES) Icons.Default.LibraryBooks else Icons.Default.Collections,
            title = if (tab == SeriesTab.SERIES) "Series" else "Collections",
            subtitle = "${groups.size} in library",
            trailing = {
                IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") }
            },
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

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(groups, key = { it.first }) { (name, count) ->
                Column {
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { expanded = if (expanded == name) null else name },
                    ) {
                        Row(
                            Modifier.padding(16.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(Modifier.weight(1f)) {
                                Text(
                                    name,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    if (count == 1) "1 book" else "$count books",
                                    style = MaterialTheme.typography.bodyMedium,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                )
                            }
                            Icon(
                                Icons.AutoMirrored.Filled.KeyboardArrowRight,
                                null,
                                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }

                    if (expanded == name) {
                        Column(
                            Modifier.padding(top = 10.dp, start = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(10.dp),
                        ) {
                            books.forEach { book -> BookCard(book) { onOpenBook(book.id) } }
                        }
                    }
                }
            }
        }
    }
}
