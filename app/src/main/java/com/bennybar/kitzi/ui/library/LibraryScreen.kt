package com.bennybar.kitzi.ui.library

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.BarChart
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.DownloadDone
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.filled.LocalFireDepartment
import androidx.compose.material.icons.filled.MonitorHeart
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Schedule
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.SwapVert
import androidx.compose.material.icons.filled.ViewList
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import coil.compose.AsyncImage
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.LibraryFilter
import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.common.CircleIconButton
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.SectionHeader
import com.bennybar.kitzi.ui.common.SegmentedPill
import com.bennybar.kitzi.ui.common.formatHm
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    onOpenBook: (String) -> Unit,
    onOpenSeries: () -> Unit,
    onOpenStats: () -> Unit,
    onOpenProfile: () -> Unit = {},
    vm: LibraryViewModel = viewModel(),
) {
    val books by vm.items.collectAsStateWithLifecycle()
    val query by vm.query.collectAsStateWithLifecycle()
    val grid by vm.grid.collectAsStateWithLifecycle()
    val refreshing by vm.refreshing.collectAsStateWithLifecycle()
    val continueListening by vm.continueListening.collectAsStateWithLifecycle()
    val recentlyAdded by vm.recentlyAdded.collectAsStateWithLifecycle()
    val summary by vm.summary.collectAsStateWithLifecycle()
    val progressById by vm.progress.collectAsStateWithLifecycle()
    val scope = rememberCoroutineScope()

    // The set of fully-downloaded items, for the row's download badge. Refreshed
    // when the library refreshes.
    var downloadedIds by remember { mutableStateOf<Set<String>>(emptySet()) }
    LaunchedEffect(refreshing, books.size) {
        downloadedIds = com.bennybar.kitzi.data.Services.downloads.downloadedItemIds().toSet()
    }

    // "Books tab alphabetical order" forces A–Z sort so the letter rail's jumps are
    // meaningful.
    val booksAlpha = com.bennybar.kitzi.ui.UiPrefsState.letterScrollBooksAlpha.value
    LaunchedEffect(booksAlpha) {
        if (booksAlpha && query.sort != BookSort.NAME_ASC) vm.setSort(BookSort.NAME_ASC)
    }

    var showSearch by remember { mutableStateOf(false) }
    // The search/grid/stats/filter/sort toolbar is hidden by default and revealed by
    // the control button to the right of the Series pill, so the top stays clean.
    var toolbarVisible by rememberSaveable { mutableStateOf(false) }
    var showFilter by remember { mutableStateOf(false) }
    var showSort by remember { mutableStateOf(false) }

    // The shelves and the summary belong to the "home" state; once the user is
    // searching or filtering they are hunting for one book and the header is noise.
    val showHeader = query.search.isBlank() && query.filter == LibraryFilter.ALL

    Column(Modifier.fillMaxSize()) {
        // Pinned: the library/series switch stays put while the content scrolls.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            SegmentedPill(
                icon = Icons.Default.MonitorHeart,
                label = "Audiobooks",
                selected = true,
                modifier = Modifier.weight(1f),
                onClick = {},
            )
            SegmentedPill(
                icon = Icons.Default.LibraryBooks,
                label = "Series",
                selected = false,
                modifier = Modifier.weight(1f),
                onClick = onOpenSeries,
            )
            CircleIconButton(
                if (toolbarVisible) Icons.Default.KeyboardArrowUp else Icons.Default.Tune,
                if (toolbarVisible) "Hide controls" else "Show controls",
                onClick = { toolbarVisible = !toolbarVisible },
            )
        }

        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = vm::refresh,
            modifier = Modifier.fillMaxSize(),
        ) {
            val listState = rememberLazyListState()
            val gridState = rememberLazyGridState()

            // Infinite scroll: widen the query window as the end of the list nears,
            // so the library isn't capped at the first 60 of N books. loadMore()
            // self-terminates once the cache is exhausted.
            LaunchedEffect(grid, listState, gridState) {
                val flow = if (grid) {
                    androidx.compose.runtime.snapshotFlow {
                        (gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) to
                            gridState.layoutInfo.totalItemsCount
                    }
                } else {
                    androidx.compose.runtime.snapshotFlow {
                        (listState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0) to
                            listState.layoutInfo.totalItemsCount
                    }
                }
                flow.collect { (lastVisible, total) ->
                    if (total > 0 && lastVisible >= total - 6) vm.loadMore()
                }
            }

            @Composable
            fun Header() {
                Column {
                    if (toolbarVisible) {
                        Toolbar(
                            grid = grid,
                            onSearch = { showSearch = !showSearch },
                            onToggleLayout = vm::toggleGrid,
                            onStats = onOpenStats,
                            onProfile = onOpenProfile,
                            onFilter = { showFilter = !showFilter },
                            onSort = { showSort = !showSort },
                        )
                    }

                    if (showSearch) {
                        KitziSearchField(
                            value = query.search,
                            onValueChange = vm::setSearch,
                            placeholder = "Search books",
                            modifier = Modifier.padding(bottom = 8.dp),
                        )
                    }
                    if (showFilter) {
                        ChipRow(
                            options = LibraryFilter.entries.map { it to it.label() },
                            selected = query.filter,
                            onSelect = vm::setFilter,
                        )
                    }
                    if (showSort) {
                        ChipRow(
                            options = listOf(
                                BookSort.ADDED_DESC to "Recently added",
                                BookSort.NAME_ASC to "Title A–Z",
                            ),
                            selected = query.sort,
                            onSelect = vm::setSort,
                        )
                    }

                    if (showHeader) {
                        SummaryBlock(summary)
                        if (continueListening.isNotEmpty()) {
                            SectionHeader(Icons.Default.PlayArrow, "Continue Listening", Modifier.padding(horizontal = 16.dp))
                            Shelf(continueListening, onOpenBook)
                        }
                        if (recentlyAdded.isNotEmpty()) {
                            SectionHeader(Icons.Default.AutoAwesome, "Recently Added", Modifier.padding(horizontal = 16.dp))
                            Shelf(recentlyAdded, onOpenBook)
                        }
                    }
                }
            }

            if (grid) {
                LazyVerticalGrid(
                    state = gridState,
                    columns = GridCells.Adaptive(120.dp),
                    contentPadding = androidx.compose.foundation.layout.PaddingValues(
                        start = 16.dp, top = 16.dp, end = 16.dp,
                        bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                    ),
                    horizontalArrangement = Arrangement.spacedBy(12.dp),
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    item(key = "header", span = { GridItemSpan(maxLineSpan) }) { Header() }
                    items(books, key = { "b_${it.id}" }) { book ->
                        BookGridItem(book) { onOpenBook(book.id) }
                    }
                }
            } else {
                Box(Modifier.fillMaxSize()) {
                    LazyColumn(
                        state = listState,
                        contentPadding = androidx.compose.foundation.layout.PaddingValues(
                            bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                        ),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                        modifier = Modifier.fillMaxSize(),
                    ) {
                        item(key = "header") { Header() }
                        items(books, key = { "b_${it.id}" }) { book ->
                            BookCard(
                                book,
                                Modifier.padding(horizontal = 16.dp),
                                progress = progressById[book.id],
                                downloaded = book.id in downloadedIds,
                            ) { onOpenBook(book.id) }
                        }
                    }
                    // A–Z fast-scroll rail (the ui_letter_scroll_enabled setting).
                    if (com.bennybar.kitzi.ui.UiPrefsState.letterScrollEnabled.value && books.isNotEmpty() && showHeader) {
                        val anchors = remember(books) {
                            LinkedHashMap<Char, Int>().apply {
                                books.forEachIndexed { i, b ->
                                    val c = b.title.firstOrNull { it.isLetter() }?.uppercaseChar() ?: '#'
                                    putIfAbsent(c, i)
                                }
                            }
                        }
                        LetterRail(
                            letters = anchors.keys.sorted(),
                            onLetter = { c -> anchors[c]?.let { scope.launch { listState.scrollToItem(it + 1) } } },
                            modifier = Modifier.align(Alignment.CenterEnd).padding(end = 2.dp),
                        )
                    }
                }
            }
        }
    }
}

