package com.bennybar.kitzi.data

import android.content.Context
import android.util.Log
import com.bennybar.kitzi.data.db.AuthorEntity
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.BooksDao
import com.bennybar.kitzi.data.db.KitziDatabase
import com.bennybar.kitzi.data.db.LibraryFilter
import com.bennybar.kitzi.data.db.MediaProgressEntity
import com.bennybar.kitzi.data.legacy.DownloadPaths
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.data.model.BookMapper
import com.bennybar.kitzi.data.model.arr
import com.bennybar.kitzi.data.model.bool
import com.bennybar.kitzi.data.model.int
import com.bennybar.kitzi.data.model.num
import com.bennybar.kitzi.data.model.obj
import com.bennybar.kitzi.data.model.str
import com.bennybar.kitzi.data.model.toBook
import com.bennybar.kitzi.data.model.toEntity
import com.bennybar.kitzi.data.net.AbsApi
import com.bennybar.kitzi.data.net.SessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

data class Library(val id: String, val name: String, val mediaType: String?)

data class Author(val name: String, val bookCount: Int, val imageUrl: String?, val description: String? = null)

/** A series row for the browse list: name, book count, and up to three member cover URLs for the fanned deck. */
@androidx.compose.runtime.Immutable
data class SeriesRow(val name: String, val bookCount: Int, val coverUrls: List<String>)

/** Position is the BOOK position, never the track position. */
data class Bookmark(
    val itemId: String,
    val timeSec: Double,
    val title: String,
    val createdAt: Long,
)

data class ListeningStats(
    val totalSec: Double,
    /** "yyyy-MM-dd" -> seconds listened that day. */
    val perDaySec: Map<String, Double>,
    val itemsFinished: Int,
)

/** A "top" list entry: a label, total listened seconds, and an optional cover. */
data class TopEntry(val label: String, val listenedSec: Double, val coverUrl: String?)

/** One row of "extra information" for a book (label, value, icon key). */
data class MetaFact(val label: String, val value: String, val icon: String)

/** The signed-in user + server summary for the profile screen. */
data class ProfileInfo(
    val username: String?,
    val serverUrl: String?,
    val libraryCount: Int,
    val totalListenedSec: Double,
    val finished: Int,
)

/** Local detailed stats derived from [PlayHistoryStore]. */
data class DetailedStats(
    val topBooks: List<TopEntry>,
    val topAuthors: List<TopEntry>,
    val topNarrators: List<TopEntry>,
    val currentStreakDays: Int,
    val daysListened: Int,
    val totalSec: Double,
)

