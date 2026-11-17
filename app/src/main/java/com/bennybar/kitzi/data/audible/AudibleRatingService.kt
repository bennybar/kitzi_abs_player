package com.bennybar.kitzi.data.audible

import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.AudibleEntity
import com.bennybar.kitzi.data.model.Book
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.abs

/**
 * A library book's Audible match: its ASIN (the server's, else found by a title,
 * author and running-time search), stars and language. Kept in the library's
 * database for a week (a day when nothing matched); an older one is still used
 * when Audible can't be reached.
 */
object AudibleRatingService {
    private const val GROUPS = "rating,product_attrs,product_desc,contributors"
    private const val MAX_AGE_MS = 7L * 86400_000
    private const val NO_MATCH_MAX_AGE_MS = 86400_000L

    private val mem = HashMap<String, AudibleEntity>()

    // Fetches run on a service-level scope and are shared per item, so one started
    // from a screen completes and is saved even if that screen closes first.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inflight = HashMap<String, Deferred<AudibleEntity?>>()

    /** Filling in the library's ratings (the "Highest rated" sort): done of total; total 0 when idle. */
    private val _fill = MutableStateFlow(0 to 0)
    val fill: StateFlow<Pair<Int, Int>> = _fill

    private val client by lazy { OkHttpClient.Builder().callTimeout(12, TimeUnit.SECONDS).build() }

    /** What's known this session, without asking anyone. */
    fun peek(itemId: String): AudibleEntity? = synchronized(mem) { mem[itemId] }

    private suspend fun saved(itemId: String): AudibleEntity? {
        peek(itemId)?.let { return it }
        return runCatching { Services.audibleDao().get(itemId) }.getOrNull()?.also { synchronized(mem) { mem[itemId] = it } }
    }

    private suspend fun save(rows: List<AudibleEntity>) {
        synchronized(mem) { rows.forEach { mem[it.itemId] = it } }
        runCatching { Services.audibleDao().upsert(rows) }
    }

    private fun fresh(r: AudibleEntity) =
        System.currentTimeMillis() - r.at < (if (r.asin.isEmpty()) NO_MATCH_MAX_AGE_MS else MAX_AGE_MS)

    /** The book's stars (null when Audible has no match or no ratings yet). */
    suspend fun rating(book: Book): AudibleEntity? = lookup(book)?.takeIf { it.stars > 0 }

    /** The book's Audible ASIN, rated or not (null when Audible has no match). */
    suspend fun asin(book: Book): String? = book.asin ?: lookup(book)?.asin?.takeIf { it.isNotEmpty() }

    /** The book's language on Audible ("english"), when known. */
    suspend fun language(book: Book): String? = lookup(book)?.language

    /** The saved match, refreshed when it's old. Offline, the old one. */
    suspend fun lookup(book: Book): AudibleEntity? {
        val old = saved(book.id)
        if (old != null && fresh(old)) return old
        val job = synchronized(inflight) {
            inflight[book.id] ?: scope.async {
                try {
                    // A real answer (a match, or none) is saved; "no match" as an empty ASIN.
                    val r = fetch(book) ?: AudibleEntity(book.id, "", 0.0, 0, System.currentTimeMillis(), null)
                    save(listOf(r))
                    r
                } catch (e: Exception) {
                    old // offline or Audible failed: keep what was known
                } finally {
                    synchronized(inflight) { inflight.remove(book.id) }
                }
            }.also { inflight[book.id] = it }
        }
        return job.await()
    }