private fun LibraryFilter.label() = when (this) {
    LibraryFilter.ALL -> "All"
    LibraryFilter.IN_PROGRESS -> "In progress"
    LibraryFilter.NOT_STARTED -> "Not started"
    LibraryFilter.FINISHED -> "Finished"
}

/** A slim right-edge A–Z rail; tapping a letter jumps the list to its first book. */
@Composable
private fun LetterRail(letters: List<Char>, onLetter: (Char) -> Unit, modifier: Modifier = Modifier) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.85f),
        shape = RoundedCornerShape(12.dp),
        modifier = modifier,
    ) {
        Column(
            Modifier.width(22.dp).padding(vertical = 6.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(1.dp),
        ) {
            letters.forEach { c ->
                Text(
                    c.toString(),
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier
                        .clip(RoundedCornerShape(4.dp))
                        .clickable { onLetter(c) }
                        .padding(horizontal = 4.dp, vertical = 1.dp),
                )
            }
        }
    }
}

/** The pill of circular icon buttons that fronts the library. */
@Composable
private fun Toolbar(
    grid: Boolean,
    onSearch: () -> Unit,
    onToggleLayout: () -> Unit,
    onStats: () -> Unit,
    onProfile: () -> Unit,
    onFilter: () -> Unit,
    onSort: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(32.dp),
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(
            Modifier.padding(horizontal = 10.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            CircleIconButton(Icons.Default.Search, "Search", onClick = onSearch)
            CircleIconButton(
                if (grid) Icons.Default.ViewList else Icons.Default.GridView,
                "Toggle layout",
                onClick = onToggleLayout,
            )
            CircleIconButton(Icons.Default.BarChart, "Stats", onClick = onStats)
            CircleIconButton(Icons.Default.Person, "Profile", onClick = onProfile)
            CircleIconButton(Icons.Default.FilterList, "Filter", onClick = onFilter)
            CircleIconButton(Icons.Default.SwapVert, "Sort", onClick = onSort)
        }
    }
}

