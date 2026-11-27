package com.bennybar.kitzi.data.audible

import android.content.Context
import com.bennybar.kitzi.data.model.arr
import com.bennybar.kitzi.data.model.int
import com.bennybar.kitzi.data.model.num
import com.bennybar.kitzi.data.model.obj
import com.bennybar.kitzi.data.model.str
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.security.MessageDigest
import java.time.LocalDate
import java.util.concurrent.TimeUnit

/** A genre in Audible's catalog. */
@androidx.compose.runtime.Immutable
data class AudibleGenre(val id: String, val name: String)

/** A book in Audible's catalog (not necessarily in the library). */
@androidx.compose.runtime.Immutable
data class AudibleBook(
    val asin: String,
    val title: String,
    val subtitle: String?,
    val authors: List<String>,
    val narrators: List<String>,
    val coverUrl: String?,
    /** A smaller cover for lists. */
    val thumbUrl: String?,
    val stars: Double?,
    val ratingCount: Int,
    val performanceStars: Double?,
    val storyStars: Double?,
    val minutes: Int?,
    val format: String?,
    val kind: String?,
    val releaseDate: String?,
    val language: String?,
    val publisher: String?,
    /** The series it belongs to, with its number there ("3", "2.5", "1-3"). */
    val seriesRefs: List<SeriesRef>,
    /** The genres with their Audible ids. */
    val genreRefs: List<AudibleGenre>,
    val summary: String?,
) {
    @androidx.compose.runtime.Immutable
    data class SeriesRef(val asin: String, val title: String, val sequence: String?)

    val author: String? get() = authors.takeIf { it.isNotEmpty() }?.joinToString(", ")
    val year: String? get() = releaseDate?.take(4)
    val releaseDay: LocalDate? get() = releaseDate?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }

    companion object {
        fun from(p: JsonObject): AudibleBook? {
            val asin = p["asin"].str() ?: return null
            val title = p["title"].str() ?: return null
            val images = p["product_images"].obj()
            val cover = images?.get("500").str()
            val rating = p["rating"].obj()
            val overall = rating?.get("overall_distribution").obj()
            val seriesRefs = p["series"].arr().orEmpty().mapNotNull { el ->
                val s = el.obj() ?: return@mapNotNull null
                SeriesRef(s["asin"].str() ?: return@mapNotNull null, s["title"].str() ?: return@mapNotNull null, s["sequence"].str())
            }
            val seen = HashSet<String>()
            val genres = p["category_ladders"].arr().orEmpty()
                .flatMap { it.obj()?.get("ladder").arr().orEmpty() }
                .mapNotNull { el ->
                    val g = el.obj() ?: return@mapNotNull null
                    val id = g["id"].str() ?: return@mapNotNull null
                    val name = g["name"].str() ?: return@mapNotNull null
                    if (seen.add(id)) AudibleGenre(id, name) else null
                }
            fun stars(o: JsonObject?) = (o?.get("display_average_rating").num() ?: o?.get("average_rating").num())?.takeIf { it > 0 }
            return AudibleBook(
                asin = asin.uppercase(),
                title = title,
                subtitle = p["subtitle"].str(),
                authors = p["authors"].arr().orEmpty().mapNotNull { it.obj()?.get("name").str() },
                narrators = p["narrators"].arr().orEmpty().mapNotNull { it.obj()?.get("name").str() },
                coverUrl = cover,
                thumbUrl = images?.get("252").str() ?: cover,
                stars = stars(overall),
                ratingCount = overall?.get("num_ratings").int() ?: 0,
                performanceStars = stars(rating?.get("performance_distribution").obj()),
                storyStars = stars(rating?.get("story_distribution").obj()),
                minutes = p["runtime_length_min"].int()?.takeIf { it > 0 },
                format = p["format_type"].str()?.replace("_", " ")?.split(" ")?.joinToString(" ") { w -> w.replaceFirstChar { it.uppercase() } },
                kind = p["content_delivery_type"].str()?.let(::kindLabel),
                releaseDate = p["release_date"].str() ?: p["issue_date"].str(),
                language = p["language"].str()?.replaceFirstChar { it.uppercase() },
                publisher = p["publisher_name"].str(),
                seriesRefs = seriesRefs,
                genreRefs = genres,
                summary = (p["publisher_summary"].str() ?: p["merchandising_summary"].str())?.let(::stripHtml),
            )
        }

        private fun kindLabel(t: String) = when (t) {
            "SinglePartBook", "MultiPartBook" -> "Audiobook"
            "Periodical", "PodcastParent", "PodcastEpisode", "PodcastSeason" -> "Podcast"
            "BookSeries" -> "Series"
            else -> t
        }
    }
}

