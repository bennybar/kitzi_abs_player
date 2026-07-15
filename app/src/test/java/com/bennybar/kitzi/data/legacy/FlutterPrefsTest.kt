package com.bennybar.kitzi.data.legacy

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.File

/**
 * These tests write into SharedPreferences exactly the way Flutter's
 * shared_preferences_android plugin does, then assert we read the values back.
 * The point is to catch encoding mismatches (notably Dart `int` -> `putLong`)
 * that would otherwise only show up as a crash or a silently-reset setting on a
 * real user's device after the update.
 */
@RunWith(RobolectricTestRunner::class)
class FlutterPrefsTest {

    private lateinit var context: Context
    private lateinit var prefs: FlutterPrefs

    /** Writes a value the way the Flutter plugin would have written it. */
    private fun writeAsFlutter(block: android.content.SharedPreferences.Editor.() -> Unit) {
        context.getSharedPreferences(FlutterPrefs.FILE_NAME, Context.MODE_PRIVATE)
            .edit().apply(block).commit()
    }

    @Before
    fun setUp() {
        context = ApplicationProvider.getApplicationContext()
        prefs = FlutterPrefs(context)
    }

    @Test
    fun `reads a Dart int, which the plugin stores as a long`() {
        // ui_font_scale_percent_v2 etc. are Dart ints -> putLong on disk.
        writeAsFlutter { putLong("flutter.ui_font_scale_percent_v2", 110L) }

        assertEquals(110, prefs.getInt("ui_font_scale_percent_v2", 100))
    }

    @Test
    fun `reading a Dart int does not throw ClassCastException`() {
        // The naive port calls getInt() on a long and crashes. Guard against it.
        writeAsFlutter { putLong("flutter.ui_seek_forward_seconds", 30L) }

        assertEquals(30, prefs.getInt("ui_seek_forward_seconds", 15))
    }

    @Test
    fun `reads a Dart bool and String natively`() {
        writeAsFlutter {
            putBoolean("flutter.ui_progress_bar_chapterized", false)
            putString("flutter.abs_base_url", "https://audiobooks02.ibarak.org")
        }

        assertEquals(false, prefs.getBoolean("ui_progress_bar_chapterized", true))
        assertEquals("https://audiobooks02.ibarak.org", prefs.getString("abs_base_url"))
    }

    @Test
    fun `reads a Dart double from its prefixed string encoding`() {
        writeAsFlutter { putString("flutter.some_double", FlutterPrefs.DOUBLE_PREFIX + "1.5") }

        assertEquals(1.5, prefs.getDouble("some_double", 0.0), 0.0001)
    }

    @Test
    fun `falls back to the default when a key is absent`() {
        assertEquals(100, prefs.getInt("ui_font_scale_percent_v2", 100))
        assertEquals(true, prefs.getBoolean("ui_progress_bar_chapterized", true))
        assertEquals(null, prefs.getString("abs_base_url"))
    }

    @Test
    fun `round-trips values we write ourselves`() {
        prefs.putInt("ui_seek_backward_seconds", 45)
        prefs.putBoolean("ui_letter_scroll_enabled", true)
        prefs.putString("abs_access", "token-123")

        assertEquals(45, prefs.getInt("ui_seek_backward_seconds", 30))
        assertEquals(true, prefs.getBoolean("ui_letter_scroll_enabled", false))
        assertEquals("token-123", prefs.getString("abs_access"))
    }

    @Test
    fun `an int we write is a long on disk, so Flutter could still read it`() {
        // Keeps a rollback to the Flutter APK viable.
        prefs.putInt("ui_series_items_per_row", 3)

        val raw = context.getSharedPreferences(FlutterPrefs.FILE_NAME, Context.MODE_PRIVATE)
        assertEquals(3L, raw.getLong("flutter.ui_series_items_per_row", -1L))
    }

    @Test
    fun `downloads resolve to the Flutter documents dir, adopted in place`() {
        val paths = DownloadPaths(context, prefs)

        // Defaults, as a user who never changed the download folder would have.
        assertEquals("abs", paths.baseSubfolder())
        assertEquals("default", paths.currentLibraryId())

        // path_provider's documents dir is context.getDir("flutter", ...) -> app_flutter
        assertTrue(
            "expected the app_flutter dir, got ${paths.documentsDir()}",
            paths.documentsDir().name == "app_flutter",
        )

        writeAsFlutter { putString("flutter.books_library_id", "lib-42") }
        assertEquals("lib-42", paths.currentLibraryId())
        assertTrue(paths.libraryDir().path.endsWith("app_flutter/abs/lib_lib-42"))
        assertTrue(paths.itemDir("item-7").path.endsWith("app_flutter/abs/lib_lib-42/item-7"))
    }

    @Test
    fun `finds downloads the Flutter app left on disk`() {
        writeAsFlutter { putString("flutter.books_library_id", "lib-42") }
        val paths = DownloadPaths(context, prefs)

        // Simulate a book the Flutter app downloaded.
        val item = paths.itemDir("item-7")
        item.mkdirs()
        File(item, "track_000.m4b").writeBytes(ByteArray(2048))
        File(item, "track_001.m4b").writeBytes(ByteArray(1024))
        // An empty dir is not a download.
        paths.itemDir("item-empty").mkdirs()

        assertEquals(listOf("item-7"), paths.downloadedItemIds())
        assertEquals(3072L, paths.bytesForItem("item-7"))
        assertEquals(3072L, paths.totalBytes())
    }

    @Test
    fun `honours a custom download subfolder`() {
        writeAsFlutter {
            putString("flutter.downloads_base_subfolder", "Audiobooks")
            putString("flutter.books_library_id", "lib-1")
        }
        val paths = DownloadPaths(context, prefs)

        assertEquals("Audiobooks", paths.baseSubfolder())
        assertTrue(paths.libraryDir().path.endsWith("app_flutter/Audiobooks/lib_lib-1"))
    }
}
