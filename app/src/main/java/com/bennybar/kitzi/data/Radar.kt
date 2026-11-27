package com.bennybar.kitzi.data

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationCompat
import com.bennybar.kitzi.MainActivity
import com.bennybar.kitzi.R
import com.bennybar.kitzi.data.audible.AudibleBook
import com.bennybar.kitzi.data.audible.AudibleCatalog
import com.bennybar.kitzi.data.audible.LibraryMatcher
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.services.Shelfarr
import com.bennybar.kitzi.data.services.ShelfarrRequest
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.coroutines.coroutineContext

/** A book on Audible that's new or coming, and why it's here. Stored as on iOS. */
@Serializable
data class RadarFind(
    val asin: String,
    val title: String,
    val author: String? = null,
    val cover: String? = null,
    val releaseDate: String? = null,
    /** "New from Andy Weir", "Book 4 of The Expanse", "Narrated by Ray Porter". */
    val reason: String,
    /** Seconds since 1970. */
    val foundAt: Double,
    /** Notified as out (after being notified as coming). */
    val announcedOut: Boolean = false,
) {
    val releaseDay: LocalDate? get() = releaseDate?.let { runCatching { LocalDate.parse(it.take(10)) }.getOrNull() }
    fun isUpcoming(today: LocalDate) = releaseDay?.isAfter(today) == true
}

/**
 * Watches for what's new: books just out (or coming) from the library's authors,
 * the next books of its series, and followed narrators (the "radar"); and
 * Shelfarr requests that have arrived. Checked in the background twice a day and
 * when the app opens; each find is notified once.
 */
object Radar {
    const val KEY_ON = "notify_new_releases"
    const val KEY_SHELFARR = "notify_shelfarr_ready"
    const val KEY_NARRATORS = "radar_narrators"