/** A step of a series' ladder: a book of the library, or one on Audible that isn't here. Unnumbered last. */
sealed interface SeriesRung {
    val number: Double

    data class Mine(val book: com.bennybar.kitzi.data.model.Book) : SeriesRung {
        override val number: Double get() = book.seriesSequence ?: 9999.0
    }

    data class Missing(val book: AudibleBook, val sequence: Double?) : SeriesRung {
        override val number: Double get() = sequence ?: 9999.0
    }
}

data class AudibleReview(
    val id: String,
    val title: String?,
    val body: String,
    val author: String?,
    val stars: Double?,
    val date: LocalDate?,
    val helpful: Int,
)

/** Text without HTML tags and entities (Audible's summaries and reviews carry both). */
fun stripHtml(s: String): String =
    androidx.core.text.HtmlCompat.fromHtml(s.replace("\n", "<br>"), androidx.core.text.HtmlCompat.FROM_HTML_MODE_LEGACY)
        .toString().replace(Regex("\n{3,}"), "\n\n").trim()

/**
 * Audible's public catalog API: search, a book, similar books, reviews, genres and
 * series. Shown in Kitzi's own screens. Answers are kept in memory and on disk for
 * a while, so a page opened again costs nothing.
 */
object AudibleCatalog {
    /** Everything a book's page shows. */
    private const val GROUPS = "rating,product_desc,product_attrs,contributors,media,series,category_ladders,product_extended_attrs"
    /** What a list row shows (about half the download): the page loads the rest. */
    private const val LIST_GROUPS = "rating,product_attrs,contributors,media,series"
    private const val BASE = "https://api.audible.com/1.0/catalog"

    enum class SearchSort(val key: String, val label: String) {
        RELEVANCE("Relevance", "Best match"),
        BESTSELLERS("BestSellers", "Bestsellers"),
        NEWEST("-ReleaseDate", "Newest"),
        LONGEST("-RuntimeLength", "Longest"),
    }

    enum class GenreList(val label: String) { BESTSELLERS("Bestsellers"), TOP_RATED("Top Rated"), NEW_RELEASES("New Releases") }

    const val PAGE_SIZE = 30

    private val client by lazy { OkHttpClient.Builder().callTimeout(15, TimeUnit.SECONDS).build() }
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val memory = HashMap<String, Pair<Long, JsonObject>>()
    private var cacheDir: File? = null

    fun init(context: Context) {
        cacheDir = File(context.cacheDir, "audible").apply { mkdirs() }
    }

