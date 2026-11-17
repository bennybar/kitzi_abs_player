package com.bennybar.kitzi.data.services

import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.data.model.arr
import com.bennybar.kitzi.data.model.int
import com.bennybar.kitzi.data.model.obj
import com.bennybar.kitzi.data.model.str
import com.bennybar.kitzi.data.net.SessionStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.Cookie
import okhttp3.CookieJar
import okhttp3.FormBody
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.time.Instant
import java.util.concurrent.TimeUnit

/** A book found by Shelfarr's search, ready to be requested. */
data class ShelfarrBook(val workId: String, val title: String, val author: String?, val year: Int?, val coverUrl: String?)

data class ShelfarrRequest(
    val id: Int,
    val status: String,
    val title: String,
    val author: String?,
    val bookType: String?,
    val workId: String?,
    val issue: String?,
    val createdMs: Long?,
    val updatedMs: Long?,
    val requestedBy: String?,
    val createdVia: String?,
    val externalSource: String?,
) {
    val isCompleted get() = status == "completed"
    /** Still moving on the server: worth checking again soon. */
    val isWorking get() = status in setOf("pending", "searching", "downloading", "processing")

    val statusLabel: String
        get() = when (status) {
            "not_found" -> "Not Found"
            "awaiting_purchase" -> "Needs Purchase"
            else -> status.replaceFirstChar { it.uppercase() }
        }

    /** What the status means, in a sentence. */
    val statusDetail: String
        get() = when (status) {
            "pending" -> "Waiting in Shelfarr's queue."
            "searching" -> "Shelfarr is looking for a release."
            "not_found" -> "No release found yet. Shelfarr will try again later."
            "awaiting_purchase" -> "Only available to buy from a store."
            "downloading" -> "Downloading now."
            "processing" -> "Downloaded, and being added to your library."
            "completed" -> "Delivered to your library."
            "failed" -> "This request failed or was cancelled."
            else -> ""
        }

    /** Where the request was made. */
    val source: String?
        get() {
            if (externalSource == "kitzi") return "Kitzi"
            return when (createdVia) {
                "web" -> "Shelfarr website"
                "api" -> externalSource?.let { if (it == "api") "API" else it.replaceFirstChar { c -> c.uppercase() } } ?: "API"
                else -> createdVia?.replaceFirstChar { it.uppercase() }
            }
        }

    /** The list doesn't carry covers, but an Open Library work id gives one. */
    val coverUrl: String?
        get() = workId?.takeIf { it.startsWith("openlibrary:") }
            ?.let { "https://covers.openlibrary.org/w/olid/${it.removePrefix("openlibrary:")}-M.jpg?default=false" }
}

/** What Open Library knows about a requested book (Shelfarr's API only has its title and author). */
data class ShelfarrBookInfo(val description: String?, val subjects: List<String>, val firstPublished: String?, val coverUrl: String?)

class ServiceFailure(message: String) : Exception(message)

/**
 * The optional Shelfarr server (https://github.com/Pedro-Revez-Silva/shelfarr):
 * search for audiobooks, request them, follow the requests. Its address, API token
 * and (optional) website login are kept encrypted.
 */
object Shelfarr {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val api = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
    private val plain = OkHttpClient.Builder().callTimeout(20, TimeUnit.SECONDS).build()