    private val json = Json { ignoreUnknownKeys = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val _finds by lazy {
        MutableStateFlow(
            runCatching { json.decodeFromString<List<RadarFind>>(Services.prefs.getString("radar_finds").orEmpty()) }.getOrDefault(emptyList())
        )
    }
    val finds: StateFlow<List<RadarFind>> get() = _finds
    private val _checking = MutableStateFlow(false)
    val checking: StateFlow<Boolean> = _checking

    /** What a check found and what it notifies. */
    data class Merge(val finds: List<RadarFind>, val fresh: List<RadarFind>, val nowOut: List<RadarFind>)

    /** Runs [checkAll] on its own, so leaving the screen that asked doesn't stop it. */
    fun checkSoon(force: Boolean = false) {
        scope.launch { checkAll(force) }
    }

    /**
     * Both checks, if they're on and due: Shelfarr at most every 3 minutes, the
     * radar at most every 12 hours, or now when [force]. From the 12-hourly worker
     * ([background]) 11 hours, so a run that comes a little early isn't skipped.
     */
    suspend fun checkAll(force: Boolean = false, background: Boolean = false) {
        val prefs = Services.prefs
        if (Services.session.baseUrl == null) return
        val now = System.currentTimeMillis() / 1000.0
        if (prefs.getBoolean(KEY_SHELFARR, false) && (force || now - prefs.getDouble("shelfarr_checked_at", 0.0) > 180)) {
            prefs.putDouble("shelfarr_checked_at", now)
            checkShelfarr()
        }
        if (prefs.getBoolean(KEY_ON, false)) {
            val last = prefs.getDouble("radar_checked_at", 0.0)
            if (force || now - last > (if (background) 11 else 12) * 3600) checkReleases()
        }
    }

    /**
     * Books from the library's authors, its series and followed narrators that
     * came out in the last six weeks or are coming in the next six months, and
     * aren't in the library. Cancelled part way, it isn't marked checked, so it
     * runs again.
     */
    suspend fun checkReleases() {
        if (!_checking.compareAndSet(false, true)) return
        try {
            val prefs = Services.prefs
            val today = LocalDate.now()
            val now = System.currentTimeMillis() / 1000.0
            // The library's language (most of its Audible matches'): an author's newest
            // list is often their old books re-released in translation. Kept once
            // there are enough matches to tell.
            var language = prefs.getString("radar_language").orEmpty()
            if (language.isEmpty()) {
                val langs = runCatching { Services.audibleDao().all() }.getOrDefault(emptyList()).mapNotNull { it.language?.lowercase() }
                language = langs.groupingBy { it }.eachCount().maxByOrNull { it.value }?.key ?: "english"
                if (langs.size >= 20) prefs.putString("radar_language", language)
            }
            val found = LinkedHashMap<String, RadarFind>()
            // A source couldn't be asked: what it found before is kept this time.
            var incomplete = false
            suspend fun add(b: AudibleBook, reason: String) {
                if (b.asin in found || !inWindow(b, language, today) || LibraryMatcher.match(b) != null) return
                found[b.asin] = RadarFind(b.asin, b.title, b.author, b.thumbUrl, b.releaseDate, reason, now)
            }

            // Authors: those with the most books here, and of what's being listened to.
            val books = Services.books.allAudiobooks()
            val weight = HashMap<String, Int>()
            for (b in books) (b.authors.firstOrNull() ?: b.author)?.let { weight[it] = (weight[it] ?: 0) + 1 }
            for (b in Services.books.continueListening()) (b.authors.firstOrNull() ?: b.author)?.let { weight[it] = (weight[it] ?: 0) + 100 }
            val authors = weight.entries.sortedByDescending { it.value }.take(40).map { it.key }
            // Five at a time.
            for (chunk in authors.chunked(5)) {
                coroutineContext.ensureActive()
                val lists = coroutineScope {
                    chunk.map { a -> async { a to runCatching { AudibleCatalog.newest(author = a) }.getOrNull() } }.awaitAll()
                }
                for ((a, list) in lists) {
                    if (list == null) { incomplete = true; continue }
                    for (b in list) if (ownBook(b, a)) add(b, "New from $a")
                }
            }
            for (n in prefs.getStringSet(KEY_NARRATORS).sorted()) {
                coroutineContext.ensureActive()
                val list = runCatching { AudibleCatalog.newest(narrator = n) }.getOrNull()
                if (list == null) { incomplete = true; continue }
                for (b in list) if (b.narrators.any { it.equals(n, ignoreCase = true) }) add(b, "Narrated by $n")
            }
            // Series being listened to or finished: the books after the last one here.
            val started = Services.books.allProgress().values.filter { it.progress > 0 }.map { it.itemId }.toSet()
            val series = books.filter { it.series != null }.groupBy { it.series!!.trim() }
                .filterValues { s -> s.any { it.id in started } }.entries.take(25)
            for ((name, members) in series) {
                coroutineContext.ensureActive()
                val (ref, lang) = runCatching { AudibleCatalog.seriesFor(name, members) }.getOrNull() ?: continue
                val all = runCatching { AudibleCatalog.seriesBooks(ref, lang) }.getOrNull() ?: continue
                val owned = members.mapNotNull { it.seriesSequence }.maxOrNull() ?: 0.0
                for (b in all) {
                    val n = AudibleCatalog.numbers(AudibleCatalog.sequenceLabel(b, ref.asin))
                    if (n.size != 1 || n[0] <= owned) continue
                    add(b, "Book ${if (n[0] % 1.0 == 0.0) n[0].toLong() else n[0]} of $name")
                }
            }

            coroutineContext.ensureActive()
            // The first run just fills the list: no flood of notifications.
            val firstRun = !prefs.contains("radar_seeded")
            val m = merge(_finds.value, found, incomplete, firstRun, today)
            _finds.value = m.finds
            prefs.putString("radar_finds", json.encodeToString(m.finds))
            prefs.putDouble("radar_checked_at", now)
            prefs.putBoolean("radar_seeded", true)
            Notifier.releases(m.fresh, m.nowOut, today)
        } finally {
            _checking.value = false
        }
    }

    /** Out in the last six weeks or in the next six months, in the library's [language]. */
    fun inWindow(b: AudibleBook, language: String, today: LocalDate): Boolean {
        val d = b.releaseDay ?: return false
        if (b.language != null && b.language.lowercase() != language) return false
        return !d.isBefore(today.minusDays(42)) && !d.isAfter(today.plusMonths(6))
    }

    /** The author's own book: a search also finds books "with" them, and anthologies they have one story in. */
    fun ownBook(b: AudibleBook, author: String): Boolean =
        b.authors.size <= 3 && b.authors.any { it.equals(author, ignoreCase = true) }

    /**
     * This check's [found] books against the [previous] finds. New ones are notified,
     * a coming one once more when it's out (not on the [firstRun]). Finds no longer
     * found go (now in the library, or past the window); after an [incomplete] check,
     * the ones it didn't see again stay while still in the window.
     */
    fun merge(previous: List<RadarFind>, found: Map<String, RadarFind>, incomplete: Boolean, firstRun: Boolean, today: LocalDate): Merge {
        val known = previous.associateBy { it.asin }
        val fresh = ArrayList<RadarFind>()
        val nowOut = ArrayList<RadarFind>()
        val merged = ArrayList<RadarFind>()
        for ((asin, f) in found) {
            val old = known[asin]
            if (old == null) {
                val new = f.copy(announcedOut = !f.isUpcoming(today))
                fresh += new
                merged += new
            } else {
                val foundDay = Instant.ofEpochSecond(old.foundAt.toLong()).atZone(ZoneId.systemDefault()).toLocalDate()
                if (!old.announcedOut && !old.isUpcoming(today) && old.releaseDay?.isAfter(foundDay) == true) {
                    val out = old.copy(announcedOut = true)
                    nowOut += out
                    merged += out
                } else merged += old
            }
        }
        if (incomplete) {
            val from = today.minusDays(42)
            merged += previous.filter { it.asin !in found && it.releaseDay?.isBefore(from) == false }
        }
        return if (firstRun) Merge(merged, emptyList(), emptyList()) else Merge(merged, fresh, nowOut)
    }

    /** Shelfarr requests that have arrived since the last check. */
    suspend fun checkShelfarr() {
        if (!Shelfarr.configured || runCatching { Shelfarr.refresh() }.isFailure) return
        val prefs = Services.prefs
        val before = runCatching { json.decodeFromString<Map<String, String>>(prefs.getString("shelfarr_statuses").orEmpty()) }.getOrDefault(emptyMap())
        val requests = Shelfarr.requests.value
        val arrived = requests.filter { r -> r.isCompleted && before["${r.id}"].let { it != null && it != r.status } }
        prefs.putString("shelfarr_statuses", json.encodeToString(requests.associate { "${it.id}" to it.status }))
        if (arrived.isEmpty()) return
        // Into the library first, so the notification opens the book itself.
        runCatching { Services.books.refresh(BookSort.ADDED_DESC) }
        arrived.forEach { Notifier.ready(it) }
    }
}

/** Local notifications, and where tapping one goes (MainActivity reads [EXTRA_OPEN]). */
object Notifier {
    const val EXTRA_OPEN = "open"
    const val EXTRA_ASIN = "asin"
    const val EXTRA_TITLE = "title"
    const val EXTRA_AUTHOR = "author"
    private const val RELEASES_CHANNEL = "com.bennybar.kitzi.channel.releases"
    private const val SHELFARR_CHANNEL = "com.bennybar.kitzi.channel.shelfarr"

