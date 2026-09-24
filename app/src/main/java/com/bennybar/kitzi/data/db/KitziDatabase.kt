package com.bennybar.kitzi.data.db

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import androidx.room.Database
import androidx.room.Room
import androidx.room.RoomDatabase
import java.io.File

@Database(
    entities = [
        BookEntity::class,
        MediaProgressEntity::class,
        AuthorEntity::class,
        DownloadEntity::class,
    ],
    // v3: series names are stored with the "#N" suffix stripped, so the cache must
    // be rebuilt from the server for existing rows to be re-parsed.
    version = 3,
    exportSchema = false,
)
abstract class KitziDatabase : RoomDatabase() {
    abstract fun booksDao(): BooksDao
    abstract fun downloadsDao(): DownloadsDao

    companion object {
        private const val TAG = "KitziDatabase"

        /** The open database and its library, swapped as one so a reader can never
         *  pair the new id with the old (already closed) database. */
        private class Open(val libraryId: String, val db: KitziDatabase)
        @Volatile private var open: Open? = null

        /**
         * One database per library, exactly as the Flutter app did — this is what
         * keeps two libraries' caches (and ETags) from polluting each other.
         */
        fun forLibrary(context: Context, libraryId: String): KitziDatabase {
            open?.takeIf { it.libraryId == libraryId }?.let { return it.db }
            synchronized(this) {
                open?.takeIf { it.libraryId == libraryId }?.let { return it.db }
                open?.db?.close()

                LegacyBooksImport.importIfNeeded(context, libraryId)

                val db = Room.databaseBuilder(
                    context.applicationContext,
                    KitziDatabase::class.java,
                    "kitzi_room_$libraryId.db",
                )
                    // Versions 1–2 predate the downloads table holding anything that
                    // matters, so they still rebuild. From v3 on it holds the download
                    // records (track list, durations, completeness), which can't be
                    // re-fetched: a schema bump must ship a Migration. Without one Room
                    // throws on open — caught in testing — instead of silently wiping
                    // every download.
                    .fallbackToDestructiveMigrationFrom(dropAllTables = true, 1, 2)
                    .build()
                open = Open(libraryId, db)
                return db
            }
        }
    }
}

/**
 * Moves the Flutter app's sqflite library cache into Room, once per library.
 *
 * Room refuses to open a database it did not create (the sqflite file has no
 * `room_master_table`), so the rows are copied rather than the file adopted.
 *
 * This is worth doing even though the library cache is re-fetchable from the
 * server: without it, a user who updates while offline opens the app to an empty
 * library, and their downloaded books have no metadata to render.
 */
object LegacyBooksImport {

    private const val TAG = "LegacyBooksImport"

    /**
     * Imports when the Room database does not yet exist. Keying off the file
     * rather than a "done" flag means the import re-runs by itself if the cache is
     * ever rebuilt (a schema change, a user clearing it), instead of leaving the
     * library permanently empty for an offline user.
     *
     * The Flutter database is NOT deleted afterwards. It is under a megabyte, and
     * keeping it is what makes that self-healing possible.
     */
    fun importIfNeeded(context: Context, libraryId: String) {
        val room = context.getDatabasePath("kitzi_room_$libraryId.db")
        if (room.exists()) return

        val legacy = context.getDatabasePath("kitzi_books_$libraryId.db")
        if (!legacy.exists()) return

        val imported = runCatching { copyRows(context, legacy, libraryId) }
            .onFailure { Log.w(TAG, "legacy import failed for $libraryId", it) }
            .getOrDefault(0)

        Log.i(TAG, "imported $imported books from ${legacy.name}")
    }

    private fun copyRows(context: Context, legacy: File, libraryId: String): Int {
        val src = SQLiteDatabase.openDatabase(legacy.path, null, SQLiteDatabase.OPEN_READONLY)
        val books = mutableListOf<BookEntity>()
        src.use { db ->
            db.rawQuery("SELECT * FROM books", null).use { c ->
                fun str(name: String): String? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getString)

                fun long(name: String): Long? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getLong)

                fun dbl(name: String): Double? =
                    c.getColumnIndex(name).takeIf { it >= 0 && !c.isNull(it) }?.let(c::getDouble)

                while (c.moveToNext()) {
                    val id = str("id") ?: continue
                    val durationMs = long("durationMs")
                    val isAudioRaw = long("isAudioBook")
                    books += BookEntity(
                        id = id,
                        title = str("title").orEmpty(),
                        author = str("author"),
                        coverUrl = str("coverUrl").orEmpty(),
                        coverPath = str("coverPath"),
                        coverUpdatedAt = long("coverUpdatedAt"),
                        description = str("description"),
                        durationMs = durationMs,
                        sizeBytes = long("sizeBytes"),
                        updatedAt = long("updatedAt"),
                        addedAt = long("addedAt") ?: long("updatedAt"),
                        series = str("series"),
                        seriesSequence = dbl("seriesSequence"),
                        collection = str("collection"),
                        collectionSequence = dbl("collectionSequence"),
                        // Same NULL-recovery rule the Dart used on read (books_repository.dart:753).
                        isAudioBook = isAudioRaw?.let { it != 0L }
                            ?: (durationMs != null && durationMs > 0),
                        mediaKind = str("mediaKind"),
                        libraryId = str("libraryId") ?: libraryId,
                        authors = str("authors"),
                        narrators = str("narrators"),
                        publisher = str("publisher"),
                        publishYear = long("publishYear")?.toInt(),
                        genres = str("genres"),
                    )
                }
            }
        }

        if (books.isEmpty()) return 0

        val room = Room.databaseBuilder(
            context.applicationContext,
            KitziDatabase::class.java,
            "kitzi_room_$libraryId.db",
        ).allowMainThreadQueries().fallbackToDestructiveMigration().build()

        try {
            room.runInTransaction {
                val w = room.openHelper.writableDatabase
                books.forEach { b ->
                    w.execSQL(
                        """INSERT OR REPLACE INTO books
                           (id,title,author,coverUrl,coverPath,coverUpdatedAt,description,durationMs,
                            sizeBytes,updatedAt,addedAt,series,seriesSequence,collection,collectionSequence,
                            isAudioBook,mediaKind,libraryId,authors,narrators,publisher,publishYear,genres)
                           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                        arrayOf(
                            b.id, b.title, b.author, b.coverUrl, b.coverPath, b.coverUpdatedAt,
                            b.description, b.durationMs, b.sizeBytes, b.updatedAt, b.addedAt,
                            b.series, b.seriesSequence, b.collection, b.collectionSequence,
                            if (b.isAudioBook) 1 else 0, b.mediaKind, b.libraryId, b.authors,
                            b.narrators, b.publisher, b.publishYear, b.genres,
                        ),
                    )
                }
            }
        } finally {
            room.close()
        }
        return books.size
    }
}
