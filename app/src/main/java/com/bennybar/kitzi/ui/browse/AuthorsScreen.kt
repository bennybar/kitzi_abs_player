package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.Author
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.formatHm
import kotlinx.coroutines.launch

@Composable
fun AuthorsScreen(onOpenBook: (String) -> Unit) {
    var authors by remember { mutableStateOf<List<Author>>(emptyList()) }
    var search by remember { mutableStateOf("") }
    var loading by remember { mutableStateOf(true) }
    var sheetAuthor by remember { mutableStateOf<Author?>(null) }
    val scope = rememberCoroutineScope()

    suspend fun load() { authors = Services.books.authorsWithImages() }

    LaunchedEffect(Unit) { load(); loading = false }

    val visible = authors.filter { it.name.contains(search, ignoreCase = true) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = Icons.Default.Person,
            title = "Authors",
            trailing = {
                IconButton(onClick = { scope.launch { load() } }) {
                    Icon(Icons.Default.Refresh, "Refresh")
                }
            },
        )
        KitziSearchField(search, { search = it }, "Search authors…", Modifier.padding(bottom = 8.dp))

        when {
            loading -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
            visible.isEmpty() -> BrowseEmptyState(
                icon = Icons.Default.Person,
                title = if (search.isNotBlank()) "No matches" else "No authors found",
                message = if (search.isNotBlank()) "Try adjusting your search terms"
                else "Authors appear once your library has synced",
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp, top = 16.dp, end = 16.dp,
                    bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(visible, key = { it.name }) { author ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { sheetAuthor = author },
                    ) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            AuthorAvatar(author, 60.dp)
                            Column(Modifier.weight(1f).padding(start = 14.dp)) {
                                Text(
                                    author.name,
                                    style = MaterialTheme.typography.titleMedium,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    if (author.bookCount == 1) "1 book" else "${author.bookCount} books",
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
                }
            }
        }
    }

    sheetAuthor?.let { author ->
        AuthorSheet(
            author = author,
            onDismiss = { sheetAuthor = null },
            onOpenBook = { id -> sheetAuthor = null; onOpenBook(id) },
        )
    }
}

@Composable
private fun AuthorAvatar(author: Author, size: androidx.compose.ui.unit.Dp) {
    if (author.imageUrl != null) {
        AsyncImage(
            model = author.imageUrl,
            contentDescription = author.name,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(size).clip(CircleShape),
        )
    } else {
        // Authors the server has no portrait for get a tinted placeholder.
        Box(
            Modifier.size(size).clip(CircleShape).background(MaterialTheme.colorScheme.primaryContainer),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Person, null, tint = MaterialTheme.colorScheme.primary)
        }
    }
}

/** The author detail sheet: portrait, name, book count, optional bio, and the author's audiobooks. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun AuthorSheet(author: Author, onDismiss: () -> Unit, onOpenBook: (String) -> Unit) {
    val scope = rememberCoroutineScope()
    var books by remember(author.name) { mutableStateOf<List<Book>>(emptyList()) }
    LaunchedEffect(author.name) { books = Services.books.booksByAuthor(author.name) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
    ) {
        LazyColumn(
            Modifier.fillMaxWidth().padding(horizontal = 20.dp),
            contentPadding = PaddingValues(bottom = 28.dp),
        ) {
            item {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    AuthorAvatar(author, 64.dp)
                    Column(Modifier.weight(1f).padding(start = 16.dp)) {
                        Text(
                            author.name,
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            maxLines = 2,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            if (author.bookCount == 1) "1 book" else "${author.bookCount} books",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
                author.description?.takeIf { it.isNotBlank() }?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 5,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 12.dp),
                    )
                }
                androidx.compose.foundation.layout.Spacer(Modifier.size(12.dp))
            }
            items(books, key = { it.id }) { book ->
                AuthorBookTile(
                    book = book,
                    onOpen = { onOpenBook(book.id) },
                    onPlay = { scope.launch { Services.playback.playItem(book.id) } },
                )
            }
        }
    }
}

@Composable
private fun AuthorBookTile(book: Book, onOpen: () -> Unit, onPlay: () -> Unit) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AsyncImage(
            model = book.coverUrl,
            contentDescription = book.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.size(width = 56.dp, height = 84.dp).clip(RoundedCornerShape(10.dp)),
        )
        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
            Text(
                book.title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                maxLines = 2,
                overflow = TextOverflow.Ellipsis,
            )
            book.series?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.primary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(top = 2.dp),
                )
            }
            book.durationMs?.let { ms ->
                Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    Icon(
                        Icons.Default.Schedule,
                        null,
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.size(15.dp),
                    )
                    Text(
                        formatHm(ms / 1000),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(start = 6.dp),
                    )
                }
            }
        }
        IconButton(onClick = onPlay) {
            Icon(
                Icons.Default.PlayCircle,
                "Play",
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(40.dp),
            )
        }
    }
}