@Composable
private fun <T> ChipRow(options: List<Pair<T, String>>, selected: T, onSelect: (T) -> Unit) {
    Row(
        Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        options.forEach { (value, label) ->
            FilterChip(
                selected = selected == value,
                onClick = { onSelect(value) },
                label = { Text(label) },
            )
        }
    }
}

/** The 2x2 at-a-glance block: one container, four inner cards, each with a tinted badge. */
@Composable
private fun SummaryBlock(summary: LibrarySummary) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SummaryTile(
                    "Listening Time",
                    formatHm(summary.todaySec.toLong()),
                    "Today",
                    Icons.Default.Schedule,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                )
                SummaryTile(
                    "Streak",
                    if (summary.streakDays > 0) "${summary.streakDays} days" else "Start today",
                    if (summary.streakDays > 0) "Keep momentum" else "No active streak",
                    Icons.Default.LocalFireDepartment,
                    Color(0xFFE8A33D),
                    Modifier.weight(1f),
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SummaryTile(
                    "Continue Listening",
                    "${summary.inProgress} books",
                    "Jump back in quickly",
                    Icons.Default.PlayArrow,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                )
                SummaryTile(
                    "Library",
                    "${summary.libraryCount} titles",
                    "Freshest shelf on top",
                    Icons.Default.LibraryBooks,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                )
            }
        }
    }
}

