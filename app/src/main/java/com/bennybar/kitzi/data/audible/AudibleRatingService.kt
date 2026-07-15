package com.bennybar.kitzi.data.audible

import com.bennybar.kitzi.data.Services
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.abs
import kotlin.math.floor

/** A cached Audible community rating for a book. */
data class AudibleRating(
    val rating: Double,        // 0..5 average
    val count: Int?,           // number of ratings
    val asin: String?,         // resolved ASIN, cached for future exact lookups
    val tsMs: Long,            // last refresh time
    val found: Boolean,        // whether a confident rating was resolved
) {
    // Real ratings refresh daily; "not found" results retry sooner so a book
    // that gets rated later doesn't stay blank for a full day.
    fun isStale(nowMs: Long): Boolean =
        nowMs - tsMs > (if (found) 24L else 6L) * 3600_000L

    fun toJson(): String = JSONObject().apply {
        put("rating", rating)
        count?.let { put("count", it) }
        asin?.let { put("asin", it) }
        put("tsMs", tsMs)
        put("found", found)
    }.toString()

    companion object {
        fun fromJson(s: String): AudibleRating? = runCatching {
            val j = JSONObject(s)
            AudibleRating(
                rating = j.optDouble("rating", 0.0),
                count = if (j.has("count")) j.optInt("count") else null,
                asin = j.optString("asin").takeIf { it.isNotBlank() },
                tsMs = j.optLong("tsMs"),
                found = j.optBoolean("found"),
            )
        }.getOrNull()
    }
}

/**
 * Resolves and caches Audible community ratings, ported from the Flutter app.
 *
 * The ASIN is taken from the ABS item metadata when available; otherwise a fuzzy
 * search (title variants + author + runtime within ~8%) resolves it against the
 * public Audible catalog API. Ratings are cached 24h (stale-while-revalidate):
 * callers show the cached value immediately and refresh in place.
 */
object AudibleRatingService {
    private const val PREFIX = "audible_rating_v4_"
    private const val GROUPS = "rating,product_attrs,product_desc,contributors"

    private val mem = mutableMapOf<String, AudibleRating>()

    // Fetches run on a service-level scope and are de-duplicated per item, so a
    // fetch started from a screen completes and caches even if that screen is
    // closed before the network returns — the Flutter `_inflight` behaviour.
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val inflight = mutableMapOf<String, Deferred<AudibleRating?>>()

    private val client by lazy {
        OkHttpClient.Builder()
            .callTimeout(12, TimeUnit.SECONDS)
            .build()
    }

    fun peek(itemId: String): AudibleRating? = mem[itemId]

    fun loadCached(itemId: String): AudibleRating? {
        mem[itemId]?.let { return it }
        val raw = Services.prefs.getString(PREFIX + itemId) ?: return null
        return AudibleRating.fromJson(raw)?.also { mem[itemId] = it }
    }

    /**
     * Returns a rating, refreshing if the cache is stale (>24h) or missing. The
     * network work runs on the service scope and is shared across concurrent
     * callers, so it finishes and caches even if the caller is cancelled (e.g. the
     * screen closed) — the next open then shows the cached value instantly.
     */
    suspend fun resolve(
        itemId: String,
        title: String,
        author: String?,
        narrator: String?,
        durationMs: Long?,
        region: String = "us",
    ): AudibleRating? {
        val cached = loadCached(itemId)
        if (cached != null && !cached.isStale(System.currentTimeMillis())) return cached

        val job = synchronized(inflight) {
            inflight[itemId] ?: scope.async {
                try {
                    val asin = cached?.asin?.takeIf { it.isNotBlank() } ?: fetchAbsAsin(itemId)
                    runCatching {
                        fetchAndCache(itemId, asin, title, author, narrator, durationMs, region)
                    }.getOrNull() ?: cached
                } finally {
                    synchronized(inflight) { inflight.remove(itemId) }
                }
            }.also { inflight[itemId] = it }
        }
        return job.await()
    }

    private fun store(itemId: String, r: AudibleRating) {
        mem[itemId] = r
        runCatching { Services.prefs.putString(PREFIX + itemId, r.toJson()) }
    }

