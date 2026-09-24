package com.bennybar.kitzi.ui.library

import com.bennybar.kitzi.ui.common.plural
import kotlinx.coroutines.flow.first
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.runtime.produceState
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.material.icons.filled.SearchOff
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.AutoStories
import androidx.compose.material.icons.filled.Headphones
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
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.repeatOnLifecycle
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

    // Keep the library fresh while the user is looking at it: re-check the server
    // when the screen resumes (app-open, or coming back from another screen) and
    // every 15 minutes it stays open. The ViewModel skips a check if one ran in the
    // last few minutes. repeatOnLifecycle cancels the loop when the app is
    // backgrounded and re-runs the check when it returns.
    val lifecycleOwner = LocalLifecycleOwner.current
    LaunchedEffect(lifecycleOwner) {
        lifecycleOwner.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            vm.refreshNewestQuietly()
            while (true) {
                // Every 15 minutes, not 2: each refresh downloads the whole /api/me
                // and listening stats (only the page fetch is conditional).
                kotlinx.coroutines.delay(15 * 60 * 1000L)
                vm.refreshNewestQuietly()
            }
        }
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

    // Hoisted so the top row can bring the header into view: the controls and the
    // search field live at the top of the list, so opening them while scrolled down
    // did nothing visible.
    val listState = rememberLazyListState()
    val gridState = rememberLazyGridState()
    fun revealHeader() {
        scope.launch { if (grid) gridState.animateScrollToItem(0) else listState.animateScrollToItem(0) }
    }

    Column(Modifier.fillMaxSize()) {
        // Pinned: the library/series switch stays put while the content scrolls.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            // Centre the round control against the taller text pills — Top alignment
            // left it riding high.
            verticalAlignment = Alignment.CenterVertically,
        ) {
            SegmentedPill(
                icon = Icons.Default.Headphones,
                label = "Audiobooks",
                selected = true,
                modifier = Modifier.weight(1f),
                onClick = {},
            )
            SegmentedPill(
                icon = Icons.Default.AutoStories,
                label = "Series",
                selected = false,
                modifier = Modifier.weight(1f),
                onClick = onOpenSeries,
            )
            // Search is always one tap away (it used to be behind the controls).
            CircleIconButton(
                Icons.Default.Search, if (showSearch) "Close search" else "Search",
                selected = showSearch,
                onClick = {
                    showSearch = !showSearch
                    if (showSearch) revealHeader() else vm.setSearch("")
                },
            )
            // A dot on the controls button while a filter or non-default sort is in
            // effect, so a filtered list is never unexplained.
            val customized = query.filter != LibraryFilter.ALL || query.sort != LibraryQuery().sort
            Box {
                CircleIconButton(
                    if (toolbarVisible) Icons.Default.KeyboardArrowUp else Icons.Default.Tune,
                    if (toolbarVisible) "Hide controls" else "Show controls",
                    onClick = {
                        toolbarVisible = !toolbarVisible
                        // Closing the controls keeps the filter (it used to silently
                        // reset it); the chip below says it's on and removes it.
                        if (!toolbarVisible) { showFilter = false; showSort = false } else revealHeader()
                    },
                )
                if (customized && !toolbarVisible) {
                    Box(
                        Modifier.align(Alignment.TopEnd).padding(2.dp).size(10.dp)
                            .clip(CircleShape).background(MaterialTheme.colorScheme.primary),
                    )
                }
            }
        }
        // With the controls closed, an active filter shows as one removable chip.
        if (!toolbarVisible && query.filter != LibraryFilter.ALL) {
            Row(Modifier.padding(horizontal = 16.dp)) {
                androidx.compose.material3.InputChip(
                    selected = true,
                    onClick = { vm.setFilter(LibraryFilter.ALL) },
                    label = { Text(query.filter.label()) },
                    trailingIcon = { Icon(Icons.Default.Close, "Remove filter", Modifier.size(16.dp)) },
                )
            }
        }

        PullToRefreshBox(
            isRefreshing = refreshing,
            onRefresh = vm::refresh,
            modifier = Modifier.fillMaxSize(),
        ) {
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
                        SummaryBlock(
                            summary,
                            onStats = onOpenStats,
                            onInProgress = { vm.setFilter(LibraryFilter.IN_PROGRESS) },
                            onLibrary = {
                                scope.launch {
                                    if (grid) gridState.animateScrollToItem(1) else listState.animateScrollToItem(1)
                                }
                            },
                        )
                        if (continueListening.isNotEmpty()) {
                            SectionHeader(Icons.Default.PlayArrow, "Continue Listening", Modifier.padding(horizontal = 16.dp))
                            Shelf(continueListening, onOpenBook, progressById)
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
                    if (books.isEmpty()) {
                        item(key = "empty", span = { GridItemSpan(maxLineSpan) }) {
                            LibraryEmpty(filtered = !showHeader, loaded = summary.loaded) {
                                vm.setSearch(""); vm.setFilter(LibraryFilter.ALL); showSearch = false
                            }
                        }
                    }
                    items(books, key = { "b_${it.id}" }) { book ->
                        BookGridItem(book, progressById[book.id], book.id in downloadedIds) { onOpenBook(book.id) }
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
                        // Nothing to list: say why, instead of a blank page under the header.
                        if (books.isEmpty()) {
                            item(key = "empty") {
                                LibraryEmpty(filtered = !showHeader, loaded = summary.loaded) {
                                    vm.setSearch(""); vm.setFilter(LibraryFilter.ALL); showSearch = false
                                }
                            }
                        }
                        items(books, key = { "b_${it.id}" }) { book ->
                            BookCard(
                                book,
                                Modifier.padding(horizontal = 16.dp),
                                progress = progressById[book.id],
                                downloaded = book.id in downloadedIds,
                            ) { onOpenBook(book.id) }
                        }
                    }
                    // A–Z fast-scroll rail (the ui_letter_scroll_enabled setting). Only
                    // under A–Z sort — under "Recently added" letters mean nothing — and
                    // built from EVERY title in list order, not just the loaded window
                    // (the list pages 60 at a time, so most letters used to be missing).
                    // Hebrew titles bring their own letters, after the Latin ones.
                    val showRail = com.bennybar.kitzi.ui.UiPrefsState.letterScrollEnabled.value &&
                        query.sort == BookSort.NAME_ASC && books.isNotEmpty()
                    if (showRail) {
                        val titles by produceState(emptyList<String>(), query.filter, query.search, refreshing) {
                            value = vm.sortedTitles()
                        }
                        val anchors = remember(titles) {
                            LinkedHashMap<Char, Int>().apply {
                                // The FIRST character decides, as it does for the SQL sort: a
                                // title opening with a quote or digit sorts before "A", so
                                // it belongs under "#" — taking its first letter instead
                                // put "B" and "T" ahead of "A".
                                titles.forEachIndexed { i, t ->
                                    val first = t.trimStart().firstOrNull()
                                    putIfAbsent(if (first != null && first.isLetter()) first.uppercaseChar() else '#', i)
                                }
                            }
                        }
                        if (anchors.size > 1) {
                            LetterRail(
                                letters = anchors.keys.toList(),
                                onLetter = { c ->
                                    anchors[c]?.let { i ->
                                        scope.launch {
                                            // Load far enough first, then jump (row 0 is the header).
                                            vm.ensureLoaded(i)
                                            androidx.compose.runtime.snapshotFlow { books.size }.first { it > i }
                                            listState.scrollToItem(i + 1)
                                        }
                                    }
                                },
                                modifier = Modifier.align(Alignment.CenterEnd).padding(end = 2.dp),
                            )
                        }
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

/**
 * A slim right-edge A–Z rail. Tap a letter, or drag along the rail, to jump the
 * list; while touching, a bubble shows the letter under the finger. The whole rail
 * is the touch target (each letter used to be a ~14dp tap target on its own).
 */
@Composable
private fun LetterRail(letters: List<Char>, onLetter: (Char) -> Unit, modifier: Modifier = Modifier) {
    var active by remember { mutableStateOf<Char?>(null) }
    var railHeight by remember { mutableIntStateOf(1) }
    fun letterAt(y: Float): Char =
        letters[((y / railHeight) * letters.size).toInt().coerceIn(0, letters.lastIndex)]
    fun select(y: Float) {
        val c = letterAt(y)
        if (c != active) { active = c; onLetter(c) }
    }
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        active?.let { c ->
            Surface(
                color = MaterialTheme.colorScheme.primary,
                contentColor = MaterialTheme.colorScheme.onPrimary,
                shape = CircleShape,
                shadowElevation = 6.dp,
                modifier = Modifier.padding(end = 10.dp).size(56.dp),
            ) {
                Box(contentAlignment = Alignment.Center) {
                    Text(c.toString(), style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold)
                }
            }
        }
        Surface(
            color = MaterialTheme.colorScheme.surfaceContainerHigh.copy(alpha = 0.85f),
            shape = RoundedCornerShape(14.dp),
        ) {
            Column(
                Modifier
                    .width(28.dp)
                    .fillMaxHeight(0.8f)
                    .heightIn(max = (letters.size * 18).dp)
                    .padding(vertical = 6.dp)
                    .onSizeChanged { railHeight = it.height.coerceAtLeast(1) }
                    .pointerInput(letters) {
                        detectTapGestures(
                            onPress = { select(it.y); tryAwaitRelease(); active = null },
                        )
                    }
                    .pointerInput(letters) {
                        detectVerticalDragGestures(
                            onDragStart = { select(it.y) },
                            onDragEnd = { active = null },
                            onDragCancel = { active = null },
                            onVerticalDrag = { change, _ -> select(change.position.y) },
                        )
                    },
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                letters.forEach { c ->
                    Box(Modifier.weight(1f), contentAlignment = Alignment.Center) {
                        Text(
                            c.toString(),
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (c == active) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.primary,
                        )
                    }
                }
            }
        }
    }
}

/** Why the list is empty: no matches for the search/filter, or no books yet. */
@Composable
private fun LibraryEmpty(filtered: Boolean, loaded: Boolean, onClear: () -> Unit) {
    if (!filtered && !loaded) return // still loading: the tiles show "—"
    Column(
        Modifier.fillMaxWidth().padding(horizontal = 32.dp, vertical = 40.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            if (filtered) Icons.Default.SearchOff else Icons.Default.Headphones, null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(48.dp),
        )
        Text(
            if (filtered) "No matches" else "Your library is empty",
            style = MaterialTheme.typography.titleLarge,
            modifier = Modifier.padding(top = 12.dp),
        )
        Text(
            if (filtered) "Nothing in your library matches this search or filter."
            else "Books you add on the server appear here. Pull down to refresh.",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            modifier = Modifier.padding(top = 6.dp),
        )
        if (filtered) {
            androidx.compose.material3.TextButton(onClick = onClear, modifier = Modifier.padding(top = 8.dp)) {
                Text("Clear search and filters")
            }
        }
    }
}

/** The pill of circular icon buttons that fronts the library. */
@Composable
private fun Toolbar(
    grid: Boolean,
    onToggleLayout: () -> Unit,
    onStats: () -> Unit,
    onProfile: () -> Unit,
    onFilter: () -> Unit,
    onSort: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(32.dp),
        // Full width (like the pills above) with the icons spread evenly, instead of
        // a content-sized pill hugging the left with empty space on the right.
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 8.dp),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
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
private fun SummaryBlock(
    summary: LibrarySummary,
    onStats: () -> Unit,
    onInProgress: () -> Unit,
    onLibrary: () -> Unit,
) {
    // "—" until the first load, instead of a row of zeros that then jumps.
    val ready = summary.loaded
    fun v(text: String) = if (ready) text else "—"
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainer,
        shape = RoundedCornerShape(24.dp),
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Column(Modifier.padding(12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SummaryTile(
                    "Listening today",
                    v(formatHm(summary.todaySec.toLong())),
                    if (ready && summary.weekSec > 0) "This week: ${formatHm(summary.weekSec.toLong())}" else "Today",
                    Icons.Default.Schedule,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                    onClick = onStats,
                )
                SummaryTile(
                    "Streak",
                    v(if (summary.streakDays > 0) plural(summary.streakDays, "day") else "Start today"),
                    when {
                        !ready -> ""
                        summary.bestStreakDays > summary.streakDays -> "Best: ${plural(summary.bestStreakDays, "day")}"
                        summary.streakDays > 0 -> "Your best yet"
                        else -> "No active streak"
                    },
                    Icons.Default.LocalFireDepartment,
                    Color(0xFFE8A33D),
                    Modifier.weight(1f),
                    onClick = onStats,
                )
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                SummaryTile(
                    "In progress",
                    v(plural(summary.inProgress, "book")),
                    if (ready && summary.leftInProgressSec > 0) "${formatHm(summary.leftInProgressSec.toLong())} left" else "Nothing in progress",
                    Icons.Default.PlayArrow,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                    onClick = onInProgress,
                )
                SummaryTile(
                    "Library",
                    v(plural(summary.libraryCount, "title")),
                    if (ready && summary.addedThisWeek > 0) "+${summary.addedThisWeek} this week" else "Newest first",
                    Icons.Default.LibraryBooks,
                    MaterialTheme.colorScheme.primary,
                    Modifier.weight(1f),
                    onClick = onLibrary,
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
    onClick: () -> Unit,
) {
    Surface(
        color = MaterialTheme.colorScheme.surfaceContainerHigh,
        shape = RoundedCornerShape(18.dp),
        modifier = modifier,
        onClick = onClick,
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
private fun Shelf(
    books: List<Book>,
    onOpenBook: (String) -> Unit,
    /** Set for Continue Listening: each card shows its progress and time left. */
    progressById: Map<String, MediaProgressEntity>? = null,
) {
    val speed = com.bennybar.kitzi.data.Services.prefs.getDouble("playback_speed", 1.0).coerceAtLeast(0.1)
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
                    val p = progressById?.get(book.id)
                    Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp))) {
                        AsyncImage(
                            model = book.coverUrl,
                            contentDescription = book.title,
                            contentScale = ContentScale.Crop,
                            modifier = Modifier.fillMaxSize(),
                        )
                        p?.progress?.toFloat()?.takeIf { it > 0f && !p.isFinished }?.let { CoverProgressBar(it) }
                    }
                    Text(
                        book.title,
                        style = MaterialTheme.typography.bodyLarge,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.padding(top = 8.dp),
                    )
                    // Continue Listening: time left at your speed, where the author
                    // would be (the author is already on the cover for most books).
                    val left = p?.takeIf { !it.isFinished }?.let {
                        val d = it.durationSec.takeIf { d -> d > 0 } ?: (book.durationMs ?: 0L) / 1000.0
                        ((d - it.currentTimeSec).coerceAtLeast(0.0) / speed).takeIf { l -> l > 0 }
                    }
                    (left?.let { "${formatHm(it.toLong())} left" } ?: book.author)?.let {
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

/** The slim progress bar across the bottom of a cover. */
@Composable
private fun androidx.compose.foundation.layout.BoxScope.CoverProgressBar(fraction: Float) {
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
                .fillMaxWidth(fraction.coerceIn(0f, 1f))
                .background(MaterialTheme.colorScheme.primary),
        )
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
                if (frac != null && frac > 0f) CoverProgressBar(frac)
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
private fun BookGridItem(book: Book, progress: MediaProgressEntity?, downloaded: Boolean, onClick: () -> Unit) {
    Column(Modifier.clickable(onClick = onClick)) {
        // The same marks the list rows have: progress, finished, downloaded.
        Box(Modifier.fillMaxWidth().aspectRatio(1f).clip(RoundedCornerShape(12.dp))) {
            AsyncImage(
                model = book.coverUrl,
                contentDescription = book.title,
                contentScale = ContentScale.Crop,
                modifier = Modifier.fillMaxSize(),
            )
            progress?.progress?.toFloat()?.takeIf { it > 0f && !progress.isFinished }?.let { CoverProgressBar(it) }
            Row(
                Modifier.align(Alignment.TopEnd).padding(6.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                if (downloaded) GridBadge(Icons.Default.DownloadDone, "Downloaded", Color(0xFF4CAF50))
                if (progress?.isFinished == true) GridBadge(Icons.Default.CheckCircle, "Finished", Color(0xFF4CAF50))
            }
        }
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

@Composable
private fun GridBadge(icon: androidx.compose.ui.graphics.vector.ImageVector, description: String, tint: Color) {
    Box(
        Modifier.size(24.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.55f)),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, description, tint = tint, modifier = Modifier.size(16.dp))
    }
}