    /**
     * Looks up the matches not known yet. Books with the server's ASIN go 50 to a
     * request; the rest (a title search each) a few at a time.
     */
    suspend fun fillIn(books: List<Book>) = withContext(Dispatchers.IO) {
        if (_fill.value.second > 0) return@withContext
        val known = runCatching { Services.audibleDao().knownIds().toHashSet() }.getOrDefault(hashSetOf())
        val todo = books.filter { it.id !in known }
        if (todo.isEmpty()) return@withContext
        _fill.value = 0 to todo.size
        try {
            val (withAsin, without) = todo.partition { it.asin != null }
            for (chunk in withAsin.chunked(50)) {
                val url = "https://api.audible.com/1.0/catalog/products".toHttpUrl().newBuilder()
                    .addQueryParameter("asins", chunk.joinToString(",") { it.asin!! })
                    .addQueryParameter("response_groups", "rating,product_attrs").build()
                val root = runCatching { get(url) }.getOrNull() ?: continue
                val found = HashMap<String, JSONObject>()
                root.optJSONArray("products")?.let { a ->
                    for (i in 0 until a.length()) a.optJSONObject(i)?.let { p -> found[p.optString("asin").uppercase()] = p }
                }
                val now = System.currentTimeMillis()
                // Not in Audible's (US) catalog: no stars, but the ASIN stays known.
                save(chunk.map { b -> found[b.asin!!]?.let { entity(b.id, it) } ?: AudibleEntity(b.id, b.asin!!, 0.0, 0, now, null) })
                _fill.value = (_fill.value.first + chunk.size) to _fill.value.second
            }
            for (group in without.chunked(4)) {
                coroutineScope { group.map { b -> async { lookup(b) } }.awaitAll() }
                _fill.value = (_fill.value.first + group.size) to _fill.value.second
            }
        } finally {
            _fill.value = 0 to 0
        }
    }

    /** Null when Audible has no match; throws when it couldn't be asked. */
    private fun fetch(book: Book): AudibleEntity? {
        // The server's ASIN is the reliable match (the library list carries it;
        // an older cached copy may not, so ask the server then).
        val asin = book.asin ?: fetchAbsAsin(book.id)
        if (!asin.isNullOrBlank()) {
            val url = "https://api.audible.com/1.0/catalog/products/$asin".toHttpUrl().newBuilder()
                .addQueryParameter("response_groups", "rating,product_attrs").build()
            get(url)?.optJSONObject("product")?.let { return entity(book.id, it) }
            // Not in this store's catalog: still the book's ASIN.
            return AudibleEntity(book.id, asin.uppercase(), 0.0, 0, System.currentTimeMillis(), null)
        }
        val author = book.authors.firstOrNull() ?: book.author?.split(",")?.firstOrNull()?.trim()
        return searchBestMatch(book.title, author, book.durationMs)?.let { entity(book.id, it) }
    }

    private fun entity(itemId: String, p: JSONObject): AudibleEntity {
        val dist = p.optJSONObject("rating")?.optJSONObject("overall_distribution")
        val avg = dist?.opt("display_average_rating") ?: dist?.opt("average_rating")
        val stars = when (avg) {
            is Number -> avg.toDouble()
            is String -> avg.toDoubleOrNull() ?: 0.0
            else -> 0.0
        }
        return AudibleEntity(
            itemId = itemId,
            asin = p.optString("asin").uppercase(),
            stars = stars,
            count = dist?.optInt("num_ratings") ?: 0,
            at = System.currentTimeMillis(),
            language = p.optString("language").takeIf { it.isNotBlank() && it != "null" },
        )
    }

