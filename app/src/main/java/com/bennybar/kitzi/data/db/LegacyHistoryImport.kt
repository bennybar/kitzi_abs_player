package com.bennybar.kitzi.data.db

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Brings the Flutter app's local listening history into the Kotlin stores, once.
 *
 * Only the playback JOURNAL is migrated here — the per-book "jump back to where you
 * paused" snapshots (`kitzi_playback_journal.db`, table `playback_history`) that
 * feed the player's Play history sheet. It maps onto [com.bennybar.kitzi.data.PlaybackJournal]'s
 * prefs format (`playback_journal_<itemId>`).
 *
 * Not migrated, deliberately:
 *  - Aggregate listening stats (totals, per-day, streak) come from the server
 *    (`/api/me/listening-stats`), so they carry over on their own.
 *  - `recent_books` is superseded by server-derived "Continue listening".
 *  - Bookmarks are server-owned in the Kotlin app and fetched fresh.
 */
object LegacyHistoryImport {

    private const val TAG = "LegacyHistoryImport"
    private const val DONE_KEY = "legacy_journal_imported"
    private const val MAX_PER_BOOK = 30

    fun importIfNeeded(context: Context, prefs: FlutterPrefs) {
        if (prefs.getBoolean(DONE_KEY, false)) return

        val db = context.getDatabasePath("kitzi_playback_journal.db")
        if (db.exists()) {
            val imported = runCatching { importJournal(db, prefs) }
                .onFailure { Log.w(TAG, "journal import failed", it) }
                .getOrDefault(0)
            Log.i(TAG, "imported journal history for $imported book(s)")
        }
        // Set even when the legacy DB is absent, so this never re-scans.
        prefs.putBoolean(DONE_KEY, true)
    }

    private fun importJournal(dbFile: File, prefs: FlutterPrefs): Int {
        // Newest first, so the per-book cap keeps the most recent snapshots — the
        // same order PlaybackJournal stores and reads.
        val byItem = LinkedHashMap<String, JSONArray>()
        SQLiteDatabase.openDatabase(dbFile.path, null, SQLiteDatabase.OPEN_READONLY).use { db ->
            db.rawQuery(
                "SELECT libraryItemId, positionMs, chapterTitle, chapterIndex, createdAt " +
                    "FROM playback_history ORDER BY createdAt DESC",
                null,
            ).use { c ->
                fun str(name: String): String? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getString)
                fun long(name: String): Long? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getLong)
                fun int(name: String): Int? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getInt)

                while (c.moveToNext()) {
                    val itemId = str("libraryItemId") ?: continue
                    val arr = byItem.getOrPut(itemId) { JSONArray() }
                    if (arr.length() >= MAX_PER_BOOK) continue
                    arr.put(
                        JSONObject().apply {
                            put("p", (long("positionMs") ?: 0L) / 1000.0)
                            str("chapterTitle")?.let { put("c", it) }
                            int("chapterIndex")?.let { put("i", it) }
                            put("t", long("createdAt") ?: 0L)
                        }
                    )
                }
            }
        }

        var count = 0
        byItem.forEach { (itemId, arr) ->
            if (arr.length() == 0) return@forEach
            // Don't clobber snapshots the Kotlin app has already recorded for a book.
            val key = "playback_journal_$itemId"
            if (prefs.getString(key) == null) {
                prefs.putString(key, arr.toString())
                count++
            }
        }
        return count
    }
}
