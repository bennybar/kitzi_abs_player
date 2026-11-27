package com.bennybar.kitzi.data.audible

import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.data.model.arr
import com.bennybar.kitzi.data.model.obj
import com.bennybar.kitzi.data.model.str

/**
 * A book's series as Audible has them, saved to the server: missing ones are
 * added, and a series whose name or number differs from Audible's is made to
 * match. Series the server has that Audible doesn't list (a collection of your
 * own) are kept.
 */
object SeriesSync {
    data class Entry(val name: String, val sequence: String?)

    /** What would change for a book: the server's series now, and after. */
    data class Change(val before: List<Entry>, val after: List<Entry>) {
        /** "The Titan Trilogy #1", or "Expanse #3 → The Expanse #3". */
        val summary: String
            get() {
                val label = { e: Entry -> e.sequence?.let { "${e.name} #$it" } ?: e.name }
                val gone = before.filter { it !in after }
                val new = after.filter { it !in before }
                if (gone.isEmpty()) return new.joinToString(", ", transform = label)
                return gone.joinToString(", ", transform = label) + " → " + new.joinToString(", ", transform = label)
            }
    }

    /**
     * The server's series made to match Audible's: each of Audible's replaces the
     * server's one with a similar name (its name and number from Audible), or, when
     * both have just one, the server's one; else it's added.
     */
    fun merge(server: List<Entry>, audible: List<Entry>): List<Entry> {
        val out = server.toMutableList()
        val used = HashSet<Int>()
        for (a in audible) {
            val want = AudibleMatch.norm(a.name)
            val i = out.indices.firstOrNull { it !in used && AudibleMatch.norm(out[it].name) == want }
                ?: out.indices.firstOrNull { it !in used && AudibleMatch.similar(AudibleMatch.norm(out[it].name), want) }
                ?: if (server.size == 1 && audible.size == 1) 0 else null
            if (i != null) {
                out[i] = Entry(a.name, a.sequence ?: out[i].sequence)
                used += i
            } else {
                out += a
                used += out.lastIndex
            }
        }
        return out
    }

    /**
     * The book's series as the library list gives them: one, or several packed into
     * one string ("The Dune Sequence #1, DUNE: Legends of Dune #1").
     */
    fun entries(b: Book): List<Entry> {
        val s = b.series ?: return emptyList()
        val full = s + (b.seriesSequence?.let { n -> " #" + if (n % 1.0 == 0.0) n.toLong().toString() else n.toString() } ?: "")
        val parts = full.split(", ")
        // Several only when each (but the last) ends in its number: a comma may
        // also be part of a name.
        val several = parts.size > 1 && parts.dropLast(1).all { NUMBER.containsMatchIn(it) }
        return (if (several) parts else listOf(full)).map { p ->
            val m = NUMBER.find(p) ?: return@map Entry(p, null)
            Entry(p.substring(0, m.range.first).trim(), m.groupValues[1])
        }
    }

    private val NUMBER = Regex("""\s*#\s*([0-9][0-9.\-–]*)$""")

    /**
     * Audible's series for each of these ASINs. Books Audible doesn't put in a series
     * map to an empty list. An edition in another language than the library's is
     * left out: its series is the translation's ("La Torre Oscura"), numbered its
     * own way.
     */
    private suspend fun audibleSeries(asins: List<String>, language: String): Map<String, List<Entry>> {
        val out = HashMap<String, List<Entry>>()
        for (p in AudibleCatalog.products(asins, "series,product_attrs")) {
            val asin = p["asin"].str() ?: continue
            if (p["language"].str()?.lowercase()?.let { it != language } == true) continue
            out[asin.uppercase()] = p["series"].arr().orEmpty().mapNotNull { el ->
                val s = el.obj() ?: return@mapNotNull null
                s["title"].str()?.let { Entry(it, s["sequence"].str()?.trim()) }
            }
        }
        return out
    }

    /** Each book's saved Audible match. */
    private suspend fun matches() = runCatching { Services.audibleDao().all() }.getOrDefault(emptyList())

    /** The library's main language on Audible: the one the radar settled on, else most of its matches'. */
    private fun mainLanguage(matches: List<com.bennybar.kitzi.data.db.AudibleEntity>): String =
        Services.prefs.getString("radar_language")?.takeIf { it.isNotEmpty() }
            ?: matches.mapNotNull { it.language?.lowercase() }.groupingBy { it }.eachCount().maxByOrNull { it.value }?.key ?: "english"

    /**
     * The library's books whose series differ from Audible's (only books whose
     * Audible id is known: the server's, or one matched before). From the books as
     * listed (their first series); the full list is read again before saving.
     */
    suspend fun check(books: List<Book>): Map<String, Change> {
        val matches = matches()
        val known = matches.associate { it.itemId to it.asin }
        val asinOf = books.mapNotNull { b ->
            (b.asin ?: known[b.id]?.takeIf { it.isNotEmpty() })?.let { b.id to it.uppercase() }
        }.toMap()
        val series = audibleSeries(asinOf.values.distinct(), mainLanguage(matches))
        return books.mapNotNull { b ->
            val audible = asinOf[b.id]?.let { series[it] }?.takeIf { it.isNotEmpty() } ?: return@mapNotNull null
            val server = entries(b)
            val after = merge(server, audible)
            if (same(server, after)) null else b.id to Change(server, after)
        }.toMap()
    }

    /** One book, looked up now (its Audible match found if need be). Null: nothing to change, or Audible has no series for it. */
    suspend fun check(book: Book): Change? {
        val asin = AudibleRatingService.asin(book)?.uppercase() ?: return null
        val audible = audibleSeries(listOf(asin), mainLanguage(matches()))[asin]?.takeIf { it.isNotEmpty() } ?: return null
        val server = Services.books.serverSeries(book.id)?.map { it.second } ?: return null
        val after = merge(server, audible)
        return if (same(server, after)) null else Change(server, after)
    }

    /** Saves Audible's series for the book to the server. Null, or why it couldn't. */
    suspend fun apply(book: Book): String? {
        val asin = AudibleRatingService.asin(book)?.uppercase() ?: return "Audible doesn't have ${book.title}."
        val audible = audibleSeries(listOf(asin), mainLanguage(matches()))[asin]?.takeIf { it.isNotEmpty() }
            ?: return "Audible doesn't list ${book.title} in a series (in your library's language)."
        val server = Services.books.serverSeries(book.id) ?: return "Couldn't reach the server."
        val after = merge(server.map { it.second }, audible)
        if (same(server.map { it.second }, after)) return null
        // A series the server has under the same name keeps its id; a new or renamed
        // one goes by name (the server finds it, or makes it). Renaming by id would
        // rename the series for every book in it.
        return Services.books.saveSeries(book.id, after.map { e -> server.firstOrNull { it.second.name == e.name }?.first to e })
    }

    /** The same series and numbers ("3" and "3.0" are the same number). */
    internal fun same(a: List<Entry>, b: List<Entry>): Boolean =
        a.size == b.size && a.zip(b).all { (x, y) ->
            val (p, q) = x.sequence?.toDoubleOrNull() to y.sequence?.toDoubleOrNull()
            x.name == y.name && (if (p != null && q != null) p == q else x.sequence == y.sequence)
        }
}