    /** The website's login cookie (for deleting); dropped with the session. */
    private class Jar : CookieJar {
        val cookies = mutableListOf<Cookie>()
        override fun saveFromResponse(url: HttpUrl, cookies: List<Cookie>) {
            synchronized(this) { this.cookies.removeAll { c -> cookies.any { it.name == c.name } }; this.cookies += cookies }
        }
        override fun loadForRequest(url: HttpUrl): List<Cookie> = synchronized(this) { cookies.filter { it.matches(url) } }
    }
    private var web = newWeb()
    private fun newWeb() = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).cookieJar(Jar()).followRedirects(true).build()

    private val store get() = Services.session
    val baseUrl: String? get() = store.secret("shelfarr_url")
    val token: String? get() = store.secret("shelfarr_token")
    val username: String? get() = store.secret("shelfarr_username")
    val password: String? get() = store.secret("shelfarr_password")
    val configured: Boolean get() = baseUrl != null && token != null

    private val _requests = MutableStateFlow<List<ShelfarrRequest>>(emptyList())
    val requests: StateFlow<List<ShelfarrRequest>> = _requests

    /** Checks the address and token (and the login, if given), and keeps them if they work. */
    suspend fun connect(url: String, token: String, username: String = "", password: String = "") = withContext(Dispatchers.IO) {
        val base = SessionStore.normalizeBaseUrl(url)
        val t = token.trim()
        val answer = call("/api/v1/requests?limit=1", base = base, token = t)
        if ((answer as? JsonObject)?.get("requests") == null) throw ServiceFailure("That doesn't look like a Shelfarr server.")
        val user = username.trim()
        val hasLogin = user.isNotEmpty() && password.isNotEmpty()
        web = newWeb()
        if (hasLogin && !webLogin(base, user, password)) throw ServiceFailure("Shelfarr rejected the username or password.")
        store.setSecret("shelfarr_url", base)
        store.setSecret("shelfarr_token", t)
        setLogin(if (hasLogin) user else null, if (hasLogin) password else null)
    }

    fun clear() {
        _requests.value = emptyList()
        web = newWeb()
        store.setSecret("shelfarr_url", null)
        store.setSecret("shelfarr_token", null)
        setLogin(null, null)
    }

    private fun setLogin(username: String?, password: String?) {
        store.setSecret("shelfarr_username", username)
        store.setSecret("shelfarr_password", password)
    }

    suspend fun search(query: String): List<ShelfarrBook> = withContext(Dispatchers.IO) {
        val q = java.net.URLEncoder.encode(query, "UTF-8")
        items(call("/api/v1/search?q=$q&limit=20")).mapNotNull { r ->
            ShelfarrBook(r["work_id"].str() ?: return@mapNotNull null, r["title"].str() ?: return@mapNotNull null,
                r["author"].str(), r["year"].int(), r["cover_url"].str())
        }
    }

    suspend fun refresh() = withContext(Dispatchers.IO) {
        val answer = call("/api/v1/requests?limit=100")
        _requests.value = (answer as? JsonObject)?.get("requests").arr().orEmpty().mapNotNull { el ->
            val r = el.obj() ?: return@mapNotNull null
            val book = r["book"].obj() ?: return@mapNotNull null
            ShelfarrRequest(
                id = r["id"].int() ?: return@mapNotNull null,
                status = r["status"].str() ?: return@mapNotNull null,
                title = book["title"].str() ?: return@mapNotNull null,
                author = book["author"].str(),
                bookType = book["book_type"].str(),
                workId = book["work_id"].str(),
                issue = r["issue_description"].str(),
                createdMs = r["created_at"].str()?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() },
                updatedMs = r["updated_at"].str()?.let { runCatching { Instant.parse(it).toEpochMilli() }.getOrNull() },
                requestedBy = r["user"].obj()?.get("username").str(),
                createdVia = r["request"].obj()?.get("created_via").str(),
                externalSource = r["request"].obj()?.get("external_source").str(),
            )
        }
    }

    /** Starts a real search and download on the server. */
    suspend fun request(book: ShelfarrBook) = withContext(Dispatchers.IO) {
        val body = buildJsonObject {
            put("work_id", book.workId); put("book_type", "audiobook"); put("title", book.title); put("external_source", "kitzi")
            book.author?.let { put("author", it) }
            book.year?.let { put("year", it) }
            book.coverUrl?.let { put("cover_url", it) }
        }
        call("/api/v1/requests", method = "POST", body = body)
        refresh()
    }

    /**
     * Removes the request from Shelfarr. Library files are kept. The API can only
     * mark a request failed, so this goes through the website, signed in.
     */
    suspend fun delete(request: ShelfarrRequest) = withContext(Dispatchers.IO) {
        val base = baseUrl
        val user = username
        val pass = password
        if (base == null || user == null || pass == null) {
            throw ServiceFailure("Add your Shelfarr username and password in Settings to delete requests.")
        }
        val page = "$base/requests/${request.id}"
        var (html, final) = fetch(page)
        if (final?.encodedPath == "/session/new") {
            if (!webLogin(base, user, pass)) {
                // Trying a bad password again would lock the account.
                setLogin(user, null)
                throw ServiceFailure("Shelfarr rejected the password. Enter it again in Settings.")
            }
            fetch(page).let { html = it.first; final = it.second }
        }
        val csrf = value(html, "name=\"csrf-token\" content=\"")
            ?: throw ServiceFailure("Couldn't delete: Shelfarr's website didn't answer as expected.")
        fetch(page, method = "DELETE", csrf = csrf)
        // Only the server's own list says whether it's really gone.
        refresh()
        if (_requests.value.any { it.id == request.id }) throw ServiceFailure("Shelfarr didn't delete this request. It may be busy; try again later.")
    }

    /** Null if Open Library doesn't have the book or can't be reached. */
    suspend fun bookInfo(request: ShelfarrRequest): ShelfarrBookInfo? = withContext(Dispatchers.IO) {
        var work = request.workId?.takeIf { it.startsWith("openlibrary:") }?.removePrefix("openlibrary:")
        if (work == null) {
            // Other sources' ids (Hardcover) mean nothing there: find it by title and author.
            val url = "https://openlibrary.org/search.json".toHttpUrl().newBuilder()
                .addQueryParameter("title", request.title)
                .apply { request.author?.let { addQueryParameter("author", it) } }
                .addQueryParameter("limit", "1").addQueryParameter("fields", "key").build()
            work = openLibrary(url.toString())?.get("docs").arr()?.firstOrNull().obj()?.get("key").str()?.removePrefix("/works/")
        }
        val w = work?.let { openLibrary("https://openlibrary.org/works/$it.json") } ?: return@withContext null
        // The description is a string or {type, value}; anything after a rule is links and credits.
        val text = (w["description"].str() ?: w["description"].obj()?.get("value").str())?.split("\n----")?.first()?.trim()
        val seen = HashSet<String>()
        val subjects = w["subjects"].arr().orEmpty().mapNotNull { it.str() }
            .filter { !it.contains(":") && !it.contains(",") && seen.add(it.lowercase()) }.take(6)
        val cover = w["covers"].arr().orEmpty().mapNotNull { it.int() }.firstOrNull { it > 0 }
        ShelfarrBookInfo(text, subjects, w["first_publish_date"].str(), cover?.let { "https://covers.openlibrary.org/b/id/$it-L.jpg" })
    }

    private fun openLibrary(url: String): JsonObject? = runCatching {
        plain.newCall(Request.Builder().url(url).build()).execute().use { r ->
            if (!r.isSuccessful) null else json.parseToJsonElement(r.body?.string().orEmpty()) as? JsonObject
        }
    }.getOrNull()

    /** False if the website turned down the username or password. */
    private fun webLogin(base: String, username: String, password: String): Boolean {
        val (html, _) = fetch("$base/session/new")
        val token = value(html, "name=\"authenticity_token\" value=\"")
            ?: throw ServiceFailure("Couldn't sign in: Shelfarr's website didn't answer as expected.")
        val form = FormBody.Builder().add("authenticity_token", token).add("username", username).add("password", password).build()
        val (_, final) = fetch("$base/session", method = "POST", form = form)
        if (final?.encodedPath?.contains("verify_otp") == true) {
            throw ServiceFailure("Deleting requests doesn't work with two-factor sign-in on the Shelfarr account.")
        }
        return final?.encodedPath != "/session/new"
    }

    /** A page of the website, following redirects: its text and where it ended up. */
    private fun fetch(url: String, method: String = "GET", form: FormBody? = null, csrf: String? = null): Pair<String, HttpUrl?> {
        val req = Request.Builder().url(url).header("Accept", "text/html").apply {
            csrf?.let { header("X-CSRF-Token", it) }
            when {
                form != null -> method(method, form)
                method == "DELETE" -> delete()
                else -> get()
            }
        }.build()
        return try {
            web.newCall(req).execute().use { r -> (r.body?.string().orEmpty()) to r.request.url }
        } catch (e: java.io.IOException) {
            throw ServiceFailure("Couldn't reach Shelfarr. Check the address and your connection.")
        }
    }

    /** The text from just after [marker] up to the next quote. */
    private fun value(html: String, marker: String): String? {
        val start = html.indexOf(marker).takeIf { it >= 0 }?.plus(marker.length) ?: return null
        val end = html.indexOf('"', start).takeIf { it >= 0 } ?: return null
        return html.substring(start, end)
    }

    private fun items(el: JsonElement?): List<JsonObject> = when (el) {
        is JsonArray -> el.mapNotNull { it.obj() }
        is JsonObject -> listOf("results", "items", "books", "data").firstNotNullOfOrNull { el[it] as? JsonArray }?.mapNotNull { it.obj() }.orEmpty()
        else -> emptyList()
    }

    private fun call(path: String, method: String = "GET", body: JsonObject? = null, base: String? = null, token: String? = null): JsonElement? {
        val b = base ?: baseUrl
        val t = token ?: this.token
        if (b == null || t == null) throw ServiceFailure("Shelfarr isn't set up.")
        val req = Request.Builder().url(b + path)
            .header("Authorization", "Bearer $t").header("Accept", "application/json")
            .apply { if (body != null) method(method, body.toString().toRequestBody("application/json".toMediaType())) else method(method, null) }
            .build()
        val (code, text) = try {
            api.newCall(req).execute().use { it.code to it.body?.string() }
        } catch (e: java.io.IOException) {
            throw ServiceFailure("Couldn't reach Shelfarr. Check the address and your connection.")
        }
        val parsed = text?.takeIf { it.isNotBlank() }?.let { runCatching { json.parseToJsonElement(it) }.getOrNull() }
        if (code == 401) throw ServiceFailure("Shelfarr rejected the API token.")
        if (code !in 200..299) {
            val first = (parsed as? JsonObject)?.get("errors").arr()?.firstOrNull()?.let { (it as? JsonPrimitive)?.content }
            throw ServiceFailure(first ?: "Shelfarr had a problem ($code).")
        }
        return parsed
    }

    /**
     * The library's copy of a book known only by title and author. Files are named
     * many ways ("Revelation Space (Unabridged)", "World War Z: An Oral History…",
     * the narrator as a second author), so this compares the title's parts and the
     * first author's surname.
     */
    fun matching(books: List<Book>, title: String, author: String?): Book? {
        fun parts(t: String) = java.text.Normalizer.normalize(t.replace(Regex("\\s*\\([^)]*\\)"), "").replace("’", "'"), java.text.Normalizer.Form.NFD)
            .replace(Regex("\\p{M}"), "").lowercase().replace(" - ", ":").split(":").map { it.trim() }
        val wanted = parts(title).firstOrNull() ?: return null
        val surname = author?.split(",")?.firstOrNull()?.trim()?.split(" ")?.lastOrNull()
        return books.firstOrNull { b ->
            (surname == null || b.author?.contains(surname, ignoreCase = true) == true) && wanted in parts(b.title)
        }
    }
}