@Composable
private fun SummaryTile(
    label: String,
    value: String,
    caption: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(18.dp),
        modifier = modifier,
    ) {
        Column(Modifier.padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(
                label,
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.SemiBold,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Row(verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.size(34.dp).clip(CircleShape).background(tint.copy(alpha = 0.16f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(icon, null, tint = tint, modifier = Modifier.size(18.dp))
                }
                Text(
                    value,
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.padding(start = 10.dp),
                )
            }
            Text(
                caption,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

/**
 * A horizontally scrolling shelf of cover cards.
 *
 * A plain scrolling Row, not a LazyRow: this can sit inside a LazyVerticalGrid
 * item, and a lazy list nested in a lazy layout on the cross axis measures to
 * zero height and silently disappears.
 */
@Composable
private fun Shelf(books: List<Book>, onOpenBook: (String) -> Unit) {
    Row(
        Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 16.dp),
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        books.forEach { book ->
            Surface(
                color = MaterialTheme.colorScheme.surfaceContainer,
                shape = RoundedCornerShape(18.dp),
                modifier = Modifier.width(150.dp).clickable { onOpenBook(book.id) },
            ) {
                Column(Modifier.padding(10.dp)) {
                    AsyncImage(
                        model = book.coverUrl,
                        contentDescription = book.title,
                        contentScale = ContentScale.Crop,
                        modifier = Modifier
                            .fillMaxWidth()
                            .aspectRatio(1f)
                            .clip(RoundedCornerShape(12.dp)),
                    )
                    Text(
                        book.title,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    book.author?.let {
                        Text(
                            it,
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
            }
        }
    }
}

/** The default library row: cover (with a progress overlay), title, series (tinted), author, narrator, duration, state, chevron. */
@Composable
fun BookCard(
    book: Book,
    modifier: Modifier = Modifier,
    progress: MediaProgressEntity? = null,
    downloaded: Boolean = false,
    onClick: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(18.dp),
        modifier = modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Row(Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(84.dp).clip(RoundedCornerShape(12.dp))) {
                AsyncImage(
                    model = book.coverUrl,
                    contentDescription = book.title,
                    contentScale = ContentScale.Crop,
                    modifier = Modifier.fillMaxSize(),
                )
                // A slim progress bar across the bottom of the cover for books in
                // progress (not the finished ones, which read as a full bar of noise).
                val frac = progress?.takeIf { it.isFinished != true }?.progress?.toFloat()
                if (frac != null && frac > 0f) {
                    Box(
                        Modifier
                            .align(Alignment.BottomCenter)
                            .fillMaxWidth()
                            .height(5.dp)
                            .background(Color.Black.copy(alpha = 0.35f)),
                    ) {
                        Box(
                            Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(frac.coerceIn(0f, 1f))
                                .background(MaterialTheme.colorScheme.primary),
                        )
                    }
                }
            }
            Column(Modifier.weight(1f).padding(start = 14.dp)) {
                Text(
                    book.title,
                    style = MaterialTheme.typography.titleMedium,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
                // The series line is tinted and sits above the author. Hidden when
                // it merely repeats the author, if that setting is on.
                val hideDupeSeries = com.bennybar.kitzi.ui.UiPrefsState.hideSeriesWhenSameAsAuthor.value
                book.series
                    ?.takeUnless { hideDupeSeries && it.equals(book.author, ignoreCase = true) }
                    ?.let { series ->
                    val sequence = book.seriesSequence
                        ?.let { s -> if (s % 1.0 == 0.0) " #${s.toInt()}" else " #$s" }
                        .orEmpty()
                    Text(
                        "$series$sequence",
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.primary,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                book.author?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                book.narrators.takeIf { it.isNotEmpty() }?.let {
                    Text(
                        "Narrated by ${it.joinToString(", ")}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                Row(Modifier.padding(top = 4.dp), verticalAlignment = Alignment.CenterVertically) {
                    book.durationMs?.let { ms ->
                        Icon(
                            Icons.Default.Schedule,
                            null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.size(16.dp),
                        )
                        Text(
                            formatHm(ms / 1000),
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            modifier = Modifier.padding(start = 6.dp),
                        )
                    }
                    // A downloaded badge sits alongside the duration, as in Flutter.
                    if (downloaded) {
                        Icon(
                            Icons.Default.DownloadDone,
                            "Downloaded",
                            tint = Color(0xFF4CAF50),
                            modifier = Modifier.padding(start = 10.dp).size(16.dp),
                        )
                    }
                }
            }
            // Finished books get a filled green check; started ones a tinted check.
            when {
                progress?.isFinished == true -> Icon(
                    Icons.Default.CheckCircle,
                    "Finished",
                    tint = Color(0xFF4CAF50),
                    modifier = Modifier.size(22.dp),
                )
                (progress?.progress ?: 0.0) > 0 -> Icon(
                    Icons.Default.CheckCircle,
                    "In progress",
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(22.dp),
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

@Composable
private fun BookGridItem(book: Book, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        AsyncImage(
            model = book.coverUrl,
            contentDescription = book.title,
            contentScale = ContentScale.Crop,
            modifier = Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp)),
        )
        Text(
            book.title,
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.SemiBold,
            maxLines = 2,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.padding(top = 6.dp),
        )
        book.author?.let {
            Text(
                it,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