    private fun fetchAbsAsin(itemId: String): String? {
        val base = Services.session.baseUrl ?: return null
        val req = Request.Builder().url("$base/api/items/$itemId").build()
        return runCatching {
            Services.httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@use null
                val root = JSONObject(resp.body?.string() ?: return@use null)
                val meta = (root.optJSONObject("item") ?: root).optJSONObject("media")?.optJSONObject("metadata")
                // optString gives the string "null" for a JSON null.
                meta?.takeIf { !it.isNull("asin") }?.optString("asin")?.takeIf { it.isNotBlank() && it != "null" }
            }
        }.getOrNull()
    }

    /** Null for "not found" (404); throws when Audible couldn't be reached or failed. */
    private fun get(url: okhttp3.HttpUrl): JSONObject? {
        val req = Request.Builder().url(url).header("User-Agent", "Kitzi/1.0").build()
        return client.newCall(req).execute().use { resp ->
            if (resp.code == 404) return@use null
            if (!resp.isSuccessful) throw java.io.IOException("Audible answered ${resp.code}")
            JSONObject(resp.body?.string() ?: throw java.io.IOException("empty"))
        }
    }

    // === title search ===

    private fun searchBestMatch(title: String, author: String?, durationMs: Long?): JSONObject? {
        if (title.isBlank()) return null
        val queries = AudibleMatch.queryVariants(title)
        val matchTitles = queries.map(AudibleMatch::loose).filter { it.isNotEmpty() }.toSet()
        for (q in queries) {
            var products = searchProducts(q, author)
            if (products.isEmpty() && !author.isNullOrEmpty()) products = searchProducts(q, null)
            if (products.isEmpty()) continue
            pickBest(products, matchTitles, author, durationMs)?.let { return it }
        }
        return null
    }

    private fun searchProducts(title: String, author: String?): List<JSONObject> {
        val b = "https://api.audible.com/1.0/catalog/products".toHttpUrl().newBuilder()
            .addQueryParameter("title", title)
            .addQueryParameter("num_results", "10")
            .addQueryParameter("products_sort_by", "Relevance")
            .addQueryParameter("response_groups", GROUPS)
        if (!author.isNullOrEmpty()) b.addQueryParameter("author", author)
        val arr = get(b.build())?.optJSONArray("products") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    private fun pickBest(products: List<JSONObject>, matchTitles: Set<String>, author: String?, durationMs: Long?): JSONObject? {
        val wantMinutes = durationMs?.let { it / 60000.0 }
        val wantAuthor = author?.takeIf { it.isNotEmpty() }?.let(AudibleMatch::loose)
        var best: JSONObject? = null
        var bestScore = 0.0
        for (p in products) {
            val pTitle = AudibleMatch.loose(p.optString("title"))
            if (pTitle.isEmpty()) continue
            val mins = (p.opt("runtime_length_min") as? Number)?.toDouble()
            val titleSim = matchTitles.maxOfOrNull { AudibleMatch.jaccard(it, pTitle) } ?: 0.0
            if (titleSim < 0.8) continue
            var durOk = false
            if (wantMinutes != null && mins != null && mins > 0) {
                if (abs(mins - wantMinutes) / wantMinutes > 0.08) continue
                durOk = true
            }
            var authorOk = false
            if (wantAuthor != null) {
                val authors = p.optJSONArray("authors")?.let { a ->
                    (0 until a.length()).map { i ->
                        val el = a.opt(i)
                        AudibleMatch.loose(if (el is JSONObject) el.optString("name") else el.toString())
                    }
                }.orEmpty()
                authorOk = authors.any { it.isNotEmpty() && AudibleMatch.jaccard(it, wantAuthor) >= 0.5 }
                if (!authorOk && !durOk) continue
            }
            if (!durOk && !authorOk && titleSim < 0.92) continue
            val hasRating = p.optJSONObject("rating")?.optJSONObject("overall_distribution")?.has("num_ratings") == true
            val score = titleSim + (if (durOk) 0.25 else 0.0) + (if (authorOk) 0.25 else 0.0) + (if (hasRating) 0.1 else 0.0)
            if (score > bestScore) { bestScore = score; best = p }
        }
        return best
    }
}

/** Title matching between the library and Audible. */
object AudibleMatch {
    /** The title as searched: without brackets, "Book 3"…, and also the part before a subtitle. */
    fun titleVariants(title: String): List<String> {
        var t = title.replace(Regex("[\\(\\[\\{].*?[\\)\\]\\}]"), " ")
        t = t.replace(Regex("(?i)[-–—:,]?\\s*\\b(book|bk|vol|volume|part)\\b\\.?\\s*\\d+"), " ")
        t = t.replace(Regex("\\s+"), " ").trim()
        val out = mutableListOf(t)
        for (sep in listOf(":", " - ", " – ", " — ")) {
            val i = t.indexOf(sep)
            if (i > 0) t.substring(0, i).trim().takeIf { it.isNotEmpty() && it !in out }?.let(out::add)
        }
        return out.filter { it.isNotEmpty() }
    }

    fun norm(s: String): String = s.lowercase()
        .replace(Regex("\\(.*?\\)"), " ")
        .replace(Regex("[^\\p{L}\\p{N} ]"), " ")
        .replace(Regex("\\s+"), " ")
        .trim()

    /** Same title, or one is the other plus a subtitle. */
    fun similar(a: String, b: String): Boolean =
        a == b || (a.length >= 6 && b.startsWith(a)) || (b.length >= 6 && a.startsWith(b))

