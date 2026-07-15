package com.bennybar.kitzi.data

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bennybar.kitzi.data.db.BookSort
import com.bennybar.kitzi.data.db.LibraryFilter
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

/**
 * End-to-end against a real ABS server:
 *   -e absUrl https://host -e absUser name -e absPass secret
 */
@RunWith(AndroidJUnit4::class)
class BooksLiveTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val args = InstrumentationRegistry.getArguments()
    private val url get() = args.getString("absUrl")
    private val user get() = args.getString("absUser")
    private val pass get() = args.getString("absPass")

    private lateinit var books: BooksRepository

    @Before
    fun setUp() {
        assumeTrue(url != null && user != null && pass != null)
        Services.init(context)
        assertTrue("login failed", Services.auth.login(url!!, user!!, pass!!))
        books = Services.books
        runBlocking { books.ensureLibrary() }
    }

    @Test
    fun listsLibrariesAndPicksOne() = runBlocking {
        val libs = books.listLibraries()
        Log.i(TAG, "libraries=${libs.map { "${it.name}(${it.mediaType})" }}")
        assertTrue("no libraries", libs.isNotEmpty())
        assertTrue("no library selected", books.libraryId.isNotEmpty())
    }

    @Test
    fun fetchesAPageIntoRoomAndReadsItBack() = runBlocking {
        books.fetchPage(page = 1, limit = 50, force = true)

        val page = books.pagedBooks(BookSort.UPDATED_DESC, LibraryFilter.ALL, null, limit = 20, offset = 0).first()
        Log.i(TAG, "page1=${page.size} first='${page.firstOrNull()?.title}' by ${page.firstOrNull()?.author}")

        assertTrue("no books cached", page.isNotEmpty())
        assertTrue("every cached book must be an audiobook", page.all { it.isAudioBook })
        assertTrue("titles must be non-blank", page.all { it.title.isNotBlank() })
    }

    /**
     * Sorting must be done by SQL over the whole library, not over the page that
     * happens to be loaded. If it were applied to a loaded page, page 2 of an
     * A-Z sort would start over from 'A' instead of continuing where page 1 left off.
     */
    @Test
    fun sortAndPagingHappenInSql() = runBlocking {
        repeat(3) { books.fetchPage(page = it + 1, limit = 50, force = true) }

        val page1 = books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.ALL, null, limit = 10, offset = 0).first()
        val page2 = books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.ALL, null, limit = 10, offset = 10).first()

        Log.i(TAG, "A-Z p1: ${page1.take(3).map { it.title }}")
        Log.i(TAG, "A-Z p2: ${page2.take(3).map { it.title }}")

        assertTrue(page1.isNotEmpty() && page2.isNotEmpty())

        // Sorted within each page...
        val titles1 = page1.map { it.title.lowercase() }
        assertEquals("page 1 is not A-Z", titles1.sorted(), titles1)

        // ...and page 2 continues after page 1 rather than restarting.
        assertTrue(
            "page 2 restarted the sort — it is being sorted per-page, not in SQL",
            page2.first().title.lowercase() >= page1.last().title.lowercase(),
        )
        assertTrue("pages overlap", page1.map { it.id }.intersect(page2.map { it.id }.toSet()).isEmpty())
    }

    @Test
    fun syncsProgressAndFiltersInSql() = runBlocking {
        books.fetchPage(page = 1, limit = 50, force = true)
        val synced = books.syncProgress()
        Log.i(TAG, "progress rows synced=$synced")

        val all = books.countBooks(LibraryFilter.ALL, null)
        val finished = books.countBooks(LibraryFilter.FINISHED, null)
        val inProgress = books.countBooks(LibraryFilter.IN_PROGRESS, null)
        val notStarted = books.countBooks(LibraryFilter.NOT_STARTED, null)
        Log.i(TAG, "all=$all finished=$finished inProgress=$inProgress notStarted=$notStarted")

        // The three filters partition the library exactly.
        assertEquals("filters do not partition the library", all, finished + inProgress + notStarted)

        books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.IN_PROGRESS, null, 50, 0).first().forEach {
            val p = books.progressFor(it.id)
            assertTrue("'${it.title}' is not actually in progress", p != null && !p.isFinished && p.progress > 0)
        }
    }

    @Test
    fun searchFiltersInSql() = runBlocking {
        books.fetchPage(page = 1, limit = 50, force = true)
        val any = books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.ALL, null, 1, 0).first().firstOrNull()
        assumeTrue(any != null)

        val term = any!!.title.take(4)
        val hits = books.pagedBooks(BookSort.NAME_ASC, LibraryFilter.ALL, term, 50, 0).first()
        Log.i(TAG, "search '$term' -> ${hits.size} hits")

        assertTrue("search returned nothing for a term taken from a real title", hits.isNotEmpty())
        assertTrue(
            "search matched a book with the term in neither title nor author",
            hits.all {
                it.title.contains(term, true) || it.author.orEmpty().contains(term, true)
            },
        )
    }

    private companion object {
        const val TAG = "BooksLiveTest"
    }
}