    private lateinit var context: Context

    fun createChannels(context: Context) {
        this.context = context.applicationContext
        context.getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(
            NotificationChannel(RELEASES_CHANNEL, "New releases", NotificationManager.IMPORTANCE_DEFAULT),
            NotificationChannel(SHELFARR_CHANNEL, "Shelfarr", NotificationManager.IMPORTANCE_DEFAULT),
        ))
    }

    fun releases(fresh: List<RadarFind>, out: List<RadarFind>, today: LocalDate) {
        // A few: one each. Many: one summary.
        if (fresh.size > 3) {
            post("radar-${System.currentTimeMillis() / 1000}", RELEASES_CHANNEL, "${fresh.size} new books for you",
                fresh.take(3).joinToString(", ") { it.title } + "…", EXTRA_OPEN to "releases")
        } else {
            for (f in fresh) {
                val day = f.releaseDay?.takeIf { f.isUpcoming(today) }
                val whenOut = day?.let { " · out " + it.format(DateTimeFormatter.ofPattern("MMM d")) }.orEmpty()
                post("radar-${f.asin}", RELEASES_CHANNEL, f.reason, f.title + whenOut, EXTRA_OPEN to "audible", EXTRA_ASIN to f.asin)
            }
        }
        for (f in out) {
            post("radar-out-${f.asin}", RELEASES_CHANNEL, "Out today", "${f.title} · ${f.reason}", EXTRA_OPEN to "audible", EXTRA_ASIN to f.asin)
        }
    }

    fun ready(r: ShelfarrRequest) {
        post("shelfarr-${r.id}", SHELFARR_CHANNEL, "Ready to listen", listOfNotNull(r.title, r.author).joinToString(" · "),
            EXTRA_OPEN to "book", EXTRA_TITLE to r.title, EXTRA_AUTHOR to r.author)
    }

    private fun post(tag: String, channel: String, title: String, body: String, vararg extras: Pair<String, String?>) {
        if (Build.VERSION.SDK_INT >= 33 &&
            context.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) return
        val intent = Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            .apply { extras.forEach { (k, v) -> putExtra(k, v) } }
        val notification = NotificationCompat.Builder(context, channel)
            .setSmallIcon(R.drawable.ic_shortcut_book)
            .setContentTitle(title)
            .setContentText(body)
            .setStyle(NotificationCompat.BigTextStyle().bigText(body))
            .setAutoCancel(true)
            .setContentIntent(PendingIntent.getActivity(context, tag.hashCode(), intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
            .build()
        context.getSystemService(NotificationManager::class.java).notify(tag, 0, notification)
    }
}
