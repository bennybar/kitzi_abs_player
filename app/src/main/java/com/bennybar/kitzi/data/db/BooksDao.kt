package com.bennybar.kitzi.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.RawQuery
import androidx.room.Upsert
import androidx.sqlite.db.SimpleSQLiteQuery
import androidx.sqlite.db.SupportSQLiteQuery
import kotlinx.coroutines.flow.Flow

/** Library list ordering. Maps to the UI's SortMode (books_page.dart:40). */
enum class BookSort { NAME_ASC, ADDED_DESC, UPDATED_DESC }

/** books_page.dart:42 */
enum class LibraryFilter { ALL, NOT_STARTED, IN_PROGRESS, FINISHED }

@Dao
interface BooksDao {

    @Upsert
    suspend fun upsertBooks(books: List<BookEntity>)

    @Upsert
    suspend fun upsertProgress(progress: List<MediaProgressEntity>)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsertAuthors(authors: List<AuthorEntity>)

    @Query("SELECT * FROM authors")
    suspend fun allAuthors(): List<AuthorEntity>

    @Query("SELECT * FROM books WHERE id = :id")
    suspend fun getBook(id: String): BookEntity?

    @Query("SELECT * FROM books WHERE id IN (:ids)")
    suspend fun getBooks(ids: List<String>): List<BookEntity>

    @Query("DELETE FROM books WHERE id = :id")
    suspend fun deleteBook(id: String)

    @Query("SELECT updatedAt FROM books WHERE id = :id")
    suspend fun updatedAtOf(id: String): Long?

    @Query("SELECT COUNT(*) FROM books")
    suspend fun count(): Int

    @Query("SELECT * FROM media_progress WHERE itemId = :id")
    suspend fun progressFor(id: String): MediaProgressEntity?

    @Query("SELECT * FROM media_progress")
    fun watchAllProgress(): Flow<List<MediaProgressEntity>>

    /**
     * The library list. Sort, filter, search and paging all resolve inside this
     * one statement — never by post-processing a loaded page, which is the bug
     * REWRITE.md calls "the single most 'app feels broken' bug there is".
     */
    @RawQuery(observedEntities = [BookEntity::class, MediaProgressEntity::class])
    fun pagedBooksRaw(query: SupportSQLiteQuery): Flow<List<BookEntity>>

    @RawQuery(observedEntities = [BookEntity::class, MediaProgressEntity::class])
    suspend fun countBooksRaw(query: SupportSQLiteQuery): Int

    /** Series members: explicit sequence first, NULLs last, then title. (books_repository.dart:1938) */
    @Query(
        """
        SELECT * FROM books
        WHERE series = :series AND $AUDIOBOOK_PREDICATE
        ORDER BY seriesSequence IS NULL, seriesSequence ASC, title COLLATE NOCASE ASC
        """
    )
    suspend fun booksInSeries(series: String): List<BookEntity>

    @Query(
        """
        SELECT author AS name, COUNT(*) AS bookCount FROM books
        WHERE author IS NOT NULL AND author != '' AND $AUDIOBOOK_PREDICATE
        GROUP BY author
        ORDER BY author COLLATE NOCASE ASC
        """
    )
    suspend fun authorsWithCounts(): List<AuthorCount>

    /**
     * Series are derived from the books table, not fetched as a list — the same
     * way the Flutter app builds the Authors view. `minBooks` backs the
     * `ui_series_min_books` setting (1 = show everything).
     */
    @Query(
        """
        SELECT series AS name, COUNT(*) AS bookCount FROM books
        WHERE series IS NOT NULL AND series != '' AND $AUDIOBOOK_PREDICATE
        GROUP BY series
        HAVING COUNT(*) >= :minBooks
        ORDER BY series COLLATE NOCASE ASC
        """
    )
    suspend fun seriesWithCounts(minBooks: Int): List<AuthorCount>

    /**
     * The member covers for every series, ordered so the first row per series is
     * the deck's hero. Kept minimal (id + coverPath) so the series list can paint
     * its fanned covers without loading whole books.
     */
    @Query(
        """
        SELECT series AS series, id AS id, coverPath AS coverPath FROM books
        WHERE series IS NOT NULL AND series != '' AND $AUDIOBOOK_PREDICATE
        ORDER BY series COLLATE NOCASE ASC, seriesSequence IS NULL, seriesSequence ASC, title COLLATE NOCASE ASC
        """
    )
    suspend fun seriesCovers(): List<SeriesCoverRow>

