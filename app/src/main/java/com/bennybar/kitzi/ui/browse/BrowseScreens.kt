package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SecondaryTabRow
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
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book

private enum class BrowseTab { SERIES, AUTHORS, COLLECTIONS }

@OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)
@Composable
fun BrowseScreen(onOpenBook: (String) -> Unit) {
    var tab by remember { mutableStateOf(BrowseTab.SERIES) }

    Column(Modifier.fillMaxSize()) {
        SecondaryTabRow(selectedTabIndex = tab.ordinal) {
            BrowseTab.entries.forEach { t ->
                Tab(
                    selected = tab == t,
                    onClick = { tab = t },
                    text = { Text(t.name.lowercase().replaceFirstChar { it.uppercase() }) },
                )
            }
        }
        when (tab) {
            BrowseTab.SERIES -> SeriesList(onOpenBook)
            BrowseTab.AUTHORS -> AuthorsList(onOpenBook)
            BrowseTab.COLLECTIONS -> CollectionsList(onOpenBook)
        }
    }
}

@Composable
private fun SeriesList(onOpenBook: (String) -> Unit) {
    var series by remember { mutableStateOf<List<Pair<String, Int>>>(emptyList()) }
    var expanded by remember { mutableStateOf<String?>(null) }
    var books by remember { mutableStateOf<List<Book>>(emptyList()) }

    // ui_series_min_books: 1 means show every series.
    val minBooks = Services.prefs.getInt("ui_series_min_books", 1)
    LaunchedEffect(Unit) { series = Services.books.series(minBooks) }
    LaunchedEffect(expanded) {
        books = expanded?.let { Services.books.booksInSeries(it) }.orEmpty()
    }

    GroupList(
        groups = series,
        expanded = expanded,
        books = books,
        onToggle = { expanded = if (expanded == it) null else it },
        onOpenBook = onOpenBook,
        emptyText = "No series",
    )
}

@Composable
private fun AuthorsList(onOpenBook: (String) -> Unit) {
    var authors by remember { mutableStateOf<List<Pair<String, Int>>>(emptyList()) }
    var expanded by remember { mutableStateOf<String?>(null) }
    var books by remember { mutableStateOf<List<Book>>(emptyList()) }

    LaunchedEffect(Unit) { authors = Services.books.authors() }
    LaunchedEffect(expanded) {
        books = expanded?.let { Services.books.booksByAuthor(it) }.orEmpty()
    }

    GroupList(
        groups = authors,
        expanded = expanded,
        books = books,
        onToggle = { expanded = if (expanded == it) null else it },
        onOpenBook = onOpenBook,
        emptyText = "No authors",
    )
}

@Composable
private fun CollectionsList(onOpenBook: (String) -> Unit) {
    var collections by remember { mutableStateOf<Map<String, List<Book>>>(emptyMap()) }
    var expanded by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(Unit) { collections = Services.books.collections() }

    GroupList(
        groups = collections.map { it.key to it.value.size },
        expanded = expanded,
        books = expanded?.let { collections[it] }.orEmpty(),
        onToggle = { expanded = if (expanded == it) null else it },
        onOpenBook = onOpenBook,
        emptyText = "No collections",
    )
}

/** A list of named groups; tapping one reveals its books in a row. */
@Composable
private fun GroupList(
    groups: List<Pair<String, Int>>,
    expanded: String?,
    books: List<Book>,
    onToggle: (String) -> Unit,
    onOpenBook: (String) -> Unit,
    emptyText: String,
) {
    if (groups.isEmpty()) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.Center) {
            Text(emptyText, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyLarge)
        }
        return
    }

    LazyColumn(Modifier.fillMaxSize()) {
        items(groups, key = { it.first }) { (name, count) ->
            Column {
                Row(
                    Modifier
                        .fillMaxWidth()
                        .clickable { onToggle(name) }
                        .padding(horizontal = 16.dp, vertical = 14.dp),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(name, style = MaterialTheme.typography.bodyLarge, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    Text("$count", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }

                if (expanded == name) {
                    LazyRow(
                        Modifier.fillMaxWidth().padding(start = 16.dp, bottom = 12.dp),
                        horizontalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        items(books, key = { it.id }) { book ->
                            Column(
                                Modifier.size(110.dp).clickable { onOpenBook(book.id) },
                            ) {
                                AsyncImage(
                                    model = book.coverUrl,
                                    contentDescription = book.title,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.size(100.dp).clip(RoundedCornerShape(8.dp)),
                                )
                                Text(
                                    book.title,
                                    style = MaterialTheme.typography.bodySmall,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
                HorizontalDivider()
            }
        }
    }
}
