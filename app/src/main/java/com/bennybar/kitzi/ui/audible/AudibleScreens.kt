package com.bennybar.kitzi.ui.audible

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.automirrored.filled.Sort
import androidx.compose.material.icons.filled.Business
import androidx.compose.material.icons.filled.CalendarMonth
import androidx.compose.material.icons.filled.Headphones
import androidx.compose.material.icons.filled.Language
import androidx.compose.material.icons.filled.LocalOffer
import androidx.compose.material.icons.filled.Numbers
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.WifiOff
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.Checkbox
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.LocalMiniPlayerInset
import com.bennybar.kitzi.data.audible.AudibleBook
import com.bennybar.kitzi.data.audible.AudibleCatalog
import com.bennybar.kitzi.data.audible.AudibleGenre
import com.bennybar.kitzi.data.audible.LibraryMatcher
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.UiPrefsState
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.formatHm
import kotlinx.coroutines.delay

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AudibleTopBar(title: String, onBack: () -> Unit, actions: @Composable () -> Unit = {}) {
    TopAppBar(
        title = { Text(title, fontWeight = FontWeight.SemiBold, maxLines = 1, overflow = TextOverflow.Ellipsis) },
        windowInsets = androidx.compose.foundation.layout.WindowInsets(0),
        navigationIcon = { IconButton(onClick = onBack) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back") } },
        actions = { actions() },
    )
}

/** Which of [books] are in the library (by ASIN), recomputed when the list changes. */
@Composable
fun rememberInLibrary(books: List<AudibleBook>?): Map<String, Book> {
    var matches by remember { mutableStateOf<Map<String, Book>>(emptyMap()) }
    LaunchedEffect(books) { matches = books?.let { LibraryMatcher.matchAll(it) }.orEmpty() }
    return matches
}

@Composable
private fun Unreachable() {
    Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Icon(Icons.Default.WifiOff, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(40.dp))
        Text("Couldn't reach Audible", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 10.dp))
        Text("Check your connection and try again.", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

// MARK: Find Book

/** Find Book: searches Audible's catalog; before anything is typed, its genres. */
@Composable
fun FindBookScreen(initialQuery: String, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var query by rememberSaveable { mutableStateOf(initialQuery) }
    var sort by rememberSaveable { mutableStateOf(AudibleCatalog.SearchSort.RELEVANCE) }
    var allLanguages by rememberSaveable { mutableStateOf(false) }
    var results by remember { mutableStateOf<List<AudibleBook>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var failed by remember { mutableStateOf(false) }
    var page by remember { mutableStateOf(0) }
    var canLoadMore by remember { mutableStateOf(false) }
    var loadingMore by remember { mutableStateOf(false) }
    var showMenu by remember { mutableStateOf(false) }

    LaunchedEffect(query, sort) {
        val q = query.trim()
        if (q.length < 2) { results = null; failed = false; return@LaunchedEffect }
        delay(450)
        searching = true
        try {
            val found = AudibleCatalog.search(q, sort)
            results = found
            page = 0
            canLoadMore = found.size >= AudibleCatalog.PAGE_SIZE
            failed = false
        } catch (e: kotlinx.coroutines.CancellationException) {
            throw e
        } catch (e: Exception) {
            failed = true
        } finally {
            searching = false
        }
    }

    val shown = results?.let { if (allLanguages) it else AudibleCatalog.mainLanguage(it) }
    val inLibrary = rememberInLibrary(shown)
    val listState = rememberLazyListState()
    // Near the end: the next page.
    LaunchedEffect(listState, shown) {
        snapshotFlow { listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }.collect { last ->
            val current = results ?: return@collect
            if (!canLoadMore || loadingMore || last < listState.layoutInfo.totalItemsCount - 4) return@collect
            val q = query.trim()
            loadingMore = true
            val more = runCatching { AudibleCatalog.search(q, sort, page + 1) }.getOrNull()
            loadingMore = false
            if (more == null || q != query.trim()) return@collect
            page += 1
            val have = current.map { it.asin }.toSet()
            results = current + more.filter { it.asin !in have }
            canLoadMore = more.size >= AudibleCatalog.PAGE_SIZE
        }
    }

    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Find Book", onBack) {
            if (results != null) {
                Box {
                    IconButton(onClick = { showMenu = true }) { Icon(Icons.AutoMirrored.Filled.Sort, "Sort") }
                    DropdownMenu(showMenu, onDismissRequest = { showMenu = false }) {
                        AudibleCatalog.SearchSort.entries.forEach { s ->
                            DropdownMenuItem(
                                text = { Text(s.label, fontWeight = if (s == sort) FontWeight.Bold else null) },
                                onClick = { sort = s; showMenu = false },
                            )
                        }
                        HorizontalDivider()
                        DropdownMenuItem(
                            text = { Text("Other languages") },
                            leadingIcon = { Checkbox(allLanguages, onCheckedChange = null) },
                            onClick = { allLanguages = !allLanguages; showMenu = false },
                        )
                    }
                }
            }
        }
        KitziSearchField(query, { query = it }, "Title, author, narrator", Modifier.padding(bottom = 8.dp))
        when {
            searching && results == null -> Column { repeat(7) { LoadingRow() } }
            failed -> Unreachable()
            shown != null && shown.isEmpty() -> Text(
                "Nothing on Audible for “${query.trim()}”.",
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(24.dp),
            )
            shown != null -> LazyColumn(
                state = listState,
                contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current),
            ) {
                items(shown, key = { it.asin }) { b ->
                    AudibleRow(b, b.asin in inLibrary) { nav.openAudible(b) }
                }
                if (loadingMore) item { Box(Modifier.fillMaxWidth().padding(16.dp), contentAlignment = Alignment.Center) { com.bennybar.kitzi.ui.common.KitziLoading(Modifier.size(36.dp)) } }
            }
            else -> GenresList()
        }
    }
}

