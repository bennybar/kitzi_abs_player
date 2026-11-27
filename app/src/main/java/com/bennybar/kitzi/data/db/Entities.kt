package com.bennybar.kitzi.data.db

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey

/**
 * Mirrors the sqflite `books` table (books_repository.dart:378) so the legacy
 * rows can be imported 1:1. Columns kept even where unused by the port, because
 * dropping one means silently losing that data on import.
 */
@Entity(
    tableName = "books",
    indices = [
        Index(value = ["updatedAt"]),
        Index(value = ["addedAt"]),
        Index(value = ["title"]),
        Index(value = ["author"]),
        Index(value = ["isAudioBook"]),
        Index(value = ["series"]),
        Index(value = ["collection"]),
    ],
)
data class BookEntity(
    @PrimaryKey val id: String,
    val title: String,
    val author: String?,
    val coverUrl: String,
    val coverPath: String?,
    val coverUpdatedAt: Long?,
    val description: String?,
    val durationMs: Long?,
    val sizeBytes: Long?,
    val updatedAt: Long?,
    val addedAt: Long?,
    val series: String?,
    val seriesSequence: Double?,
    val collection: String?,
    val collectionSequence: Double?,
    val isAudioBook: Boolean,
    val mediaKind: String?,
    val libraryId: String?,
    /** JSON arrays, exactly as the Flutter app stored them. */
    val authors: String?,
    val narrators: String?,
    val publisher: String?,
    val publishYear: Int?,
    val genres: String?,
    /** The server's Audible ASIN (metadata.asin), when it has one. */
    val asin: String? = null,
    /** False when the server has no cover for it; null when the list didn't say. */
    val hasCover: Boolean? = null,
    val chapterCount: Int? = null,
)

/**
 * A book's Audible match: its ASIN (the server's, or found by a title search),
 * stars and language. `asin` empty: Audible has no match. `stars` 0: on Audible
 * but not rated yet. In the library's database so the list can sort by it.
 */
@Entity(tableName = "audible")
data class AudibleEntity(
    @PrimaryKey val itemId: String,
    val asin: String,
    val stars: Double,
    val count: Int,
    val at: Long,
    val language: String?,
)

/**
 * Listening progress, from `GET /api/me` -> `mediaProgress[]`.
 *
 * The Flutter app kept this only in memory, which forced the library filters to
 * be expressed as id sets passed into the query (books_page.dart:663). Storing
 * it lets sort + filter + paging collapse into one SQL statement, which is what
 * REWRITE.md asks for.
 */
@Entity(tableName = "media_progress")
data class MediaProgressEntity(
    @PrimaryKey val itemId: String,
    /** 0..1 */
    val progress: Double,
    val isFinished: Boolean,
    val currentTimeSec: Double,
    val durationSec: Double,
    val lastUpdate: Long,
)

/** books_repository.dart:423 — author metadata, refreshed at most every 24h. */
@Entity(tableName = "authors", indices = [Index(value = ["name"])])
data class AuthorEntity(
    @PrimaryKey val name: String,
    val id: String?,
    val description: String?,
    val updatedAt: Long?,
    val lastSyncedAt: Long?,
)