/**
 * The optional Achew server (https://github.com/SirGibblets/achew), which repairs a
 * book's chapters on Audiobookshelf. Kitzi starts a book there and shows its
 * website; the address and login are kept encrypted.
 */
object Achew {
    private val json = Json { ignoreUnknownKeys = true; isLenient = true }
    private val client = OkHttpClient.Builder().callTimeout(30, TimeUnit.SECONDS).build()
    private val store get() = Services.session
    val baseUrl: String? get() = store.secret("achew_url")
    val username: String? get() = store.secret("achew_username")
    val password: String? get() = store.secret("achew_password")
    val configured get() = baseUrl != null

    /** Checks the address and login against the server, and keeps them if they work. */
    suspend fun connect(url: String, username: String, password: String) = withContext(Dispatchers.IO) {
        val base = SessionStore.normalizeBaseUrl(url)
        val user = username.trim()
        val status = call("/api/status", base = base, username = user, password = password)
        if (status?.get("abs_configured") == null) throw ServiceFailure("That doesn't look like an Achew server.")
        store.setSecret("achew_url", base)
        store.setSecret("achew_username", user)
        store.setSecret("achew_password", password)
    }

    fun clear() {
        store.setSecret("achew_url", null)
        store.setSecret("achew_username", null)
        store.setSecret("achew_password", null)
    }