    /** Books the user has actually started, most recently touched first. */
    @Query(
        """
        SELECT b.* FROM books b
        JOIN media_progress p ON p.itemId = b.id
        WHERE p.isFinished = 0 AND p.progress > 0 AND $AUDIOBOOK_PREDICATE
        ORDER BY p.lastUpdate DESC
        LIMIT :limit
        """
    )
    suspend fun continueListening(limit: Int): List<BookEntity>

    @Query(
        "SELECT * FROM books WHERE $AUDIOBOOK_PREDICATE ORDER BY addedAt IS NULL, addedAt DESC LIMIT :limit"
    )
    suspend fun recentlyAdded(limit: Int): List<BookEntity>

    @Query(
        "SELECT * FROM books WHERE author = :author AND $AUDIOBOOK_PREDICATE ORDER BY title COLLATE NOCASE ASC"
    )
    suspend fun booksByAuthor(author: String): List<BookEntity>

    @Query("SELECT * FROM books WHERE collection IS NOT NULL AND collection != '' AND $AUDIOBOOK_PREDICATE")
    suspend fun booksInAnyCollection(): List<BookEntity>

    companion object {
        /**
         * "Is this an audiobook?", byte-for-byte the predicate the Flutter app
         * used (books_repository.dart:857). The NULL arm exists for rows written
         * by older versions before isAudioBook was stored.
         */
        const val AUDIOBOOK_PREDICATE =
            "((isAudioBook = 1) OR (isAudioBook IS NULL AND durationMs IS NOT NULL AND durationMs > 0))"

        /**
         * Builds the library query. Progress lives in its own table, so the
         * filters are a LEFT JOIN predicate rather than the id-set round-trip the
         * Flutter app needed (books_page.dart:663) — same semantics, one statement,
         * and no 999-bind-variable ceiling.
         */
        fun libraryQuery(
            sort: BookSort,
            filter: LibraryFilter,
            search: String?,
            limit: Int,
            offset: Int,
            countOnly: Boolean = false,
        ): SupportSQLiteQuery {
            val args = mutableListOf<Any>()
            val where = mutableListOf(AUDIOBOOK_PREDICATE)

            search?.trim()?.takeIf { it.isNotEmpty() }?.let {
                where += "(LOWER(b.title) LIKE ? OR LOWER(b.author) LIKE ?)"
                val like = "%${it.lowercase()}%"
                args += like
                args += like
            }

            // A book with no progress row counts as not-started; `finished` and
            // `inProgress` therefore require a row to exist.
            where += when (filter) {
                LibraryFilter.ALL -> "1"
                LibraryFilter.FINISHED -> "p.isFinished = 1"
                LibraryFilter.IN_PROGRESS -> "(p.isFinished = 0 AND p.progress > 0)"
                LibraryFilter.NOT_STARTED ->
                    "(p.itemId IS NULL OR (p.isFinished = 0 AND p.progress <= 0))"
            }

            // NULLS LAST, matching the `X IS NULL,` idiom in the Dart.
            val orderBy = when (sort) {
                BookSort.NAME_ASC -> "b.title COLLATE NOCASE ASC"
                BookSort.ADDED_DESC -> "b.addedAt IS NULL, b.addedAt DESC, b.updatedAt DESC"
                BookSort.UPDATED_DESC -> "b.updatedAt IS NULL, b.updatedAt DESC"
            }

            val select = if (countOnly) "COUNT(*)" else "b.*"
            val sql = buildString {
                append("SELECT $select FROM books b ")
                append("LEFT JOIN media_progress p ON p.itemId = b.id ")
                append("WHERE ${where.joinToString(" AND ")} ")
                if (!countOnly) {
                    append("ORDER BY $orderBy LIMIT ? OFFSET ?")
                }
            }
            if (!countOnly) {
                args += limit
                args += offset
            }
            return SimpleSQLiteQuery(sql, args.toTypedArray())
        }
    }
}

data class AuthorCount(val name: String, val bookCount: Int)

data class SeriesCoverRow(val series: String, val id: String, val coverPath: String?)