/** Audible's genres, each opening its bestsellers. */
@Composable
private fun GenresList() {
    val nav = LocalKitziNav.current
    var genres by remember { mutableStateOf<List<AudibleGenre>?>(null) }
    var failed by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        runCatching { AudibleCatalog.genres() }.onSuccess { genres = it }.onFailure { failed = true }
    }
    LazyColumn(contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current)) {
        item {
            Text("Bestsellers by Genre", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold,
                modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
        }
        val g = genres
        when {
            g != null -> items(g, key = { it.id }) { genre ->
                Row(
                    Modifier.fillMaxWidth().clickable { nav.openGenre(genre) }.padding(horizontal = 16.dp, vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(genre.name, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                    Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            failed -> item { Unreachable() }
            else -> items(8) { LoadingBlock(36.dp, Modifier.padding(horizontal = 16.dp, vertical = 6.dp), radius = 8.dp) }
        }
        item {
            Text("Or search Audible by title, author or narrator.", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp))
        }
    }
}

// MARK: genre

/** A genre's bestsellers, top rated or new releases, with its subgenres along the top. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AudibleGenreScreen(genre: AudibleGenre, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var list by rememberSaveable { mutableStateOf(AudibleCatalog.GenreList.BESTSELLERS) }
    var books by remember { mutableStateOf<List<AudibleBook>?>(null) }
    var failed by remember { mutableStateOf(false) }
    var subgenres by remember { mutableStateOf<List<AudibleGenre>>(emptyList()) }
    LaunchedEffect(list) {
        books = null
        failed = false
        runCatching { AudibleCatalog.genreBooks(genre.id, list) }.onSuccess { books = it }.onFailure { failed = true }
    }
    LaunchedEffect(genre.id) { subgenres = runCatching { AudibleCatalog.genres(genre.id) }.getOrDefault(emptyList()) }
    val inLibrary = rememberInLibrary(books)

    Column(Modifier.fillMaxSize()) {
        AudibleTopBar(genre.name, onBack)
        LazyColumn(contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current)) {
            if (subgenres.isNotEmpty()) item {
                Row(
                    Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 4.dp),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    subgenres.forEach { g -> AssistChip(onClick = { nav.openGenre(g) }, label = { Text(g.name) }) }
                }
            }
            item {
                SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp)) {
                    AudibleCatalog.GenreList.entries.forEachIndexed { i, l ->
                        SegmentedButton(
                            selected = list == l,
                            onClick = { list = l },
                            shape = SegmentedButtonDefaults.itemShape(i, AudibleCatalog.GenreList.entries.size),
                        ) { Text(l.label, maxLines = 1) }
                    }
                }
            }
            val b = books
            when {
                b != null && b.isEmpty() -> item {
                    Text(
                        if (list == AudibleCatalog.GenreList.NEW_RELEASES) "No bestsellers came out here in the last four months." else "Nothing here yet.",
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp),
                    )
                }
                b != null -> itemsIndexed(b, key = { _, it -> it.asin }) { i, book ->
                    AudibleRow(book, book.asin in inLibrary, rank = i + 1) { nav.openAudible(book) }
                }
                failed -> item { Unreachable() }
                else -> items(7) { LoadingRow() }
            }
        }
    }
}

// MARK: author, narrator, series

/** An author's or narrator's books on Audible (bestsellers first), or a series' in order. */
@Composable
fun AudibleListScreen(route: AudibleListRoute, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var books by remember { mutableStateOf<List<AudibleBook>?>(null) }
    var failed by remember { mutableStateOf(false) }
    val title = when (route) {
        is AudibleListRoute.Author -> route.name
        is AudibleListRoute.Narrator -> route.name
        is AudibleListRoute.Series -> route.title
    }
    LaunchedEffect(route) {
        runCatching {
            when (route) {
                is AudibleListRoute.Author -> AudibleCatalog.booksBy(author = route.name)
                is AudibleListRoute.Narrator -> AudibleCatalog.booksBy(narrator = route.name)
                is AudibleListRoute.Series -> AudibleCatalog.mainLanguage(
                    AudibleCatalog.seriesBooks(AudibleBook.SeriesRef(route.asin, route.title, null), null),
                )
            }
        }.onSuccess { books = it }.onFailure { failed = true }
    }
    val inLibrary = rememberInLibrary(books)
    Column(Modifier.fillMaxSize()) {
        AudibleTopBar(title, onBack)
        LazyColumn(contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current)) {
            if (route is AudibleListRoute.Narrator) item {
                Text("Narrated by ${route.name}", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp))
            }
            val b = books
            when {
                b != null && b.isEmpty() -> item { Text("Audible has nothing here.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(16.dp)) }
                b != null -> items(b, key = { it.asin }) { book ->
                    val note = (route as? AudibleListRoute.Series)?.let { r ->
                        AudibleCatalog.sequenceLabel(book, r.asin)?.let { if (it.contains("-")) "Books $it" else "Book $it" }
                    }
                    AudibleRow(book, book.asin in inLibrary, note = note) { nav.openAudible(book) }
                }
                failed -> item { Unreachable() }
                else -> items(7) { LoadingRow() }
            }
        }
    }
}

// MARK: an Audible book's page

/** An Audible book's page, laid out like Kitzi's own book page. */
@Composable
fun AudibleBookScreen(asin: String, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var full by remember { mutableStateOf<AudibleBook?>(null) }
    var failed by remember { mutableStateOf(false) }
    val book = full ?: remember(asin) { AudibleCatalog.peek(asin) }
    var mine by remember { mutableStateOf<Book?>(null) }
    LaunchedEffect(asin) {
        runCatching { AudibleCatalog.product(asin) }.onSuccess { full = it; if (it == null) failed = true }.onFailure { failed = true }
    }
    LaunchedEffect(book?.asin, book?.title) { mine = book?.let { LibraryMatcher.match(it) } }

    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Audible", onBack)
        if (book == null) {
            if (failed) Unreachable() else Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { com.bennybar.kitzi.ui.common.KitziLoading() }
            return@Column
        }
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)
                .padding(bottom = 16.dp + LocalMiniPlayerInset.current),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            AudibleCover(book.coverUrl, 220.dp, Modifier.padding(top = 8.dp))
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(book.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                book.subtitle?.let { Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center) }
                People(book.authors, prefix = null) { nav.openList(AudibleListRoute.Author(it)) }
                People(book.narrators, prefix = "Narrated by ") { nav.openList(AudibleListRoute.Narrator(it)) }
                book.stars?.let { StarsRow(it, book.ratingCount, 16.dp, Modifier.padding(top = 2.dp)) }
                Row(Modifier.padding(top = 6.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    book.minutes?.let { Chip(Icons.Default.Schedule, formatHm(it * 60L)) }
                    book.format?.let { Chip(Icons.Default.Headphones, it) }
                    book.year?.let { Chip(Icons.Default.CalendarMonth, it) }
                }
            }
            mine?.let { m ->
                Button(onClick = { nav.openBook(m.id) }, modifier = Modifier.fillMaxWidth().height(50.dp)) {
                    Icon(Icons.AutoMirrored.Filled.LibraryBooks, null)
                    Text("Open in Your Library", modifier = Modifier.padding(start = 8.dp))
                }
            }
            // Already in the library: nothing to send.
            if (mine == null) com.bennybar.kitzi.ui.services.SendToShelfarr(book.title, book.authors.firstOrNull())
            if (book.performanceStars != null || book.storyStars != null) {
                Card {
                    Text("Ratings", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    book.stars?.let { RatingLine("Overall", it) }
                    book.performanceStars?.let { RatingLine("Performance", it) }
                    book.storyStars?.let { RatingLine("Story", it) }
                }
            }
            book.summary?.takeIf { it.isNotBlank() }?.let { About(it) }
            if (UiPrefsState.audibleReviews.value) ReviewsCard(book.asin)
            Card {
                Text("Details", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                book.seriesRefs.forEach { ref ->
                    DetailLine(Icons.AutoMirrored.Filled.LibraryBooks, "Series", ref.sequence?.let { "${ref.title}, Book $it" } ?: ref.title) {
                        nav.openList(AudibleListRoute.Series(ref.asin, ref.title))
                    }
                }
                book.kind?.let { DetailLine(Icons.Default.Headphones, "Type", listOfNotNull(it, book.format).joinToString(" · ")) }
                book.genreRefs.take(5).forEachIndexed { i, g ->
                    DetailLine(if (i == 0) Icons.Default.LocalOffer else null, if (i == 0) "Genres" else "", g.name) { nav.openGenre(g) }
                }
                book.releaseDate?.let { DetailLine(Icons.Default.CalendarMonth, "Released", it) }
                book.language?.let { DetailLine(Icons.Default.Language, "Language", it) }
                book.publisher?.let { DetailLine(Icons.Default.Business, "Publisher", it) }
                DetailLine(Icons.Default.Numbers, "ASIN", book.asin)
            }
        }
    }
}

/** An author or narrator line: one person opens their books; several, a menu. */
@Composable
private fun People(names: List<String>, prefix: String?, open: (String) -> Unit) {
    if (names.isEmpty()) return
    var menu by remember { mutableStateOf(false) }
    Box {
        Text(
            buildString { prefix?.let(::append); append(names.joinToString(", ")) },
            style = if (prefix == null) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.primary,
            textAlign = TextAlign.Center,
            modifier = Modifier.clickable { if (names.size == 1) open(names[0]) else menu = true }.padding(2.dp),
        )
        DropdownMenu(menu, onDismissRequest = { menu = false }) {
            names.forEach { n -> DropdownMenuItem(text = { Text(n) }, onClick = { menu = false; open(n) }) }
        }
    }
}

@Composable
private fun Chip(icon: ImageVector, text: String) {
    Row(
        Modifier.background(MaterialTheme.colorScheme.surfaceContainerHigh, RoundedCornerShape(50)).padding(horizontal = 10.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, Modifier.size(14.dp), tint = MaterialTheme.colorScheme.primary)
        Text(text, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp))
    }
}

@Composable
fun Card(content: @Composable androidx.compose.foundation.layout.ColumnScope.() -> Unit) {
    Surface(color = MaterialTheme.colorScheme.surfaceContainer, shape = RoundedCornerShape(20.dp), modifier = Modifier.fillMaxWidth()) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(10.dp), content = content)
    }
}

@Composable
private fun RatingLine(label: String, stars: Double) {
    Row(verticalAlignment = Alignment.CenterVertically) {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.width(110.dp))
        StarsRow(stars, 0)
    }
}

@Composable
private fun About(text: String) {
    var expanded by remember { mutableStateOf(false) }
    Card {
        Text("About", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
        Text(text, style = MaterialTheme.typography.bodyMedium, maxLines = if (expanded) Int.MAX_VALUE else 6, overflow = TextOverflow.Ellipsis)
        if (text.length > 300) {
            TextButton(onClick = { expanded = !expanded }, contentPadding = PaddingValues(0.dp)) { Text(if (expanded) "Less" else "More") }
        }
    }
}

/** A details row; with [onClick], the value in the accent colour with a chevron. */
@Composable
private fun DetailLine(icon: ImageVector?, label: String, value: String, onClick: (() -> Unit)? = null) {
    Row(
        Modifier.fillMaxWidth().then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier).padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(30.dp)) {
            icon?.let { Icon(it, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(18.dp)) }
        }
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.width(84.dp))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            color = if (onClick != null) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurface,
            modifier = Modifier.weight(1f),
        )
        if (onClick != null) Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(18.dp))
    }
}