    /** The book Achew is in the middle of, if any (id, title). It works on one book at a time. */
    suspend fun currentJob(): Pair<String, String>? = withContext(Dispatchers.IO) {
        val status = call("/api/status")
        val step = status?.get("step").str() ?: "idle"
        if ((status?.get("has_pipeline") as? JsonPrimitive)?.content != "true" || step in setOf("idle", "completed")) return@withContext null
        val state = call("/api/pipeline/state") ?: return@withContext null
        val id = state["item_id"].str() ?: return@withContext null
        id to (state["book"].obj()?.get("media").obj()?.get("metadata").obj()?.get("title").str() ?: "another book")
    }

    /**
     * Makes this the book Achew is working on, replacing any other: it refuses a new
     * book while it holds one, even a finished one.
     */
    suspend fun start(itemId: String) = withContext(Dispatchers.IO) {
        val check = call("/api/validate-item", body = buildJsonObject { put("item_id", itemId) })
        if ((check?.get("valid") as? JsonPrimitive)?.content != "true") {
            throw ServiceFailure(check?.get("error_message").str() ?: "Achew can't find this book.")
        }
        if ((call("/api/status")?.get("has_pipeline") as? JsonPrimitive)?.content == "true") call("/api/pipeline", method = "DELETE")
        call("/api/pipeline", body = buildJsonObject { put("item_id", itemId) })
    }

    private fun call(path: String, method: String? = null, body: JsonObject? = null, base: String? = null, username: String? = null, password: String? = null): JsonObject? {
        val b = base ?: baseUrl ?: throw ServiceFailure("Achew isn't set up.")
        val login = okhttp3.Credentials.basic(username ?: this.username.orEmpty(), password ?: this.password.orEmpty())
        val req = Request.Builder().url(b + path).header("Authorization", login).apply {
            when {
                body != null -> post(body.toString().toRequestBody("application/json".toMediaType()))
                method != null -> method(method, null)
            }
        }.build()
        val (code, text) = try {
            client.newCall(req).execute().use { it.code to it.body?.string() }
        } catch (e: java.io.IOException) {
            throw ServiceFailure("Couldn't reach Achew. Check the address and your connection.")
        }
        val parsed = text?.let { runCatching { json.parseToJsonElement(it) as? JsonObject }.getOrNull() }
        if (code == 401) throw ServiceFailure("Achew rejected the username or password.")
        if (code !in 200..299) throw ServiceFailure(parsed?.get("detail").str() ?: "Achew had a problem ($code).")
        return parsed
    }
}