/**
 * The library: server sync into Room, and every read served from Room.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class BooksRepository(
    private val context: Context,
    private val api: AbsApi,
    private val session: SessionStore,
    private val prefs: FlutterPrefs,
) {
    private val etagPrefs =
        context.getSharedPreferences("kitzi_etags", Context.MODE_PRIVATE)

    /**
     * The library whose database every read and write goes to. Seeded from the
     * stored choice, so the database is usable from any entry point (Android Auto,
     * a media button, a worker) without waiting for ensureLibrary(); before a
     * library is ever chosen it points at the empty default database. Room flows
     * are built on top of it with flatMapLatest, so they follow a library switch
     * instead of staying bound to the closed database.
     */
    private val library = MutableStateFlow(
        prefs.getString(FlutterPrefs.KEY_LIBRARY_ID)?.takeIf { it.isNotBlank() }
            ?: DownloadPaths.DEFAULT_LIBRARY_ID
    )
    val libraryId: String get() = library.value

    private val dao: BooksDao get() = daoFor(libraryId)
    private fun daoFor(id: String): BooksDao = KitziDatabase.forLibrary(context, id).booksDao()

    // ---- library selection -------------------------------------------------

    /** Picks the active library, preferring the stored one (books_repository.dart:100). */
    suspend fun ensureLibrary(): String = withContext(Dispatchers.IO) {
        // The stored library only counts for the server it was chosen on. Logging in
        // to another server used to reuse the old id: every request 404'd and the
        // previous server's cached books stayed on screen. (A choice stored before
        // this was recorded has no server, and is trusted as before.)
        val storedServer = prefs.getString(KEY_LIBRARY_SERVER)
        prefs.getString(FlutterPrefs.KEY_LIBRARY_ID)?.takeIf { it.isNotBlank() }
            ?.takeIf { storedServer == null || storedServer == session.baseUrl }
            ?.let {
                open(it)
                return@withContext it
            }

        val libs = listLibraries()
        check(libs.isNotEmpty()) { "server returned no libraries" }
        // First library that actually holds books; podcast/ebook libraries are not the default.
        val chosen = libs.firstOrNull { it.mediaType?.contains("book", ignoreCase = true) == true }
            ?: libs.first()

        remember(chosen.id)
        open(chosen.id)
        chosen.id
    }

    private fun remember(id: String) {
        prefs.putString(FlutterPrefs.KEY_LIBRARY_ID, id)
        session.baseUrl?.let { prefs.putString(KEY_LIBRARY_SERVER, it) }
    }

    /**
     * On logout: point reads back at the empty default database until the next
     * login's ensureLibrary() reopens the stored library (same server) or picks a
     * new one — so nothing of the previous session shows in between.
     */
    fun closeLibrary() {
        library.value = DownloadPaths.DEFAULT_LIBRARY_ID
    }

    suspend fun listLibraries(): List<Library> = withContext(Dispatchers.IO) {
        api.libraries().mapNotNull { j ->
            val id = j["id"].str() ?: j["_id"].str() ?: return@mapNotNull null
            Library(
                id = id,
                name = j["name"].str() ?: j["title"].str() ?: id,
                mediaType = j["mediaType"].str() ?: j["type"].str(),
            )
        }
    }

    /**
     * Switching library re-points the DB and drops every cached ETag. Without
     * this, one library's conditional requests get answered against another's
     * cache (books_repository.dart:557).
     */
    suspend fun switchLibrary(id: String) = withContext(Dispatchers.IO) {
        remember(id)
        etagPrefs.edit().clear().apply()
        open(id)
    }

    private fun open(id: String) {
        KitziDatabase.forLibrary(context, id)
        library.value = id
    }

    // ---- reads (always from Room) ------------------------------------------

    /**
     * Sort, filter, search and paging happen in SQL. Never re-sort or re-filter
     * the returned list — that is the "app feels broken" bug in REWRITE.md §2.
     */
    fun pagedBooks(
        sort: BookSort,
        filter: LibraryFilter,
        search: String?,
        limit: Int,
        offset: Int,
    ): Flow<List<Book>> {
        val query = BooksDao.libraryQuery(sort, filter, search, limit, offset)
        // Mapped off the main thread: each row costs a file check (its offline cover)
        // and JSON decodes, and this re-runs on every write to books or progress —
        // which a sync does many times. Collected on Main, it stuttered the list.
        return library.flatMapLatest { id ->
            daoFor(id).pagedBooksRaw(query).map { rows ->
                val base = session.baseUrl.orEmpty()
                rows.map { it.toBook(base) }
            }
        }.flowOn(Dispatchers.Default)
    }

    suspend fun countBooks(filter: LibraryFilter, search: String?): Int = withContext(Dispatchers.IO) {
        dao.countBooksRaw(BooksDao.libraryQuery(BookSort.NAME_ASC, filter, search, 0, 0, countOnly = true))
    }

    suspend fun getBook(id: String): Book? = withContext(Dispatchers.IO) {
        dao.getBook(id)?.toBook(session.baseUrl.orEmpty())
    }

    /** One query for many books — the Downloads list would otherwise do N of them. */
    suspend fun getBooks(ids: Collection<String>): List<Book> = withContext(Dispatchers.IO) {
        if (ids.isEmpty()) return@withContext emptyList()
        dao.getBooks(ids.toList()).map { it.toBook(session.baseUrl.orEmpty()) }
    }

    suspend fun booksInSeries(series: String): List<Book> = withContext(Dispatchers.IO) {
        dao.booksInSeries(series).map { it.toBook(session.baseUrl.orEmpty()) }
    }

    suspend fun booksByAuthor(author: String): List<Book> = withContext(Dispatchers.IO) {
        dao.booksByAuthor(author).map { it.toBook(session.baseUrl.orEmpty()) }
    }

    suspend fun authors(): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        dao.authorsWithCounts().map { it.name to it.bookCount }
    }

    /**
     * Authors with their portraits.
     *
     * The author list itself is derived from the books table (ABS has no "list my
     * authors" endpoint), but the portrait needs the author's id, which only the
     * library's author endpoint knows. Those ids are cached in the authors table.
     */
    suspend fun authorsWithImages(): List<Author> = withContext(Dispatchers.IO) {
        runCatching { syncAuthorMetadata() }

        val rows = dao.allAuthors()
        val ids = rows.associate { it.name to it.id }
        val descriptions = rows.associate { it.name to it.description }
        val base = session.baseUrl.orEmpty()

        dao.authorsWithCounts().map { (name, count) ->
            val id = ids[name]
            Author(
                name = name,
                bookCount = count,
                imageUrl = id?.let {
                    "$base/api/authors/$it/image"
                },
                description = descriptions[name],
            )
        }
    }

    /** Refreshed at most daily; the portraits rarely change. Keyed per library so
     *  switching libraries doesn't suppress the new one's author fetch. */
    private suspend fun syncAuthorMetadata() {
        val key = "${KEY_AUTHORS_SYNCED}_$libraryId"
        val last = prefs.getDouble(key, 0.0).toLong()
        if (System.currentTimeMillis() - last < 24 * 3600 * 1000L) return

        val fetched = runCatching { api.authors(libraryId) }.getOrNull() ?: return
        val rows = fetched.mapNotNull { j ->
            val name = j["name"].str() ?: return@mapNotNull null
            AuthorEntity(
                name = name,
                id = j["id"].str() ?: j["_id"].str(),
                description = j["description"].str() ?: j["desc"].str(),
                updatedAt = j["updatedAt"].num()?.toLong(),
                lastSyncedAt = System.currentTimeMillis(),
            )
        }
        if (rows.isNotEmpty()) {
            dao.upsertAuthors(rows)
            prefs.putDouble(key, System.currentTimeMillis().toDouble())
        }
    }

    /** `minBooks` = 1 shows every series (the ui_series_min_books setting). */
    suspend fun series(minBooks: Int = 1): List<Pair<String, Int>> = withContext(Dispatchers.IO) {
        dao.seriesWithCounts(minBooks).map { it.name to it.bookCount }
    }

    /**
     * Series with up to three member cover URLs each, for the fanned-deck cards.
     * One covers query, grouped in memory — no per-series book load, so the list
     * paints immediately.
     */
    suspend fun seriesWithCovers(minBooks: Int = 1): List<SeriesRow> = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        val counts = dao.seriesWithCounts(minBooks)
        val kept = counts.map { it.name }.toSet()
        val covers = LinkedHashMap<String, MutableList<String>>()
        for (row in dao.seriesCovers()) {
            if (row.series !in kept) continue
            val list = covers.getOrPut(row.series) { mutableListOf() }
            if (list.size >= 3) continue
            list += row.coverPath?.takeIf { java.io.File(it).exists() }?.let { "file://$it" }
                ?: BookMapper.coverUrl(row.id, base)
        }
        counts.map { SeriesRow(it.name, it.bookCount, covers[it.name].orEmpty()) }
    }

    /**
     * Collections have no server endpoint — they are a client-side grouping over
     * the `collection` field parsed out of each book's metadata.
     */
    suspend fun collections(): Map<String, List<Book>> = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        dao.booksInAnyCollection()
            .map { it.toBook(base) }
            .groupBy { it.collection!! }
            .mapValues { (_, books) ->
                // Explicit sequence first, then title — same rule as series.
                books.sortedWith(
                    compareBy(nullsLast()) { it.collectionSequence }
                ).sortedWith(
                    compareBy<Book> { it.collectionSequence ?: Double.MAX_VALUE }.thenBy { it.title.lowercase() }
                )
            }
            .toSortedMap()
    }

    suspend fun continueListening(limit: Int = 20): List<Book> = withContext(Dispatchers.IO) {
        dao.continueListening(limit).map { it.toBook(session.baseUrl.orEmpty()) }
    }

    suspend fun recentlyAdded(limit: Int = 20): List<Book> = withContext(Dispatchers.IO) {
        dao.recentlyAdded(limit).map { it.toBook(session.baseUrl.orEmpty()) }
    }

    /** Bookmarks live on `/api/me`; there is no per-item endpoint. */
    suspend fun bookmarks(itemId: String): List<Bookmark> = withContext(Dispatchers.IO) {
        val me = runCatching { api.me() }.getOrNull() ?: return@withContext emptyList()
        (me["bookmarks"] as? JsonArray).orEmpty().mapNotNull { el ->
            val b = el.obj() ?: return@mapNotNull null
            if (b["libraryItemId"].str() != itemId) return@mapNotNull null
            Bookmark(
                itemId = itemId,
                timeSec = b["time"].num() ?: return@mapNotNull null,
                title = b["title"].str() ?: "Bookmark",
                createdAt = b["createdAt"].num()?.toLong() ?: 0L,
            )
        }.sortedBy { it.timeSec }
    }

    /** `GET /api/me/listening-stats` — total seconds listened, and per-day totals. */
    suspend fun listeningStats(): ListeningStats? = withContext(Dispatchers.IO) {
        val json = runCatching { api.listeningStats() }.getOrNull() ?: return@withContext null
        val perDay = (json["days"] as? JsonObject)?.mapValues { (_, v) -> v.num() ?: 0.0 }.orEmpty()
        ListeningStats(
            totalSec = json["totalTime"].num() ?: 0.0,
            perDaySec = perDay,
            itemsFinished = (json["items"] as? JsonObject)?.size ?: 0,
        )
    }

    /**
     * Aggregates the local play-history into top books / authors / narrators and a
     * listening streak. Books are resolved from the library table at read time.
     */
    suspend fun detailedStats(): DetailedStats = withContext(Dispatchers.IO) {
        val sessions = PlayHistoryStore.sessions()
        val base = session.baseUrl.orEmpty()
        val books = sessions.map { it.itemId }.toSet()
            .associateWith { dao.getBook(it)?.toBook(base) }

        val bookTotals = LinkedHashMap<String, Double>()
        val authorTotals = HashMap<String, Double>()
        val narratorTotals = HashMap<String, Double>()
        var total = 0.0
        sessions.forEach { s ->
            total += s.listenedSec
            bookTotals.merge(s.itemId, s.listenedSec, Double::plus)
            val b = books[s.itemId] ?: return@forEach
            b.author?.let { authorTotals.merge(it, s.listenedSec, Double::plus) }
            b.narrators.firstOrNull()?.let { narratorTotals.merge(it, s.listenedSec, Double::plus) }
        }

        val topBooks = bookTotals.entries.sortedByDescending { it.value }.take(5)
            .mapNotNull { (id, sec) -> books[id]?.let { TopEntry(it.title, sec, it.coverUrl) } }
        val topAuthors = authorTotals.entries.sortedByDescending { it.value }.take(5)
            .map { TopEntry(it.key, it.value, null) }
        val topNarrators = narratorTotals.entries.sortedByDescending { it.value }.take(5)
            .map { TopEntry(it.key, it.value, null) }

        val days = sessions.map {
            java.time.Instant.ofEpochMilli(it.atMs).atZone(java.time.ZoneId.systemDefault()).toLocalDate()
        }.toSet()
        var streak = 0
        var d = java.time.LocalDate.now()
        if (d !in days) d = d.minusDays(1) // grace: an unfinished today doesn't break yesterday's streak
        while (d in days) { streak++; d = d.minusDays(1) }

        DetailedStats(topBooks, topAuthors, topNarrators, streak, days.size, total)
    }

    /**
     * The full "extra information" fact list for a book, matching the Flutter
     * metadata sheet. Pulls the live item (for language / ISBN / distribution /
     * file type + bitrate) and combines it with the cached book fields.
     */
    suspend fun metadataFacts(book: Book): List<MetaFact> = withContext(Dispatchers.IO) {
        val item = runCatching { api.item(book.id) }.getOrNull()
        val media = item?.get("media").obj()
        val meta = media?.get("metadata").obj()
        val audioFiles = media?.get("audioFiles").arr()

        val facts = mutableListOf<MetaFact>()
        fun add(label: String, value: String?, icon: String) {
            value?.trim()?.takeIf { it.isNotEmpty() }?.let { facts += MetaFact(label, it, icon) }
        }
        fun hm(sec: Long): String {
            val h = sec / 3600; val m = (sec % 3600) / 60
            return if (h > 0) "${h}h ${m}m" else "${m}m"
        }
        fun sizeStr(b: Long): String {
            val mb = b / 1024.0 / 1024.0
            return if (mb >= 1024) String.format(java.util.Locale.US, "%.2f GB", mb / 1024)
            else String.format(java.util.Locale.US, "%.1f MB", mb)
        }

        add("Author", book.author, "user")
        add("Narrator", book.narrators.joinToString(", ").ifBlank { null }, "mic")
        add("Released year", book.publishYear?.toString() ?: meta?.get("publishedYear").str(), "calendar")
        add("Publisher", book.publisher, "building")
        add("Distribution", meta?.get("distribution").str() ?: meta?.get("distributor").str(), "truck")
        add("Genres", book.genres.joinToString(" / ").ifBlank { null }, "tags")
        add("Series", book.series, "library")
        add("Collection", book.collection, "folder")
        add("Media", if (book.isAudioBook) "Audiobook" else (book.mediaKind ?: "Book"), "book")
        add("Length", book.durationMs?.let { hm(it / 1000) }, "clock")
        add("Size", (book.sizeBytes ?: item?.get("size").num()?.toLong())?.let { sizeStr(it) }, "archive")
        val exts = audioFiles?.mapNotNull { it.obj()?.get("metadata").obj()?.get("ext").str()?.trimStart('.') }
            ?.distinct().orEmpty()
        add("File type", exts.joinToString(", ").uppercase().ifBlank { null }, "audio")
        val bitrates = audioFiles?.mapNotNull { it.obj()?.get("bitRate").num()?.toLong() }.orEmpty()
        add("Bitrate", bitrates.maxOrNull()?.let { "${it / 1000} kbps" }, "activity")
        add("Language", meta?.get("language").str(), "language")
        add("ISBN", meta?.get("isbn").str() ?: meta?.get("isbn13").str() ?: meta?.get("asin").str(), "pin")
        facts
    }

    /** The book's chapter list from the server item metadata (empty offline / none). */
    suspend fun chapters(itemId: String): List<com.bennybar.kitzi.playback.Chapter> = withContext(Dispatchers.IO) {
        val item = runCatching { api.item(itemId) }.getOrNull() ?: return@withContext emptyList()
        (item["media"].obj()?.get("chapters") as? kotlinx.serialization.json.JsonArray)
            ?.mapNotNull { el ->
                val c = el.obj() ?: return@mapNotNull null
                val start = c["start"].num() ?: return@mapNotNull null
                com.bennybar.kitzi.playback.Chapter(c["title"].str().orEmpty(), start)
            }
            .orEmpty()
    }

    suspend fun profile(): ProfileInfo = withContext(Dispatchers.IO) {
        val me = runCatching { api.me() }.getOrNull()
        val stats = runCatching { api.listeningStats() }.getOrNull()
        ProfileInfo(
            username = me?.get("username").str(),
            serverUrl = session.baseUrl,
            // The same count the home screen shows: local audiobooks, one query.
            libraryCount = countBooks(LibraryFilter.ALL, null),
            totalListenedSec = stats?.get("totalTime").num() ?: 0.0,
            finished = (stats?.get("items") as? JsonObject)?.size ?: 0,
        )
    }

    suspend fun isEmpty(): Boolean = withContext(Dispatchers.IO) { dao.count() == 0 }

    // ---- server sync -------------------------------------------------------

    /**
     * Pulls a page into Room.
     *
     * [force] means user-initiated (pull-to-refresh): it sends NO If-None-Match
     * at all, and refetches unconditionally if a 304 somehow comes back anyway.
     * The bug this guards is real and was shipped once: a conditional request
     * answered 304 was served from the local DB, so newly added books never
     * appeared no matter how many times the user pulled.
     */
    suspend fun fetchPage(
        page: Int,
        limit: Int = 50,
        sort: BookSort = BookSort.UPDATED_DESC,
        force: Boolean = false,
    ): Int = withContext(Dispatchers.IO) {
        val (sortField, desc) = serverSort(sort)
        // The ETag is per (library, sort, page) — sharing one key across pages lets a
        // page-2 ETag be replayed onto a page-1 request and yield a bogus 304.
        // v2: page numbering was off by one before, so ETags cached under the old key
        // describe a different page's contents — replaying them would 304 away the
        // newest items this fix exists to fetch.
        // One library for the whole call: a switch mid-request must not write this
        // library's page into the other one's database.
        val lib = libraryId
        val libDao = daoFor(lib)
        val etagKey = "etag2_${lib}_${sortField}_${desc}_$page"
        val etag = if (force) null else etagPrefs.getString(etagKey, null)

        var result = api.libraryItems(lib, page, limit, sortField, desc, etag)

        if (result.notModified) {
            val cached = libDao.countBooksRaw(
                BooksDao.libraryQuery(sort, LibraryFilter.ALL, null, 0, 0, countOnly = true)
            )
            // A 304 is only trustworthy if we actually have the rows it refers to.
            if (cached > 0) return@withContext 0
            result = api.libraryItems(lib, page, limit, sortField, desc, etag = null)
        }

        if (libraryId != lib) return@withContext 0
        result.etag?.let { etagPrefs.edit().putString(etagKey, it).apply() }
        upsert(result.items, libDao)
    }

    /** User-initiated refresh. Always unconditional. */
    suspend fun refresh(sort: BookSort = BookSort.UPDATED_DESC): Int =
        fetchPage(page = 1, limit = 50, sort = sort, force = true)

    /**
     * Pulls the whole library into Room, a page at a time.
     *
     * The cache has to hold everything, not just the first page: sort, filter and
     * search all run as SQL over the cache, so a partially-cached library would
     * sort and filter only the part that happened to be loaded — the exact bug
     * REWRITE.md warns about. It also means the library works offline.
     *
     * pageSize is 50 because the ABS items endpoint caps a page at 50 regardless of
     * the requested `limit`. Asking for 100 returned only 50 rows while the offset
     * still advanced by 100 — so half of every 100 items (items 50–99, 150–199, …)
     * were skipped and never cached. This is the "not all books show" bug the
     * Flutter app fixed the same way.
     */
    /**
     * The launch-time sweep, at most once per [maxAgeMs] per library. A full sweep
     * re-downloads every page (8 requests for 350 books) and nearly always finds
     * nothing new; the quick page-1 sync on launch already picks up new and edited
     * books. Pull-to-refresh and "Clear deleted" still sweep every time.
     */
    suspend fun syncAllIfStale(maxAgeMs: Long = AUTO_SWEEP_MAX_AGE_MS): Int {
        val last = prefs.getDouble(sweptKey(libraryId), 0.0).toLong()
        if (System.currentTimeMillis() - last < maxAgeMs) return 0
        return syncAll()
    }

    private fun sweptKey(lib: String) = "kitzi_last_full_sweep_$lib"

    suspend fun syncAll(pageSize: Int = 50): Int = withContext(Dispatchers.IO) {
        var page = 1
        var total = 0
        val seen = HashSet<String>()
        var fullSweep = false
        // How many items the server says the library holds (first page's `total`).
        var serverTotal: Int? = null
        // Pinned for the whole sweep; a library switch part-way aborts it (below)
        // rather than mixing two libraries and pruning one against the other.
        val lib = libraryId
        val libDao = daoFor(lib)

        // Which paging parameter this server actually honours. We start with `page`
        // and, the first time a page>1 comes back as only already-seen items (the
        // server ignored `page`), switch to `offset` and then `skip` — the same
        // three-way fallback the Flutter app used. Once one works we stick with it.
        var paging = AbsApi.Paging.PAGE
        // Swept by date added, not date updated: an item edited on the server
        // mid-sweep would jump to the front of an updatedAt ordering, shift every
        // later item down a slot, and one would cross a page boundary unseen — and
        // then be pruned as "deleted".
        val (sortField, desc) = serverSort(BookSort.ADDED_DESC)

        fun fetch(p: Int, mode: AbsApi.Paging) = runCatching {
            api.libraryItems(lib, p, pageSize, sortField, desc, etag = null, paging = mode)
        }.getOrNull()

        while (page <= MAX_SYNC_PAGES) {
            if (libraryId != lib) break
            var result = fetch(page, paging) ?: break
            if (page == 1) serverTotal = result.total
            if (result.items.isEmpty()) { fullSweep = page > 1; break }

            fun freshCount(r: AbsApi.Page) = r.items.count { it["id"].str()?.let { id -> id !in seen } ?: false }
            var fresh = freshCount(result)

            // Server ignored `page` (a page>1 of only-seen items): try offset, then
            // skip, and adopt whichever actually advances.
            if (fresh == 0 && page > 1) {
                for (alt in listOf(AbsApi.Paging.OFFSET, AbsApi.Paging.SKIP)) {
                    val altResult = fetch(page, alt) ?: continue
                    if (freshCount(altResult) > 0) {
                        result = altResult; fresh = freshCount(altResult); paging = alt
                        break
                    }
                }
            }

            // Commit: record ids as seen, then upsert.
            result.items.forEach { it["id"].str()?.let(seen::add) }
            total += upsert(result.items, libDao)
            if (fresh == 0) break

            if (result.items.size < pageSize) { fullSweep = true; break }
            page++
        }

        // Only a complete, uninterrupted sweep makes `seen` an authoritative list of
        // what still exists on the server — so only then may we prune. A network
        // failure mid-sweep must never delete books. Neither may a first page that
        // came back empty: a Cloudflare Access login page or a captive portal answers
        // 200 with no items, which is not the server saying the library is empty.
        // When the server reports its total, the sweep must have seen all of it.
        val complete = fullSweep && seen.isNotEmpty() &&
            (serverTotal == null || seen.size >= serverTotal!!) && libraryId == lib
        if (complete) {
            pruneDeletedBooks(seen, libDao)
            prefs.putDouble(sweptKey(lib), System.currentTimeMillis().toDouble())
        }
        else if (fullSweep) Log.w(TAG, "syncAll: saw ${seen.size} of $serverTotal items; not pruning")

        Log.i(TAG, "syncAll: cached $total new books over $page page(s)")
        total
    }

    /**
     * Covers saved to disk (shown offline via file://) were stored at 400px, so the
     * width bump on the network URL never reached them and a downloaded book kept its
     * soft cover. Re-fetch any below the crisp threshold at player width.
     *
     * The hi-res copy is written to a NEW filename and the row's coverPath repointed
     * at it, not overwritten in place: Coil keys its MEMORY cache by the file path
     * string alone, so an in-place overwrite would keep showing the stale bitmap
     * until the process restarted — exactly the "pulled to refresh, cover didn't
     * change" report. A new path is a new key, and the Room write re-emits the list
     * so the grid repaints. Best-effort and idempotent: a crisp file is skipped, a
     * failed fetch leaves the old file to retry, and the old file is deleted last.
     */
    /**
     * Saves a book's cover to disk at player resolution so a downloaded book shows a
     * crisp cover with no network — the cover URL needs a token and points at the
     * server, so an offline downloaded book had no cover at all. Called when a
     * download completes; the file lives in the download's own directory so it is
     * removed with the download. Idempotent (a crisp file already there is kept) and
     * best-effort (offline it simply retries on the next completed download).
     */
    suspend fun cacheCoverForOffline(itemId: String, intoDir: java.io.File) = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        if (base.isEmpty()) return@withContext
        val file = java.io.File(intoDir, "cover.jpg")
        if (file.isFile) {
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeFile(file.path, bounds)
            if (bounds.outWidth >= CRISP_COVER_MIN_PX) { dao.setCoverPath(itemId, file.path); return@withContext }
        }
        runCatching {
            val url = BookMapper.coverUrl(itemId, base, width = CRISP_COVER_PX)
            val request = okhttp3.Request.Builder().url(url).build()
            Services.httpClient.newCall(request).execute().use { resp ->
                val bytes = resp.body?.bytes()?.takeIf { resp.isSuccessful && it.isNotEmpty() } ?: return@use
                intoDir.mkdirs()
                val tmp = java.io.File(intoDir, "cover.jpg.tmp")
                tmp.writeBytes(bytes)
                if (tmp.renameTo(file)) dao.setCoverPath(itemId, file.path) else tmp.delete()
            }
        }.onFailure { Log.w(TAG, "offline cover save failed for $itemId", it) }
    }

    /**
     * Backfills offline covers for books downloaded before this existed (their
     * cover was only ever the network URL). cacheCoverForOffline is idempotent, so
     * this is a cheap header-check for books already covered and a one-time fetch
     * for the rest. Runs alongside the low-res refresh on library sync.
     */
    suspend fun ensureDownloadedCovers() = withContext(Dispatchers.IO) {
        if (session.baseUrl.isNullOrEmpty()) return@withContext
        val ids = runCatching { Services.downloads.downloadedItemIds() }.getOrDefault(emptyList())
        for (id in ids) cacheCoverForOffline(id, Services.downloadPaths.itemDir(id, libraryId))
    }

    suspend fun refreshLowResCovers() = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        if (base.isEmpty()) return@withContext
        val rows = dao.coversOnDisk()
        Log.i(TAG, "cover refresh: ${rows.size} on-disk covers to check")
        var upgraded = 0
        for (row in rows) {
            val old = java.io.File(row.coverPath)
            if (!old.isFile) continue
            val bounds = android.graphics.BitmapFactory.Options().apply { inJustDecodeBounds = true }
            android.graphics.BitmapFactory.decodeFile(row.coverPath, bounds)
            if (bounds.outWidth >= CRISP_COVER_MIN_PX) continue
            runCatching {
                val url = BookMapper.coverUrl(row.id, base, width = CRISP_COVER_PX)
                val request = okhttp3.Request.Builder().url(url).build()
                Services.httpClient.newCall(request).execute().use { resp ->
                    val bytes = resp.body?.bytes()?.takeIf { resp.isSuccessful && it.isNotEmpty() }
                        ?: run { Log.w(TAG, "cover refresh ${row.id}: HTTP ${resp.code}"); return@use }
                    // Version the filename so the file:// URL — and thus Coil's cache
                    // key — changes. `{name}.jpg` -> `{name}.hd.jpg`.
                    val dot = row.coverPath.lastIndexOf('.').takeIf { it > row.coverPath.lastIndexOf('/') }
                    val newPath = if (dot != null) {
                        row.coverPath.substring(0, dot) + ".hd" + row.coverPath.substring(dot)
                    } else row.coverPath + ".hd"
                    val target = java.io.File(newPath)
                    val tmp = java.io.File("$newPath.tmp")
                    tmp.writeBytes(bytes)
                    if (tmp.renameTo(target)) {
                        dao.setCoverPath(row.id, newPath)
                        if (old.path != target.path) old.delete()
                        upgraded++
                    } else tmp.delete()
                }
            }.onFailure { Log.w(TAG, "cover refresh failed for ${row.id}", it) }
        }
        Log.i(TAG, "cover refresh: upgraded $upgraded covers")
    }

    /**
     * Removes local books the server no longer lists — but keeps anything the user
     * has downloaded, so a book deleted server-side stays playable offline until
     * they remove the download themselves.
     */
    private suspend fun pruneDeletedBooks(serverIds: Set<String>, libDao: BooksDao) {
        val downloaded = runCatching { Services.downloads.downloadedItemIds() }
            .getOrDefault(emptyList()).toSet()
        val stale = libDao.allBookIds().filter { it !in serverIds && it !in downloaded }
        stale.forEach { libDao.deleteBook(it); libDao.deleteProgress(it) }
        if (stale.isNotEmpty()) Log.i(TAG, "pruneDeletedBooks: removed ${stale.size} book(s) gone from server")
    }

    /**
     * "Clear deleted and broken items": a full reconciliation against the server —
     * a complete library sweep (which prunes books deleted server-side) plus a
     * progress refresh (which prunes reset/removed progress). This is what the
     * settings action always claimed to do; it previously only refreshed page 1.
     */
    suspend fun reconcile(): Int = withContext(Dispatchers.IO) {
        val cached = syncAll()
        runCatching { syncProgress() }
        cached
    }

    private suspend fun upsert(items: List<JsonObject>, libDao: BooksDao = dao): Int {
        val base = session.baseUrl.orEmpty()
        val books = items
            .mapNotNull { BookMapper.fromLibraryItem(it, base) }
            // Ebooks and podcasts never enter the library cache.
            .filter { it.isAudioBook }

        if (books.isEmpty()) return 0

        // One query for the page's existing rows, instead of one per book plus a scan
        // of the whole covers table on every page.
        val existing = libDao.getBooks(books.map { it.id }).associateBy { it.id }
        val changed = books.mapNotNull { book ->
            val old = existing[book.id]
            // Don't overwrite a newer local row with a staler server one.
            if (old?.updatedAt != null && book.updatedAt != null && book.updatedAt < old.updatedAt) {
                return@mapNotNull null
            }
            // coverPath is a LOCAL-only field (a downloaded/cached cover on disk); the
            // server never supplies it, so it's carried across — otherwise every sync
            // wiped the offline cover pointer.
            book.toEntity(coverPath = old?.coverPath)
                // Only rows that actually differ are written. Rewriting every row made
                // each sync page re-run and re-map every open list. A mapper fix still
                // reaches old rows: the re-mapped entity differs, so it's written.
                .takeIf { it != old }
        }
        if (changed.isNotEmpty()) libDao.upsertBooks(changed)
        return changed.size
    }

    suspend fun searchServer(query: String): List<Book> = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        val items = api.search(libraryId, query)
        // Through upsert, which keeps a downloaded book's offline cover path.
        upsert(items)
        items.mapNotNull { BookMapper.fromLibraryItem(it, base) }.filter { it.isAudioBook }
    }

    /**
     * Progress for every book, from a single `GET /api/me`. Stored so the library
     * filters can run in SQL instead of being applied to a loaded page.
     */
    suspend fun syncProgress(): Int = withContext(Dispatchers.IO) {
        val me = runCatching { api.me() }.getOrNull() ?: return@withContext 0
        val entries = (me["mediaProgress"] as? JsonArray).orEmpty().mapNotNull { el ->
            el.obj()?.let(::progressEntity)
        }
        // Only rows that changed: rewriting all of them on every refresh re-ran every
        // list observing progress (the whole library list among them).
        if (entries.isNotEmpty()) {
            val current = dao.allProgress().associateBy { it.itemId }
            entries.filter { it != current[it.itemId] }.takeIf { it.isNotEmpty() }?.let { dao.upsertProgress(it) }
        }

        // Progress the server no longer reports (reset on another device, or the
        // book removed) should not linger locally. Room progress rows are only ever
        // written from the server or Mark-Finished — never from offline listening
        // (that lives in prefs and wins on resume by timestamp) — so pruning here
        // can't lose un-pushed offline progress. Downloaded books are preserved so
        // their shown progress doesn't vanish mid-offline-listen. Guard on a
        // non-empty response so a transient empty /api/me can't wipe everything.
        val serverIds = entries.map { it.itemId }.toSet()
        if (serverIds.isNotEmpty()) {
            val downloaded = runCatching { Services.downloads.downloadedItemIds() }
                .getOrDefault(emptyList()).toSet()
            dao.allProgressIds()
                .filter { it !in serverIds && it !in downloaded }
                .forEach { dao.deleteProgress(it) }
        }
        entries.size
    }

    /** A server mediaProgress object as a row; null without an item id. */
    private fun progressEntity(m: JsonObject): MediaProgressEntity? {
        val itemId = m["libraryItemId"].str() ?: m["id"].str() ?: return null

        val duration = m["duration"].num() ?: 0.0
        val currentTime = m["currentTime"].num() ?: 0.0
        val finished = m["isFinished"].bool() == true
        // DERIVE progress from position/duration — the server's own `progress`
        // field is unreliable: ABS can report it as 0 while currentTime is set,
        // OR leave it stuck at 1.0 (a book "100% complete" 23 minutes in) after
        // an old finish. Position over duration is authoritative; only fall back
        // to the reported figure when the duration is unknown.
        val reported = m["progress"].num() ?: 0.0
        val progress = when {
            finished -> 1.0
            duration > 0 -> currentTime / duration
            else -> reported
        }.coerceIn(0.0, 1.0).let { if (it.isNaN()) 0.0 else it }

        return MediaProgressEntity(
            itemId = itemId,
            progress = progress,
            isFinished = finished,
            currentTimeSec = currentTime,
            durationSec = duration,
            lastUpdate = m["lastUpdate"].num()?.toLong() ?: System.currentTimeMillis(),
        )
    }

    /**
     * One book's progress, for the sync before playing it — a single small request
     * instead of the whole /api/me (every book's progress plus all bookmarks).
     */
    suspend fun syncProgressFor(itemId: String) = withContext(Dispatchers.IO) {
        val m = api.mediaProgress(itemId) ?: return@withContext
        progressEntity(m)?.let { row ->
            if (row != dao.progressFor(row.itemId)) dao.upsertProgress(listOf(row))
        }
    }

    suspend fun progressFor(id: String): MediaProgressEntity? = withContext(Dispatchers.IO) {
        dao.progressFor(id)
    }

    /**
     * "Mark as Finished": tells the server, then writes the finished state to the
     * local progress table so the UI updates at once — without this the network
     * call ran on the caller's dispatcher and nothing local changed, so the book
     * still showed as in-progress until the next full resync.
     */
    suspend fun markFinished(id: String): Boolean = setFinished(id, true)

    /** The undo for [markFinished] — the only way back once a book is marked. */
    suspend fun markUnfinished(id: String): Boolean = setFinished(id, false)

    private suspend fun setFinished(id: String, finished: Boolean): Boolean {
        // Stop the book first if it's the one playing. The player reports its own
        // position every ~26s and on pause, and that report carries isFinished=false
        // — so marking the CURRENT book finished used to be silently undone by its
        // own playback a few seconds later.
        //
        // Deliberately OUTSIDE the IO context below: ExoPlayer must be touched from
        // the thread it was built on, and stopAndAwait ends in player.stop(). Called
        // on a Dispatchers.IO coroutine it throws, and the book just kept playing.
        if (Services.playback.nowPlaying.value?.itemId == id) {
            runCatching { Services.playback.stopAndAwait() }
        }
        return withContext(Dispatchers.IO) { writeFinished(id, finished) }
    }

    private suspend fun writeFinished(id: String, finished: Boolean): Boolean {
        // The book's duration, needed so "finished" is reported as a position at the
        // end rather than at zero. The progress row may not carry it yet (a book
        // never opened), so fall back to the library metadata.
        val existing = dao.progressFor(id)
        val duration = existing?.durationSec?.takeIf { it > 0 }
            ?: dao.getBook(id)?.durationMs?.let { it / 1000.0 }
            ?: 0.0

        // The server is the source of truth here. Writing the local row regardless
        // of the result made a failed call look like it had worked, until the next
        // full resync quietly reverted it.
        if (!Services.playbackApi.setFinished(id, finished, duration.takeIf { it > 0 })) return false
        dao.upsertProgress(
            listOf(
                MediaProgressEntity(
                    itemId = id,
                    progress = if (finished) 1.0 else 0.0,
                    isFinished = finished,
                    currentTimeSec = when {
                        !finished -> 0.0
                        duration > 0 -> duration
                        else -> existing?.currentTimeSec ?: 0.0
                    },
                    durationSec = duration,
                    lastUpdate = System.currentTimeMillis(),
                )
            )
        )
        return true
    }

    /** Progress for every book, so a list row can show its finished/in-progress mark. */
    fun watchProgress(): Flow<Map<String, MediaProgressEntity>> = library.flatMapLatest { id ->
        daoFor(id).watchAllProgress().map { rows -> rows.associateBy { it.itemId } }
    }.flowOn(Dispatchers.Default)

    /**
     * Drops every progress row, on logout: the next user (or the same one) gets
     * theirs back from the server on the first sync, instead of seeing the previous
     * account's finished marks and Continue Listening.
     */
    suspend fun clearProgress() = withContext(Dispatchers.IO) { dao.clearProgress() }

    private fun serverSort(sort: BookSort): Pair<String, Boolean> = when (sort) {
        BookSort.NAME_ASC -> "media.metadata.title" to false
        BookSort.ADDED_DESC -> "addedAt" to true
        BookSort.UPDATED_DESC -> "updatedAt" to true
    }

    private companion object {
        const val TAG = "BooksRepository"
        /** A backstop against a server that pages forever. 100 * 200 = 20k books. */
        const val MAX_SYNC_PAGES = 200
        const val KEY_AUTHORS_SYNCED = "authors_last_synced"
        /** The automatic (launch) full sweep runs at most this often. */
        const val AUTO_SWEEP_MAX_AGE_MS = 12 * 3600 * 1000L
        /** The server [FlutterPrefs.KEY_LIBRARY_ID] was chosen on. */
        const val KEY_LIBRARY_SERVER = "kitzi_library_server"
        /** Below this stored width, an on-disk cover counts as low-res and is re-fetched. */
        const val CRISP_COVER_MIN_PX = 700
        /** The width re-fetched covers are stored at — sized for the full-screen player. */
        const val CRISP_COVER_PX = 1200
    }
}