    /** Recently looked-at books, so a page opens with what the list already had. */
    private val known = object : LinkedHashMap<String, AudibleBook>(64, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, AudibleBook>?) = size > 300
    }

    fun remember(books: List<AudibleBook>) = synchronized(known) { books.forEach { known[it.asin] = it } }
    fun peek(asin: String): AudibleBook? = synchronized(known) { known[asin] }

    private fun books(root: JsonObject?, key: String = "products"): List<AudibleBook> =
        root?.get(key).arr().orEmpty().mapNotNull { it.obj()?.let(AudibleBook::from) }.also(::remember)

    private fun url(path: String, vararg params: Pair<String, String?>): String {
        val b = "$BASE$path".toHttpUrl().newBuilder()
        params.forEach { (k, v) -> if (v != null) b.addQueryParameter(k, v) }
        return b.build().toString()
    }

    /** A page of search results (`page` from 0: Audible counts them from 0). */
    suspend fun search(query: String, sort: SearchSort = SearchSort.RELEVANCE, page: Int = 0): List<AudibleBook> =
        books(get(url("/products", "keywords" to query, "num_results" to "$PAGE_SIZE", "page" to "$page",
            "products_sort_by" to sort.key, "image_sizes" to "252,500", "response_groups" to LIST_GROUPS), ttlSec = 600))

    /** One book with everything its page shows. */
    suspend fun product(asin: String): AudibleBook? =
        get(url("/products/$asin", "image_sizes" to "252,500", "response_groups" to GROUPS), ttlSec = 86400)
            ?.get("product").obj()?.let(AudibleBook::from)?.also { remember(listOf(it)) }

    /** Many books by ASIN, 50 to a request, with just [groups], as Audible answers. A request that fails is skipped. */
    suspend fun products(asins: List<String>, groups: String): List<JsonObject> =
        asins.chunked(50).flatMap { chunk ->
            runCatching { get(url("/products", "asins" to chunk.joinToString(","), "response_groups" to groups), ttlSec = 86400) }
                .getOrNull()?.get("products").arr().orEmpty().mapNotNull { it.obj() }
        }

    /** Books by an author or a narrator, bestsellers first. */
    suspend fun booksBy(author: String? = null, narrator: String? = null): List<AudibleBook> =
        mainLanguage(books(get(url("/products", "num_results" to "50", "products_sort_by" to "BestSellers",
            "image_sizes" to "252,500", "response_groups" to LIST_GROUPS, "author" to author, "narrator" to narrator), ttlSec = 6 * 3600)))

    /** An author's or a narrator's books, newest release first (pre-orders included). */
    suspend fun newest(author: String? = null, narrator: String? = null): List<AudibleBook> =
        mainLanguage(books(get(url("/products", "num_results" to "20", "products_sort_by" to "-ReleaseDate",
            "image_sizes" to "252,500", "response_groups" to LIST_GROUPS, "author" to author, "narrator" to narrator), ttlSec = 6 * 3600)))

    /**
     * "Listeners also enjoyed": Audible's similar books, in the book's own language
     * (it also suggests the same book in other languages).
     */
    suspend fun similar(asin: String, language: String? = null): List<AudibleBook> {
        val sims = get(url("/products/$asin/sims", "similarity_type" to "RawSimilarities", "num_results" to "20",
            "image_sizes" to "252,500", "response_groups" to LIST_GROUPS), ttlSec = 86400)
        val lang = (language ?: runCatching {
            get(url("/products/$asin", "response_groups" to "product_attrs"), ttlSec = 7 * 86400)?.get("product").obj()?.get("language").str()
        }.getOrNull())?.lowercase()
        return books(sims, "similar_products")
            .filter { lang == null || it.language == null || it.language.lowercase() == lang }
            .filter { it.asin != asin.uppercase() }
    }

    /** The language most of [books] are in, and only those (lists also carry translations). */
    fun mainLanguage(books: List<AudibleBook>): List<AudibleBook> {
        val main = books.mapNotNull { it.language }.groupingBy { it }.eachCount().maxByOrNull { it.value }?.key ?: return books
        return books.filter { it.language == null || it.language == main }
    }

    /** The most helpful reviews. */
    suspend fun reviews(asin: String, count: Int = 5): List<AudibleReview> =
        get(url("/products/$asin/reviews", "num_results" to "$count", "sort_by" to "MostHelpful"), ttlSec = 86400)
            ?.get("customer_reviews").arr().orEmpty().mapNotNull { el ->
                val r = el.obj() ?: return@mapNotNull null
                val id = r["id"].str() ?: return@mapNotNull null
                val body = r["body"].str()?.let(::stripHtml)?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
                AudibleReview(
                    id = id,
                    title = r["title"].str()?.let(::stripHtml),
                    body = body,
                    author = r["author_name"].str(),
                    stars = r["ratings"].obj()?.get("overall_rating").num()?.takeIf { it > 0 },
                    date = r["submission_date"].str()?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() },
                    helpful = r["review_content_scores"].obj()?.get("num_helpful_votes").int() ?: 0,
                )
            }

    private val genreCache = HashMap<String, List<AudibleGenre>>()

    /** The top-level genres ([parent] null), or a genre's subgenres. */
    suspend fun genres(parent: String? = null): List<AudibleGenre> {
        genreCache[parent.orEmpty()]?.let { return it }
        val list = if (parent != null) {
            get(url("/categories/$parent", "categories_num_levels" to "1"), ttlSec = 7 * 86400)
                ?.get("category").obj()?.get("children").arr()
        } else {
            get(url("/categories", "categories_num_levels" to "1"), ttlSec = 7 * 86400)?.get("categories").arr()
        }.orEmpty().mapNotNull { el ->
            val c = el.obj() ?: return@mapNotNull null
            AudibleGenre(c["id"].str() ?: return@mapNotNull null, c["name"].str() ?: return@mapNotNull null)
        }
        if (list.isNotEmpty()) genreCache[parent.orEmpty()] = list
        return list
    }

    /** A genre's bestsellers (top 100), in the language most of them are in. */
    private suspend fun bestsellers(genre: String): List<AudibleBook> {
        val all = (0..1).flatMap { page ->
            books(get(url("/products", "category_id" to genre, "products_sort_by" to "BestSellers", "num_results" to "50",
                "page" to "$page", "image_sizes" to "252,500", "response_groups" to LIST_GROUPS), ttlSec = 6 * 3600))
        }
        return mainLanguage(all.distinctBy { it.asin })
    }

    /**
     * A genre's list. Top rated: its bestsellers by stars weighted by how many rated
     * them (Audible's own rating sort puts a 4.9 from 200 people first). New
     * releases: its bestsellers out in the last four months, newest first (Audible's
     * newest-first list is pages of pre-orders).
     */
    suspend fun genreBooks(genre: String, list: GenreList): List<AudibleBook> {
        val books = bestsellers(genre)
        return when (list) {
            GenreList.BESTSELLERS -> books
            GenreList.TOP_RATED -> books.filter { (it.stars ?: 0.0) > 0 }.sortedByDescending(::weighted)
            GenreList.NEW_RELEASES -> {
                val now = LocalDate.now()
                val from = now.minusDays(120)
                books.filter { b -> b.releaseDay?.let { !it.isBefore(from) && !it.isAfter(now) } ?: false }
                    .sortedByDescending { it.releaseDay }
            }
        }
    }

    /** Stars pulled towards a typical 4.3 by the weight of 100 ratings. */
    fun weighted(b: AudibleBook): Double = ((b.stars ?: 0.0) * b.ratingCount + 4.3 * 100) / (b.ratingCount + 100)

    /**
     * The Audible series a library series is, from the first of its books Audible
     * knows: the one whose name matches (or the book's only series). Null rather than
     * a guess when the book is in several and none matches (a bigger "universe"
     * isn't this series).
     */
    suspend fun seriesFor(name: String, books: List<com.bennybar.kitzi.data.model.Book>): Pair<AudibleBook.SeriesRef, String?>? {
        val want = AudibleMatch.norm(name)
        for (b in books.take(4)) {
            val asin = AudibleRatingService.asin(b) ?: continue
            val p = get(url("/products/$asin", "response_groups" to "series,product_attrs"), ttlSec = 86400)?.get("product").obj() ?: continue
            val refs = p["series"].arr().orEmpty().mapNotNull { el ->
                val s = el.obj() ?: return@mapNotNull null
                AudibleBook.SeriesRef(s["asin"].str() ?: return@mapNotNull null, s["title"].str() ?: return@mapNotNull null, s["sequence"].str())
            }
            val named = refs.firstOrNull { AudibleMatch.norm(it.title) == want }
                ?: refs.firstOrNull { AudibleMatch.similar(AudibleMatch.norm(it.title), want) }
            val ref = named ?: refs.singleOrNull()
            if (ref != null) return ref to p["language"].str()
        }
        return null
    }

    /** Every book of an Audible series, in series order, in [language] if given. */
    suspend fun seriesBooks(series: AudibleBook.SeriesRef, language: String?): List<AudibleBook> {
        val asins = get(url("/products/${series.asin}", "response_groups" to "relationships"), ttlSec = 86400)
            ?.get("product").obj()?.get("relationships").arr().orEmpty()
            .mapNotNull { it.obj() }
            .filter { it["relationship_type"].str() == "series" && it["relationship_to_product"].str() == "child" }
            .mapNotNull { it["asin"].str() }
        val found = asins.chunked(40).flatMap { chunk ->
            books(get(url("/products", "asins" to chunk.joinToString(","), "image_sizes" to "252,500", "response_groups" to LIST_GROUPS), ttlSec = 86400))
        }
        val lang = language?.lowercase()
        return found
            .filter { lang == null || it.language == null || it.language.lowercase() == lang }
            .sortedWith(compareBy<AudibleBook> { sequence(it, series.asin) }.thenByDescending { it.ratingCount })
    }

    /**
     * The numbers a series entry covers: "3" is [3], "1-3" (a box set) is [1, 2, 3],
     * "2.5" is [2.5]; empty when it has none.
     */
    fun numbers(sequence: String?): List<Double> {
        val s = sequence?.trim()?.takeIf { it.isNotEmpty() } ?: return emptyList()
        s.toDoubleOrNull()?.let { return listOf(it) }
        val parts = s.split('-', '–').map { it.trim() }
        if (parts.size == 2) {
            val a = parts[0].toIntOrNull(); val b = parts[1].toIntOrNull()
            if (a != null && b != null && a <= b && b - a < 50) return (a..b).map { it.toDouble() }
        }
        return emptyList()
    }

    /** The book's number in a series (unnumbered last). */
    fun sequence(b: AudibleBook, series: String): Double =
        numbers(b.seriesRefs.firstOrNull { it.asin == series }?.sequence).firstOrNull() ?: 9999.0

    /** The book's entry in a series ("3", "1-3"). */
    fun sequenceLabel(b: AudibleBook, series: String): String? = b.seriesRefs.firstOrNull { it.asin == series }?.sequence

    /** Dated more than five years out: Audible's placeholder for "no date" (1 Jan 2200). */
    fun farFuture(b: AudibleBook, today: LocalDate): Boolean = b.releaseDay?.isAfter(today.plusYears(5)) == true

    /**
     * The books of a series ([all], in series order, as [seriesBooks] gives them)
     * that aren't in the library: not [inLibrary] (ASINs matched to it), and not by
     * their number either ([owned]: another edition of a book that's here, a box set
     * of books that are). One edition per number: the most-rated (they come first).
     */
    fun missingFromSeries(
        all: List<AudibleBook>,
        seriesAsin: String,
        inLibrary: Set<String>,
        owned: Set<Double>,
        today: LocalDate,
    ): List<SeriesRung.Missing> {
        val seen = HashSet<Double>()
        return all.mapNotNull { b ->
            if (b.asin in inLibrary || farFuture(b, today)) return@mapNotNull null
            val ns = numbers(sequenceLabel(b, seriesAsin))
            when {
                ns.isEmpty() -> SeriesRung.Missing(b, null)
                ns.all { it in owned } -> null
                ns.size == 1 && !seen.add(ns[0]) -> null
                else -> SeriesRung.Missing(b, ns[0])
            }
        }
    }

    /** Every book of a series in order: yours, and Audible's that aren't here (yours first at the same number). */
    fun ladder(mine: List<com.bennybar.kitzi.data.model.Book>, missing: List<SeriesRung.Missing>): List<SeriesRung> =
        (mine.map { SeriesRung.Mine(it) } + missing).sortedBy { it.number }

    /** Null when Audible answered 404; throws when it couldn't be reached. */
    private suspend fun get(url: String, ttlSec: Long = 0): JsonObject? = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val file = cacheDir?.let { File(it, sha256(url)) }
        if (ttlSec > 0) {
            synchronized(memory) { memory[url] }?.let { (at, j) -> if (now - at < ttlSec * 1000) return@withContext j }
            if (file != null && file.isFile && now - file.lastModified() < ttlSec * 1000) {
                runCatching { json.parseToJsonElement(file.readText()) as JsonObject }.getOrNull()?.let {
                    synchronized(memory) { memory[url] = file.lastModified() to it }
                    return@withContext it
                }
            }
        }
        val req = Request.Builder().url(url).header("User-Agent", "Kitzi/1.0").build()
        client.newCall(req).execute().use { resp ->
            if (resp.code == 404) return@withContext null
            if (!resp.isSuccessful) throw java.io.IOException("Audible answered ${resp.code}")
            val body = resp.body?.string() ?: throw java.io.IOException("empty answer")
            val root = json.parseToJsonElement(body) as? JsonObject ?: throw java.io.IOException("not JSON")
            if (ttlSec > 0) {
                synchronized(memory) { memory[url] = now to root }
                runCatching { file?.writeText(body) }
            }
            root
        }
    }

    private fun sha256(s: String): String =
        MessageDigest.getInstance("SHA-256").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }
}
