package com.bennybar.kitzi.downloads

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bennybar.kitzi.data.Services
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

@RunWith(AndroidJUnit4::class)
class DownloadsLiveTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val args = InstrumentationRegistry.getArguments()
    private val url get() = args.getString("absUrl")
    private val user get() = args.getString("absUser")
    private val pass get() = args.getString("absPass")

    @Before
    fun setUp() {
        assumeTrue(url != null && user != null && pass != null)
        Services.init(context)
        assertTrue(Services.auth.login(url!!, user!!, pass!!))
        runBlocking {
            Services.books.ensureLibrary()
            Services.books.fetchPage(page = 1, limit = 50, force = true)
        }
    }

    /**
     * Resolves a real book's track list from the server and checks the plan is
     * usable: real file ids, sane indices, and — the compatibility-critical part —
     * filenames in the exact layout the Flutter app already wrote to disk.
     */
    @Test
    fun resolvesAPlanWithDurationsAndTheRightFilenames() = runBlocking {
        val book = Services.books
            .pagedBooks(BookSort.UPDATED_DESC, LibraryFilter.ALL, null, 5, 0).first()
            .firstOrNull()
        assumeTrue(book != null)

        val planner = DownloadPlanResolver(
            com.bennybar.kitzi.data.net.AbsApi(Services.httpClient, Services.session),
            com.bennybar.kitzi.data.net.PlaybackApi(Services.httpClient, Services.session),
        )
        val plan = planner.resolve(book!!.id)

        Log.i(TAG, "'${book.title}' -> ${plan.size} tracks")
        plan.take(3).forEach { Log.i(TAG, "  ${it.filename} dur=${it.durationSec} mime=${it.mimeType}") }

        assertTrue("no tracks resolved for '${book.title}'", plan.isNotEmpty())
        assertTrue("a track has no file id", plan.all { it.fileId.isNotBlank() })
        assertTrue("filenames must be track_NNN.ext", plan.all { it.filename.matches(Regex("track_\\d{3}\\.\\w+")) })

        // Durations captured at plan time are what keep progress sync alive for a
        // downloaded book that is never streamed.
        assertTrue(
            "no track durations captured — progress sync would silently stop for this book offline",
            plan.any { it.durationSec != null && it.durationSec!! > 0 },
        )

        // Sorting filenames must reproduce track order, since that is how playback
        // orders local files.
        val byName = plan.sortedBy { it.filename }.map { it.index }
        assertEquals("filename sort disagrees with track order", plan.sortedBy { it.index }.map { it.index }, byName)
    }

    /**
     * Downloads a real book end to end and asserts the bytes land in the exact
     * directory the Flutter app used, so an updated user's existing downloads and
     * new ones live side by side.
     */
    @Test
    fun downloadsABookToTheFlutterEraLocation() = runBlocking {
        // Pick the smallest book so the test stays quick.
        val candidates = Services.books
            .pagedBooks(BookSort.UPDATED_DESC, LibraryFilter.ALL, null, 40, 0).first()
        val book = candidates.filter { (it.sizeBytes ?: 0) > 0 }.minByOrNull { it.sizeBytes!! }
        assumeTrue(book != null)
        Log.i(TAG, "downloading '${book!!.title}' (${(book.sizeBytes ?: 0) / 1024 / 1024} MB)")

        Services.downloads.delete(book.id)
        Services.downloads.wifiOnly = false
        Services.downloads.download(book.id)

        // WorkManager runs the chain; poll until the book reports complete.
        var state = Services.downloads.watch(book.id).first()
        val deadline = System.currentTimeMillis() + 5 * 60_000
        while (!state.isComplete && System.currentTimeMillis() < deadline) {
            kotlinx.coroutines.delay(3000)
            state = Services.downloads.watch(book.id).first()
            Log.i(TAG, "  ${state.status} ${(state.progress * 100).toInt()}% (${state.completedTracks}/${state.totalTracks})")
        }

        assertTrue("download did not complete: $state", state.isComplete)

        val dir = Services.downloadPaths.itemDir(book.id)
        val files = dir.listFiles().orEmpty().filter { it.isFile }
        Log.i(TAG, "landed ${files.size} files in $dir")

        // The exact path the Flutter app used: <app_flutter>/abs/lib_<libId>/<itemId>/
        assertTrue("wrong directory: $dir", dir.path.contains("app_flutter/abs/lib_"))
        assertTrue("no files on disk", files.isNotEmpty())
        assertTrue("no .part files should survive", files.none { it.name.endsWith(".part") })
        assertTrue("files must be track_NNN.ext", files.all { it.name.matches(Regex("track_\\d{3}\\.\\w+")) })
        assertTrue("files must be non-empty", files.all { it.length() > 0 })

        // And the app must now consider it downloaded, from the DB rather than a guess.
        assertTrue(Services.downloads.isDownloaded(book.id))
        assertTrue(Services.downloadPaths.downloadedItemIds().contains(book.id))
    }

    private companion object {
        const val TAG = "DownloadsLiveTest"
    }
}
