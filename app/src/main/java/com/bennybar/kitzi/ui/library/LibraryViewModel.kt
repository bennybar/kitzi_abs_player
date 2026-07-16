package com.bennybar.kitzi.ui.library

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.LibraryFilter
import com.bennybar.kitzi.data.model.Book
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

data class LibraryQuery(
    val sort: BookSort = BookSort.ADDED_DESC,
    val filter: LibraryFilter = LibraryFilter.ALL,
    val search: String = "",
    val limit: Int = 60,
)

/** The four tiles across the top of the home screen. */
data class LibrarySummary(
    val todaySec: Double = 0.0,
    val streakDays: Int = 0,
    val inProgress: Int = 0,
    val libraryCount: Int = 0,
)

@OptIn(ExperimentalCoroutinesApi::class)
class LibraryViewModel : ViewModel() {

    private val books = Services.books

    val query = MutableStateFlow(LibraryQuery())
    // The Flutter app's default library view is the list, not the grid.
    val grid = MutableStateFlow(false)
    val refreshing = MutableStateFlow(false)
    val ready = MutableStateFlow(false)

    /**
     * The list is a query, not a filtered copy of something already loaded. Every
     * change to sort/filter/search re-runs SQL over the whole library, so paging
     * stays correct — sorting only the books currently paged in is the single
     * most "app feels broken" bug there is.
     */
    val items = query
        .flatMapLatest { q ->
            books.pagedBooks(q.sort, q.filter, q.search.takeIf { it.isNotBlank() }, q.limit, 0)
        }
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val continueListening = MutableStateFlow<List<Book>>(emptyList())
    val recentlyAdded = MutableStateFlow<List<Book>>(emptyList())
    val summary = MutableStateFlow(LibrarySummary())

    val progress = books.watchProgress()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    init {
        viewModelScope.launch {
            runCatching {
                books.ensureLibrary()
                ready.value = true
            }.onFailure { Log.w(TAG, "could not open the library", it) }

            // Each step is guarded on its own: a server hiccup while warming the
            // cache must not stop the shelves (which read from the local DB) from
            // being populated. Lumping them into one runCatching meant a single
            // failure silently blanked the home screen.
            // First page fast, so the grid paints; then the rest of the library in
            // the background, because sort/filter/search are SQL over the cache and
            // a half-cached library would only sort the half that is loaded.
            runCatching { books.fetchPage(page = 1, limit = 50, force = false) }
                .onFailure { Log.w(TAG, "page warm-up failed", it) }
            runCatching { books.syncProgress() }
                .onFailure { Log.w(TAG, "progress sync failed", it) }
            runCatching { loadShelves() }
                .onFailure { Log.w(TAG, "shelves failed", it) }
            runCatching { books.syncAll() }
                .onFailure { Log.w(TAG, "full library sync failed", it) }
            runCatching { loadShelves() }
                .onFailure { Log.w(TAG, "shelves failed", it) }
        }
    }

    private suspend fun loadShelves() {
        continueListening.value = books.continueListening()
        recentlyAdded.value = books.recentlyAdded()

        val stats = runCatching { books.listeningStats() }.getOrNull()
        summary.value = LibrarySummary(
            todaySec = stats?.perDaySec?.get(today()) ?: 0.0,
            streakDays = stats?.perDaySec?.let(::streakFrom) ?: 0,
            inProgress = continueListening.value.size,
            // The locally-cached count, matching the Profile screen's number
            // (the server total can include non-audiobook items).
            libraryCount = books.countBooks(LibraryFilter.ALL, null),
        )
    }

    private fun today(): String =
        java.time.LocalDate.now().format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)

    /** Consecutive days with any listening, counting back from today. */
    private fun streakFrom(perDay: Map<String, Double>): Int {
        var day = java.time.LocalDate.now()
        var streak = 0
        while (true) {
            val key = day.format(java.time.format.DateTimeFormatter.ISO_LOCAL_DATE)
            if ((perDay[key] ?: 0.0) <= 0) return streak
            streak++
            day = day.minusDays(1)
        }
    }

    /**
     * Pulls the newest server additions into the cache and repaints the shelves.
     * Fetches page 1 by "date added" so a book added on the server since the last
     * sync appears — on the recently-added shelf, and (because the list is SQL
     * over the cache) in the main list under whatever sort is active.
     */
    private suspend fun syncNewest(force: Boolean) {
        runCatching { books.fetchPage(page = 1, sort = BookSort.ADDED_DESC, force = force) }
            .onFailure { Log.w(TAG, "recent sync failed", it) }
        runCatching { books.syncProgress() }
            .onFailure { Log.w(TAG, "progress sync failed", it) }
        runCatching { loadShelves() }
            .onFailure { Log.w(TAG, "shelves failed", it) }
    }

    /**
     * Pull-to-refresh. Deliberately forced: a conditional request answered 304
     * used to be served from the local DB, so newly added books never appeared no
     * matter how many times the user pulled.
     */
    fun refresh() {
        if (refreshing.value) return
        refreshing.value = true
        viewModelScope.launch {
            syncNewest(force = true)
            refreshing.value = false
        }
    }

    private var quietSyncing = false

    /**
     * A quiet refresh (no pull spinner) for when the screen resumes and on a
     * periodic tick while it's open. Conditional, so an unchanged library answers
     * 304 and costs nothing; only a real change transfers a page. WorkManager's
     * periodic sync is hours apart and doesn't help someone who just added a book
     * on the server and switched back to the app.
     */
    fun refreshNewestQuietly() {
        if (quietSyncing || refreshing.value) return
        quietSyncing = true
        viewModelScope.launch {
            syncNewest(force = false)
            quietSyncing = false
        }
    }

    fun loadMore() {
        val q = query.value
        // The current window came back smaller than requested -> the cache has no
        // more rows to show, so widening the window would do nothing. Stops the
        // infinite-scroll trigger from firing forever at the end of the list.
        if (items.value.size < q.limit) return
        viewModelScope.launch {
            // Widen the window; the query re-runs and Room emits the longer list.
            query.value = q.copy(limit = q.limit + 60)
            runCatching { books.fetchPage(page = (q.limit / 50) + 1, limit = 50, sort = q.sort) }
        }
    }

    private companion object {
        const val TAG = "LibraryViewModel"
    }

    fun setSort(sort: BookSort) { query.value = query.value.copy(sort = sort, limit = 60) }
    fun setFilter(filter: LibraryFilter) { query.value = query.value.copy(filter = filter, limit = 60) }
    fun setSearch(text: String) { query.value = query.value.copy(search = text, limit = 60) }
    fun toggleGrid() { grid.value = !grid.value }
}