    private fun fetchAndCache(
        itemId: String,
        asin: String?,
        title: String,
        author: String?,
        narrator: String?,
        durationMs: Long?,
        region: String,
    ): AudibleRating {
        var product: JSONObject? = null
        if (!asin.isNullOrBlank()) product = lookupByAsin(asin, region)
        if (product == null) product = searchBestMatch(title, author, durationMs, region)

        val now = System.currentTimeMillis()
        if (product == null) {
            val neg = AudibleRating(0.0, null, asin, now, found = false)
            store(itemId, neg)
            return neg
        }

        val dist = product.optJSONObject("rating")?.optJSONObject("overall_distribution")
        val avg = dist?.opt("display_average_rating") ?: dist?.opt("average_rating")
        val rating = when (avg) {
            is Number -> avg.toDouble()
            is String -> avg.toDoubleOrNull() ?: 0.0
            else -> 0.0
        }
        val count = dist?.let { if (it.has("num_ratings")) it.optInt("num_ratings") else null }
        val resolvedAsin = product.optString("asin").takeIf { it.isNotBlank() && it != "null" } ?: asin

        val r = AudibleRating(rating, count, resolvedAsin, now, found = rating > 0)
        store(itemId, r)
        return r
    }

    // === ABS ASIN ===

    private fun fetchAbsAsin(itemId: String): String? {
        val base = Services.session.baseUrl ?: return null
        val req = Request.Builder().url("$base/api/items/$itemId").build()
        return runCatching {
            Services.httpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@use null
                val body = resp.body?.string() ?: return@use null
                val root = JSONObject(body)
                val item = root.optJSONObject("item") ?: root
                val meta = item.optJSONObject("media")?.optJSONObject("metadata")
                // Android's optString returns the string "null" for a JSON null, so
                // guard both blank and the literal "null".
                meta?.takeIf { !it.isNull("asin") }?.optString("asin")
                    ?.takeIf { it.isNotBlank() && it != "null" }
            }
        }.getOrNull()
    }

    // === Audible catalog API ===

    private fun host(region: String): String = when (region.lowercase()) {
        "uk" -> "api.audible.co.uk"
        "de" -> "api.audible.de"
        "fr" -> "api.audible.fr"
        "au" -> "api.audible.com.au"
        "ca" -> "api.audible.ca"
        "it" -> "api.audible.it"
        "es" -> "api.audible.es"
        "jp" -> "api.audible.co.jp"
        "in" -> "api.audible.in"
        else -> "api.audible.com"
    }

    private fun get(url: okhttp3.HttpUrl): JSONObject? = runCatching {
        val req = Request.Builder().url(url).header("User-Agent", "Kitzi/1.0").build()
        client.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) return@use null
            resp.body?.string()?.let { JSONObject(it) }
        }
    }.getOrNull()

    private fun lookupByAsin(asin: String, region: String): JSONObject? {
        val url = "https://${host(region)}/1.0/catalog/products/$asin".toHttpUrl()
            .newBuilder().addQueryParameter("response_groups", GROUPS).build()
        return get(url)?.optJSONObject("product")
    }

    private fun searchBestMatch(
        title: String,
        author: String?,
        durationMs: Long?,
        region: String,
    ): JSONObject? {
        if (title.isBlank()) return null
        val queries = queryVariants(title)
        val matchTitles = queries.map(::norm).filter { it.isNotEmpty() }.toSet()

        for (q in queries) {
            var products = searchProducts(q, author, region)
            if (products.isEmpty() && !author.isNullOrEmpty()) {
                products = searchProducts(q, null, region)
            }
            if (products.isEmpty()) continue
            pickBest(products, matchTitles, author, durationMs)?.let { return it }
        }
        return null
    }

    private fun searchProducts(title: String, author: String?, region: String): List<JSONObject> {
        val builder = "https://${host(region)}/1.0/catalog/products".toHttpUrl().newBuilder()
            .addQueryParameter("title", title)
            .addQueryParameter("num_results", "10")
            .addQueryParameter("products_sort_by", "Relevance")
            .addQueryParameter("response_groups", GROUPS)
        if (!author.isNullOrEmpty()) builder.addQueryParameter("author", author)
        val arr = get(builder.build())?.optJSONArray("products") ?: return emptyList()
        return (0 until arr.length()).mapNotNull { arr.optJSONObject(it) }
    }

    private fun pickBest(
        products: List<JSONObject>,
        matchTitles: Set<String>,
        author: String?,
        durationMs: Long?,
    ): JSONObject? {
        val wantMinutes = durationMs?.let { it / 60000.0 }
        val wantAuthor = author?.takeIf { it.isNotEmpty() }?.let(::norm)

        var best: JSONObject? = null
        var bestScore = 0.0
        for (p in products) {
            val pTitle = norm(p.optString("title"))
            if (pTitle.isEmpty()) continue
            val mins = p.opt("runtime_length_min").let { (it as? Number)?.toDouble() }

            val titleSim = matchTitles.maxOfOrNull { similarity(it, pTitle) } ?: 0.0
            if (titleSim < 0.8) continue

            var durOk = false
            if (wantMinutes != null && mins != null && mins > 0) {
                val durDiff = abs(mins - wantMinutes) / wantMinutes
                if (durDiff > 0.08) continue
                durOk = true
            }

            var authorOk = false
            if (wantAuthor != null) {
                val authors = p.optJSONArray("authors")?.let { a ->
                    (0 until a.length()).map { i ->
                        val el = a.opt(i)
                        norm(if (el is JSONObject) el.optString("name") else el.toString())
                    }
                } ?: emptyList()
                authorOk = authors.any { it.isNotEmpty() && similarity(it, wantAuthor) >= 0.5 }
                if (!authorOk && !durOk) continue
            }

            if (!durOk && !authorOk && titleSim < 0.92) continue

            val dist = p.optJSONObject("rating")?.optJSONObject("overall_distribution")
            val hasRating = dist != null && dist.has("num_ratings")
            val score = titleSim + (if (durOk) 0.25 else 0.0) +
                (if (authorOk) 0.25 else 0.0) + (if (hasRating) 0.1 else 0.0)
            if (score > bestScore) {
                bestScore = score
                best = p
            }
        }
        return best
    }

    // === matching helpers ===

    private fun queryVariants(title: String): List<String> {
        val out = LinkedHashSet<String>()
        fun add(s: String) { s.trim().takeIf { it.isNotEmpty() }?.let { out.add(it) } }

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
        var s = t
        s = s.replace(Regex("[\\(\\[\\{].*?[\\)\\]\\}]"), " ")
        s = s.replace(Regex("(?i)[-–—:,]?\\s*\\b(book|bk|vol|volume|part|episode|ep)\\b\\.?\\s*\\d+"), " ")
        s = s.replace(Regex("[-–—#]\\s*\\d+\\s*$"), " ")
        s = s.replace(Regex("\\s+"), " ").trim()
        s = s.trim(' ', '-', '–', '—', ':', ',')
        return s.ifEmpty { t.trim() }
    }

    private fun norm(s: String): String {
        var t = s.lowercase()
        val colon = t.indexOf(':')
        if (colon > 3) t = t.substring(0, colon)
        t = t.replace(Regex("\\(.*?\\)"), " ")
            .replace("unabridged", " ")
            .replace("abridged", " ")
            .replace(Regex("[^a-z0-9 ]"), " ")
            .replace(Regex("\\s+"), " ")
            .trim()
        return t
    }

    /** Token-set Jaccard similarity (0..1). */
    private fun similarity(a: String, b: String): Double {
        if (a.isEmpty() || b.isEmpty()) return 0.0
        if (a == b) return 1.0
        val sa = a.split(' ').filter { it.isNotEmpty() }.toSet()
        val sb = b.split(' ').filter { it.isNotEmpty() }.toSet()
        if (sa.isEmpty() || sb.isEmpty()) return 0.0
        val inter = sa.intersect(sb).size
        val union = sa.union(sb).size
        return inter.toDouble() / union
    }
}
