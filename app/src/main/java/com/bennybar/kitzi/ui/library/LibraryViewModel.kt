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
import kotlinx.coroutines.flow.distinctUntilChanged
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
    /** False until the first load, so the tiles show "—" rather than zeros. */
    val loaded: Boolean = false,
    val weekSec: Double = 0.0,
    val bestStreakDays: Int = 0,
    /** Wall-clock time left (at the current speed) across the books in progress. */
    val leftInProgressSec: Double = 0.0,
    /** Books added in the last 7 days (counted from the Recently added shelf). */
    val addedThisWeek: Int = 0,
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
        // A write that didn't change what's shown (a sync touching other rows) must
        // not recompose the list.
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyList())

    val continueListening = MutableStateFlow<List<Book>>(emptyList())
    val recentlyAdded = MutableStateFlow<List<Book>>(emptyList())
    val summary = MutableStateFlow(LibrarySummary())

    val progress = books.watchProgress()
        .distinctUntilChanged()
        .stateIn(viewModelScope, SharingStarted.WhileSubscribed(5_000), emptyMap())

    /** When the last quiet refresh (or the init sync) started; see refreshNewestQuietly. */
    private var lastQuietSyncAt = 0L

    init {
        // The init sync below covers what a quiet refresh would do, so the screen's
        // first on-resume refresh (which fires at the same moment) is skipped.
        lastQuietSyncAt = android.os.SystemClock.elapsedRealtime()
        viewModelScope.launch {
            openLibrary()

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
            runCatching { books.syncAllIfStale() }
                .onFailure { Log.w(TAG, "full library sync failed", it) }
            runCatching { loadShelves() }
                .onFailure { Log.w(TAG, "shelves failed", it) }
            // One-time-ish, idempotent: upgrade any 400px covers left on disk to a
            // crisp one, and save offline covers for books downloaded before that
            // existed. Last so they never delay the library or shelves appearing.
            runCatching { books.refreshLowResCovers() }
                .onFailure { Log.w(TAG, "cover refresh failed", it) }
            runCatching { books.ensureDownloadedCovers() }
                .onFailure { Log.w(TAG, "downloaded-cover backfill failed", it) }
        }
    }

    /**
     * Opens the library if it isn't yet. On a first login this is a network call,
     * and when it failed nothing retried: the home screen stayed empty for the
     * whole session. The refresh paths call it again until it succeeds.
     */
    private suspend fun openLibrary() {
        if (ready.value) return
        runCatching {
            books.ensureLibrary()
            ready.value = true
        }.onFailure { Log.w(TAG, "could not open the library", it) }
    }

    private suspend fun loadShelves() {
        continueListening.value = books.continueListening()
        recentlyAdded.value = books.recentlyAdded()

        val stats = runCatching { books.listeningStats() }.getOrNull()
        val perDay = stats?.perDaySec.orEmpty()
        val iso = java.time.format.DateTimeFormatter.ISO_LOCAL_DATE
        val now = java.time.LocalDate.now()
        val speed = Services.prefs.getDouble("playback_speed", 1.0).coerceAtLeast(0.1)
        val leftContent = continueListening.value.sumOf { b ->
            val p = books.progressFor(b.id)
            val duration = p?.durationSec?.takeIf { it > 0 } ?: (b.durationMs ?: 0L) / 1000.0
            (duration - (p?.currentTimeSec ?: 0.0)).coerceAtLeast(0.0)
        }
        val weekAgoMs = System.currentTimeMillis() - 7L * 24 * 3600 * 1000
        summary.value = LibrarySummary(
            todaySec = perDay[today()] ?: 0.0,
            streakDays = streakFrom(perDay),
            inProgress = continueListening.value.size,
            // The locally-cached count, matching the Profile screen's number
            // (the server total can include non-audiobook items).
            libraryCount = books.countBooks(LibraryFilter.ALL, null),
            loaded = true,
            weekSec = (0L..6L).sumOf { perDay[now.minusDays(it).format(iso)] ?: 0.0 },
            bestStreakDays = longestStreak(perDay),
            leftInProgressSec = leftContent / speed,
            addedThisWeek = recentlyAdded.value.count { (it.addedAt ?: 0L) >= weekAgoMs },
        )
    }

    /** The longest run of consecutive listening days on record. */
    private fun longestStreak(perDay: Map<String, Double>): Int {
        val days = perDay.filterValues { it > 0 }.keys
            .mapNotNull { runCatching { java.time.LocalDate.parse(it) }.getOrNull() }
            .sorted()
        var best = 0; var run = 0; var prev: java.time.LocalDate? = null
        for (d in days) {
            run = if (prev != null && d == prev.plusDays(1)) run + 1 else 1
            best = maxOf(best, run); prev = d
        }
        return best
    }

    /** Titles in A–Z order for the letter rail (whole library, current filter/search). */
    suspend fun sortedTitles(): List<String> =
        query.value.let { books.sortedTitles(it.filter, it.search.takeIf { s -> s.isNotBlank() }) }

    /** Widens the list so row [index] is loaded (a letter-rail jump past the window). */
    fun ensureLoaded(index: Int) {
        val q = query.value
        if (index >= q.limit) query.value = q.copy(limit = index + 60)
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
        openLibrary()
        runCatching { books.fetchPage(page = 1, sort = BookSort.ADDED_DESC, force = force) }
            .onFailure { Log.w(TAG, "recent sync failed", it) }
        runCatching { books.syncProgress() }
            .onFailure { Log.w(TAG, "progress sync failed", it) }
        runCatching { loadShelves() }
            .onFailure { Log.w(TAG, "shelves failed", it) }
    }

    /**
     * Pull-to-refresh: a full sweep, so the local library actually matches the
     * server. syncAll fetches every page (newest included) AND prunes books deleted
     * server-side — the earlier page-1-only sync could add new books but never
     * remove deleted ones, so a book removed on the server lingered in the app no
     * matter how many times you pulled. Only a complete sweep can prune safely (a
     * partial list would look like everything else was deleted), which is why this
     * is heavier than the quiet background sync.
     */
    fun refresh() {
        if (refreshing.value) return
        refreshing.value = true
        viewModelScope.launch {
            openLibrary()
            runCatching { books.syncAll() }.onFailure { Log.w(TAG, "full sync failed", it) }
            // A failed pull used to just stop spinning. Say so — the list below is
            // still the cached library, which works offline.
            if (!books.lastSyncReachedServer) {
                com.bennybar.kitzi.ui.common.Snackbars.show("Couldn't reach the server — showing your offline library")
            }
            runCatching { books.syncProgress() }.onFailure { Log.w(TAG, "progress sync failed", it) }
            runCatching { loadShelves() }.onFailure { Log.w(TAG, "shelves failed", it) }
            refreshing.value = false
            // After the spinner drops: an explicit pull is a fair moment to upgrade
            // any still-soft on-disk covers. Off the refresh flag so it never holds
            // the spinner, and skipped entirely once every cover is already crisp.
            runCatching { books.refreshLowResCovers() }
                .onFailure { Log.w(TAG, "cover refresh failed", it) }
            runCatching { books.ensureDownloadedCovers() }
                .onFailure { Log.w(TAG, "downloaded-cover backfill failed", it) }
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
        // Coming back to the list (from a book, a tab, the player) re-fires this.
        // Each run is 3 requests, two of them full downloads (/api/me and listening
        // stats), so opening and closing ten books cost thirty. Once every few
        // minutes is plenty.
        val now = android.os.SystemClock.elapsedRealtime()
        if (now - lastQuietSyncAt < QUIET_MIN_INTERVAL_MS) return
        lastQuietSyncAt = now
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
        const val QUIET_MIN_INTERVAL_MS = 3 * 60 * 1000L
    }

    fun setSort(sort: BookSort) { query.value = query.value.copy(sort = sort, limit = 60) }
    fun setFilter(filter: LibraryFilter) { query.value = query.value.copy(filter = filter, limit = 60) }
    fun setSearch(text: String) { query.value = query.value.copy(search = text, limit = 60) }
    fun toggleGrid() { grid.value = !grid.value }
}
