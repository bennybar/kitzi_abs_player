package com.bennybar.kitzi.data

import android.content.Context
import android.util.Log
import com.bennybar.kitzi.data.db.AuthorEntity
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.BooksDao
import com.bennybar.kitzi.data.db.KitziDatabase
import com.bennybar.kitzi.data.db.LibraryFilter
import com.bennybar.kitzi.data.db.MediaProgressEntity
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
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject

data class Library(val id: String, val name: String, val mediaType: String?)

data class Author(val name: String, val bookCount: Int, val imageUrl: String?, val description: String? = null)

/** A series row for the browse list: name, book count, and up to three member cover URLs for the fanned deck. */
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
class BooksRepository(
    private val context: Context,
    private val api: AbsApi,
    private val session: SessionStore,
    private val prefs: FlutterPrefs,
) {
    private val etagPrefs =
        context.getSharedPreferences("kitzi_etags", Context.MODE_PRIVATE)

    private lateinit var db: KitziDatabase
    private val dao: BooksDao get() = db.booksDao()

    var libraryId: String = ""
        private set

    // ---- library selection -------------------------------------------------

    /** Picks the active library, preferring the stored one (books_repository.dart:100). */
    suspend fun ensureLibrary(): String = withContext(Dispatchers.IO) {
        prefs.getString(FlutterPrefs.KEY_LIBRARY_ID)?.takeIf { it.isNotBlank() }?.let {
            open(it)
            return@withContext it
        }

        val libs = listLibraries()
        check(libs.isNotEmpty()) { "server returned no libraries" }
        // First library that actually holds books; podcast/ebook libraries are not the default.
        val chosen = libs.firstOrNull { it.mediaType?.contains("book", ignoreCase = true) == true }
            ?: libs.first()

        prefs.putString(FlutterPrefs.KEY_LIBRARY_ID, chosen.id)
        open(chosen.id)
        chosen.id
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
        prefs.putString(FlutterPrefs.KEY_LIBRARY_ID, id)
        etagPrefs.edit().clear().apply()
        open(id)
    }

    private fun open(id: String) {
        libraryId = id
        db = KitziDatabase.forLibrary(context, id)
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
        val base = session.baseUrl.orEmpty()
        val token = session.accessToken
        return dao.pagedBooksRaw(query).map { rows -> rows.map { it.toBook(base, token) } }
    }

    suspend fun countBooks(filter: LibraryFilter, search: String?): Int = withContext(Dispatchers.IO) {
        dao.countBooksRaw(BooksDao.libraryQuery(BookSort.NAME_ASC, filter, search, 0, 0, countOnly = true))
    }

    suspend fun getBook(id: String): Book? = withContext(Dispatchers.IO) {
        dao.getBook(id)?.toBook(session.baseUrl.orEmpty(), session.accessToken)
    }

    suspend fun booksInSeries(series: String): List<Book> = withContext(Dispatchers.IO) {
        dao.booksInSeries(series).map { it.toBook(session.baseUrl.orEmpty(), session.accessToken) }
    }

    suspend fun booksByAuthor(author: String): List<Book> = withContext(Dispatchers.IO) {
        dao.booksByAuthor(author).map { it.toBook(session.baseUrl.orEmpty(), session.accessToken) }
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
        val token = session.accessToken

        dao.authorsWithCounts().map { (name, count) ->
            val id = ids[name]
            Author(
                name = name,
                bookCount = count,
                imageUrl = id?.let {
                    "$base/api/authors/$it/image" + if (!token.isNullOrEmpty()) "?token=$token" else ""
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
        val token = session.accessToken
        val counts = dao.seriesWithCounts(minBooks)
        val kept = counts.map { it.name }.toSet()
        val covers = LinkedHashMap<String, MutableList<String>>()
        for (row in dao.seriesCovers()) {
            if (row.series !in kept) continue
            val list = covers.getOrPut(row.series) { mutableListOf() }
            if (list.size >= 3) continue
            list += row.coverPath?.takeIf { java.io.File(it).exists() }?.let { "file://$it" }
                ?: BookMapper.coverUrl(row.id, base, token)
        }
        counts.map { SeriesRow(it.name, it.bookCount, covers[it.name].orEmpty()) }
    }

    /**
     * Collections have no server endpoint — they are a client-side grouping over
     * the `collection` field parsed out of each book's metadata.
     */
    suspend fun collections(): Map<String, List<Book>> = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        val token = session.accessToken
        dao.booksInAnyCollection()
            .map { it.toBook(base, token) }
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
        dao.continueListening(limit).map { it.toBook(session.baseUrl.orEmpty(), session.accessToken) }
    }

    suspend fun recentlyAdded(limit: Int = 20): List<Book> = withContext(Dispatchers.IO) {
        dao.recentlyAdded(limit).map { it.toBook(session.baseUrl.orEmpty(), session.accessToken) }
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
        val token = session.accessToken
        val books = sessions.map { it.itemId }.toSet()
            .associateWith { dao.getBook(it)?.toBook(base, token) }

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
        val etagKey = "etag_${libraryId}_${sortField}_${desc}_$page"
        val etag = if (force) null else etagPrefs.getString(etagKey, null)

        var result = api.libraryItems(libraryId, page, limit, sortField, desc, etag)

        if (result.notModified) {
            val cached = dao.countBooksRaw(
                BooksDao.libraryQuery(sort, LibraryFilter.ALL, null, 0, 0, countOnly = true)
            )
            // A 304 is only trustworthy if we actually have the rows it refers to.
            if (cached > 0) return@withContext 0
            result = api.libraryItems(libraryId, page, limit, sortField, desc, etag = null)
        }

        result.etag?.let { etagPrefs.edit().putString(etagKey, it).apply() }
        upsert(result.items)
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
    suspend fun syncAll(pageSize: Int = 50): Int = withContext(Dispatchers.IO) {
        var page = 1
        var total = 0
        val seen = HashSet<String>()
        var fullSweep = false

        // Which paging parameter this server actually honours. We start with `page`
        // and, the first time a page>1 comes back as only already-seen items (the
        // server ignored `page`), switch to `offset` and then `skip` — the same
        // three-way fallback the Flutter app used. Once one works we stick with it.
        var paging = AbsApi.Paging.PAGE
        val (sortField, desc) = serverSort(BookSort.UPDATED_DESC)

        fun fetch(p: Int, mode: AbsApi.Paging) = runCatching {
            api.libraryItems(libraryId, p, pageSize, sortField, desc, etag = null, paging = mode)
        }.getOrNull()

        while (page <= MAX_SYNC_PAGES) {
            var result = fetch(page, paging) ?: break
            if (result.items.isEmpty()) { fullSweep = true; break }

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
            total += upsert(result.items)
            if (fresh == 0) break

            if (result.items.size < pageSize) { fullSweep = true; break }
            page++
        }

        // Only a complete, uninterrupted sweep makes `seen` an authoritative list of
        // what still exists on the server — so only then may we prune. A network
        // failure mid-sweep must never delete books.
        if (fullSweep) pruneDeletedBooks(seen)

        Log.i(TAG, "syncAll: cached $total new books over $page page(s)")
        total
    }

    /**
     * Removes local books the server no longer lists — but keeps anything the user
     * has downloaded, so a book deleted server-side stays playable offline until
     * they remove the download themselves.
     */
    private suspend fun pruneDeletedBooks(serverIds: Set<String>) {
        val downloaded = runCatching { Services.downloads.downloadedItemIds() }
            .getOrDefault(emptyList()).toSet()
        val stale = dao.allBookIds().filter { it !in serverIds && it !in downloaded }
        stale.forEach { dao.deleteBook(it); dao.deleteProgress(it) }
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

    private suspend fun upsert(items: List<JsonObject>): Int {
        val base = session.baseUrl.orEmpty()
        val token = session.accessToken
        val books = items
            .mapNotNull { BookMapper.fromLibraryItem(it, base, token) }
            // Ebooks and podcasts never enter the library cache.
            .filter { it.isAudioBook }

        if (books.isEmpty()) return 0

        // Don't overwrite a newer local row with a staler server one.
        val fresh = books.filter { book ->
            val existing = dao.updatedAtOf(book.id)
            existing == null || book.updatedAt == null || book.updatedAt > existing
        }
        if (fresh.isNotEmpty()) dao.upsertBooks(fresh.map { it.toEntity() })
        return fresh.size
    }

    suspend fun searchServer(query: String): List<Book> = withContext(Dispatchers.IO) {
        val base = session.baseUrl.orEmpty()
        val token = session.accessToken
        val found = api.search(libraryId, query).mapNotNull { BookMapper.fromLibraryItem(it, base, token) }
            .filter { it.isAudioBook }
        if (found.isNotEmpty()) dao.upsertBooks(found.map { it.toEntity() })
        found
    }

    /**
     * Progress for every book, from a single `GET /api/me`. Stored so the library
     * filters can run in SQL instead of being applied to a loaded page.
     */
    suspend fun syncProgress(): Int = withContext(Dispatchers.IO) {
        val me = runCatching { api.me() }.getOrNull() ?: return@withContext 0
        val entries = (me["mediaProgress"] as? JsonArray).orEmpty().mapNotNull { el ->
            val m = el.obj() ?: return@mapNotNull null
            val itemId = m["libraryItemId"].str() ?: m["id"].str() ?: return@mapNotNull null

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

            MediaProgressEntity(
                itemId = itemId,
                progress = progress,
                isFinished = finished,
                currentTimeSec = currentTime,
                durationSec = duration,
                lastUpdate = m["lastUpdate"].num()?.toLong() ?: System.currentTimeMillis(),
            )
        }
        if (entries.isNotEmpty()) dao.upsertProgress(entries)

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

    suspend fun progressFor(id: String): MediaProgressEntity? = withContext(Dispatchers.IO) {
        dao.progressFor(id)
    }

    /**
     * "Mark as Finished": tells the server, then writes the finished state to the
     * local progress table so the UI updates at once — without this the network
     * call ran on the caller's dispatcher and nothing local changed, so the book
     * still showed as in-progress until the next full resync.
     */
    suspend fun markFinished(id: String): Boolean = withContext(Dispatchers.IO) {
        val ok = Services.playbackApi.markFinished(id)
        val existing = dao.progressFor(id)
        val duration = existing?.durationSec ?: 0.0
        dao.upsertProgress(
            listOf(
                MediaProgressEntity(
                    itemId = id,
                    progress = 1.0,
                    isFinished = true,
                    currentTimeSec = if (duration > 0) duration else existing?.currentTimeSec ?: 0.0,
                    durationSec = duration,
                    lastUpdate = System.currentTimeMillis(),
                )
            )
        )
        ok
    }

    /**
     * Progress for every book, so a list row can show its finished/in-progress mark.
     *
     * Wrapped in `flow { }` so the DAO is not touched until someone collects: the
     * database is opened by ensureLibrary(), which runs after the ViewModel is
     * constructed, and touching `dao` eagerly crashes the ViewModel's init.
     */
    fun watchProgress(): Flow<Map<String, MediaProgressEntity>> = flow {
        emitAll(dao.watchAllProgress().map { rows -> rows.associateBy { it.itemId } })
    }

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
    }
}
