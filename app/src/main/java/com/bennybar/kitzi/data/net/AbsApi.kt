package com.bennybar.kitzi.data.net

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * The authenticated `/api/...` surface. Auth, refresh-on-401 and the custom
 * headers are handled by the interceptor on [client], so nothing here deals with
 * tokens.
 *
 * Responses are read as loose JSON rather than @Serializable classes: ABS moves
 * fields between shapes across versions (`results` vs `items` vs a bare array),
 * and the Flutter client leans on that tolerance heavily.
 */
class AbsApi(
    private val client: OkHttpClient,
    private val session: SessionStore,
) {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }

    class HttpError(val code: Int) : Exception("HTTP $code")

    /** A page of results plus the ETag the server gave us for it. */
    data class Page(val items: List<JsonObject>, val etag: String?, val notModified: Boolean)

    private fun base(): String = session.baseUrl ?: error("Base URL not set")

    private fun get(path: String, headers: Map<String, String> = emptyMap()): Pair<Int, String?> {
        val request = Request.Builder()
            .url(base() + path)
            .apply { headers.forEach { (k, v) -> header(k, v) } }
            .get()
            .build()
        return client.newCall(request).execute().use { it.code to it.body?.string() }
    }

    private fun parse(body: String?): JsonElement? =
        body?.takeIf { it.isNotEmpty() }?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() }

    /** ABS returns the list under any of these keys, or as a bare array. */
    private fun itemsOf(el: JsonElement?): List<JsonObject> = when (el) {
        is JsonArray -> el.mapNotNull { it as? JsonObject }
        is JsonObject -> listOf(
            "results", "items", "libraryItems", "data", "libraries", "series", "books", "authors",
        )
            .firstNotNullOfOrNull { el[it] as? JsonArray }
            ?.mapNotNull { it as? JsonObject }
            .orEmpty()
        else -> emptyList()
    }

    fun libraries(): List<JsonObject> {
        val (code, body) = get("/api/libraries")
        if (code != 200) throw HttpError(code)
        return itemsOf(parse(body))
    }

    /**
     * A page of library items.
     *
     * [etag] is passed only when the caller wants a conditional request. Pull-to-
     * refresh must pass null — see BooksRepository.refresh.
     */
    /** How to ask the server for a page: some ABS servers/proxies honour only one. */
    enum class Paging { PAGE, OFFSET, SKIP }

    fun libraryItems(
        libraryId: String,
        page: Int,
        limit: Int,
        sort: String,
        desc: Boolean,
        etag: String? = null,
        paging: Paging = Paging.PAGE,
    ): Page {
        // `page` is 1-based; offset/skip are 0-based item counts. Some servers ignore
        // `page` and return the first page every time — the caller falls back through
        // the other two (see BooksRepository.syncAll), mirroring the Flutter app.
        val pagingParam = when (paging) {
            Paging.PAGE -> "page=$page"
            Paging.OFFSET -> "offset=${(page - 1).coerceAtLeast(0) * limit}"
            Paging.SKIP -> "skip=${(page - 1).coerceAtLeast(0) * limit}"
        }
        val path = "/api/libraries/$libraryId/items" +
            "?limit=$limit&$pagingParam&sort=$sort&desc=${if (desc) 1 else 0}"

        val request = Request.Builder()
            .url(base() + path)
            .apply { if (etag != null) header("If-None-Match", etag) }
            .get()
            .build()

        return client.newCall(request).execute().use { resp ->
            when (resp.code) {
                304 -> Page(emptyList(), etag, notModified = true)
                200 -> Page(itemsOf(parse(resp.body?.string())), resp.header("ETag"), notModified = false)
                else -> throw HttpError(resp.code)
            }
        }
    }

    fun item(itemId: String): JsonObject? {
        val (code, body) = get("/api/items/$itemId")
        if (code == 404) return null
        if (code != 200) throw HttpError(code)
        val root = parse(body)
        return (root as? JsonObject)?.let { it["item"] as? JsonObject ?: it }
    }

    fun search(libraryId: String, query: String): List<JsonObject> {
        val encoded = java.net.URLEncoder.encode(query, "UTF-8")
        val (code, body) = get("/api/libraries/$libraryId/search?q=$encoded")
        if (code != 200) throw HttpError(code)
        // Results come back as { book: [ { libraryItem: {...} }, ... ] }
        val root = parse(body) as? JsonObject ?: return emptyList()
        return (root["book"] as? JsonArray).orEmpty().mapNotNull { entry ->
            (entry as? JsonObject)?.let { it["libraryItem"] as? JsonObject ?: it }
        }
    }

    fun series(libraryId: String, page: Int, limit: Int = 100): List<JsonObject> {
        // NB: this endpoint pages from 0, unlike /items which pages from 1.
        val path = "/api/libraries/$libraryId/series" +
            "?sort=name&desc=0&filter=all&limit=$limit&page=$page&minified=1" +
            "&include=rssfeed,numEpisodesIncomplete,share"
        val (code, body) = get(path)
        if (code != 200) throw HttpError(code)
        return itemsOf(parse(body))
    }

    fun booksInSeries(libraryId: String, seriesId: String): List<JsonObject> {
        val (code, body) = get("/api/libraries/$libraryId/series/$seriesId")
        if (code != 200) throw HttpError(code)
        return itemsOf(parse(body))
    }

    fun authors(libraryId: String): List<JsonObject> {
        val (code, body) = get("/api/libraries/$libraryId/authors")
        if (code == 200) return itemsOf(parse(body))
        val (code2, body2) = get("/api/libraries/$libraryId/bookshelf/authors")
        if (code2 != 200) throw HttpError(code2)
        return itemsOf(parse(body2))
    }

    fun libraryStats(libraryId: String): JsonObject? {
        val (code, body) = get("/api/libraries/$libraryId/stats")
        if (code != 200) return null
        return parse(body) as? JsonObject
    }

    /** `/api/me` carries mediaProgress[] and bookmarks[] — one call feeds both. */
    fun me(): JsonObject? {
        val (code, body) = get("/api/me")
        if (code != 200) throw HttpError(code)
        return parse(body) as? JsonObject
    }

    fun listeningStats(): JsonObject? {
        val (code, body) = get("/api/me/listening-stats")
        if (code != 200) return null
        return parse(body) as? JsonObject
    }
}