    // The search's looser forms (the rating search has always used these).
    internal fun queryVariants(title: String): List<String> {
        val out = LinkedHashSet<String>()
        fun add(s: String) { s.trim().takeIf { it.isNotEmpty() }?.let(out::add) }
        val cleaned = cleanQueryTitle(title)
        add(cleaned)
        val dashParts = cleaned.split(Regex("\\s[-–—]\\s"))
        if (dashParts.size > 1) {
            add(cleanQueryTitle(dashParts.last()))
            add(cleanQueryTitle(dashParts.first()))
        }
        add(title.trim())
        return out.toList()
    }

    private fun cleanQueryTitle(t: String): String {
        var s = t.replace(Regex("[\\(\\[\\{].*?[\\)\\]\\}]"), " ")
        s = s.replace(Regex("(?i)[-–—:,]?\\s*\\b(book|bk|vol|volume|part|episode|ep)\\b\\.?\\s*\\d+"), " ")
        s = s.replace(Regex("[-–—#]\\s*\\d+\\s*$"), " ")
        s = s.replace(Regex("\\s+"), " ").trim().trim(' ', '-', '–', '—', ':', ',')
        return s.ifEmpty { t.trim() }
    }

    internal fun loose(s: String): String {
        var t = s.lowercase()
        val colon = t.indexOf(':')
        if (colon > 3) t = t.substring(0, colon)
        return t.replace(Regex("\\(.*?\\)"), " ")
            .replace("unabridged", " ").replace("abridged", " ")
            .replace(Regex("[^a-z0-9 ]"), " ")
            .replace(Regex("\\s+"), " ").trim()
    }

    /** Token-set Jaccard similarity (0..1). */
    internal fun jaccard(a: String, b: String): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        if (a == b) return 1.0
        val sa = a.split(' ').filter { it.isNotEmpty() }.toSet()
        val sb = b.split(' ').filter { it.isNotEmpty() }.toSet()
        if (sa.isEmpty() || sb.isEmpty()) return 0.0
        return sa.intersect(sb).size.toDouble() / sa.union(sb).size
    }
}

/**
 * Which library book an Audible book is: by ASIN, else the same title (or the
 * title without its subtitle) by the same author. The index is rebuilt when the
 * library changes.
 */
object LibraryMatcher {
    private class Index(val byAsin: Map<String, Book>, val byTitle: Map<String, List<Book>>, val all: List<Book>)
    @Volatile private var index: Index? = null

    fun invalidate() { index = null }

    private suspend fun index(): Index = index ?: withContext(Dispatchers.IO) {
        val books = Services.books.allAudiobooks()
        val byAsin = HashMap<String, Book>()
        val byTitle = HashMap<String, MutableList<Book>>()
        for (b in books) {
            b.asin?.let { byAsin[it] = b }
            for (t in AudibleMatch.titleVariants(b.title).map(AudibleMatch::norm).toSet()) {
                if (t.isNotEmpty()) byTitle.getOrPut(t) { mutableListOf() }.add(b)
            }
        }
        Index(byAsin, byTitle, books).also { index = it }
    }

    suspend fun all(): List<Book> = index().all

    suspend fun match(a: AudibleBook): Book? = match(a, index())

    /** Matches for many at once (one index). */
    suspend fun matchAll(list: List<AudibleBook>): Map<String, Book> {
        val idx = index()
        return list.mapNotNull { a -> match(a, idx)?.let { a.asin to it } }.toMap()
    }

    private fun match(a: AudibleBook, idx: Index): Book? {
        idx.byAsin[a.asin]?.let { return it }
        val authors = a.authors.map(AudibleMatch::norm).filter { it.isNotEmpty() }
        for (t in AudibleMatch.titleVariants(a.title).map(AudibleMatch::norm)) {
            for (b in idx.byTitle[t].orEmpty()) {
                // Another Audible edition of a book here is still this one (same title
                // and author): the ASIN differs between editions.
                val mine = b.authors.ifEmpty { listOf(b.author.orEmpty()) }.map(AudibleMatch::norm).filter { it.isNotEmpty() }
                if (authors.isEmpty() || mine.isEmpty() || mine.any { m -> authors.any { it.contains(m) || m.contains(it) } }) return b
            }
        }
        return null
    }
}
