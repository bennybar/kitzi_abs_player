package com.bennybar.kitzi.ui.browse

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
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
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import com.bennybar.kitzi.ui.library.BookCard
import kotlinx.coroutines.launch

@Composable
fun AuthorsScreen(onOpenBook: (String) -> Unit) {
    var authors by remember { mutableStateOf<List<Author>>(emptyList()) }
    var search by remember { mutableStateOf("") }
    var expanded by remember { mutableStateOf<String?>(null) }
    var books by remember { mutableStateOf<List<Book>>(emptyList()) }
    val scope = rememberCoroutineScope()

    suspend fun load() { authors = Services.books.authorsWithImages() }

    LaunchedEffect(Unit) { load() }
    LaunchedEffect(expanded) {
        books = expanded?.let { Services.books.booksByAuthor(it) }.orEmpty()
    }

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

        LazyColumn(
            contentPadding = androidx.compose.foundation.layout.PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(visible, key = { it.name }) { author ->
                Column {
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { expanded = if (expanded == author.name) null else author.name },
                    ) {
                        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            if (author.imageUrl != null) {
                                AsyncImage(
                                    model = author.imageUrl,
                                    contentDescription = author.name,
                                    contentScale = ContentScale.Crop,
                                    modifier = Modifier.size(60.dp).clip(CircleShape),
                                )
                            } else {
                                // Authors the server has no portrait for get the same
                                // tinted placeholder the Flutter app shows.
                                Box(
                                    Modifier
                                        .size(60.dp)
                                        .clip(CircleShape)
                                        .background(MaterialTheme.colorScheme.primaryContainer),
                                    contentAlignment = Alignment.Center,
                                ) {
                                    Icon(
                                        Icons.Default.Person,
                                        null,
                                        tint = MaterialTheme.colorScheme.primary,
                                    )
                                }
                            }
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

                    if (expanded == author.name) {
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
