package com.bennybar.kitzi.data.db

import androidx.room.Dao
import androidx.room.Entity
import androidx.room.Query
import androidx.room.Upsert
import kotlinx.coroutines.flow.Flow

enum class DownloadStatus { QUEUED, RUNNING, COMPLETE, FAILED, CANCELED }

/**
 * One row per track of a book being (or already) downloaded.
 *
 * Persisting the *plan* — not just the files on disk — is what lets the app
 * answer "is this book fully downloaded?" offline, and tell a partial download
 * apart from a complete one. The Flutter app kept the plan only in memory and
 * inferred completeness from "does any file exist", so a half-downloaded book
 * whose bookkeeping had been pruned displayed as complete.
 *
 * [durationSec] is captured at download time from the server's track list. That
 * is the fix for a real bug: a downloaded book that was never streamed had no
 * track durations, so the book position was unknowable past track 0 and progress
 * sync silently stopped reporting.
 */
@Entity(tableName = "downloads", primaryKeys = ["libraryItemId", "trackIndex"])
data class DownloadEntity(
    val libraryItemId: String,
    val trackIndex: Int,
    val fileId: String,
    val mimeType: String,
    /** `track_%03d.<ext>` — must match the Flutter naming or existing files are orphaned. */
    val filename: String,
    val durationSec: Double?,
    val status: DownloadStatus,
    val bytesDownloaded: Long,
    val totalBytes: Long,
    val updatedAt: Long,
)

@Dao
interface DownloadsDao {

    @Upsert
    suspend fun upsert(rows: List<DownloadEntity>)

    @Upsert
    suspend fun upsert(row: DownloadEntity)

    @Query("SELECT * FROM downloads WHERE libraryItemId = :itemId ORDER BY trackIndex")
    suspend fun tracksFor(itemId: String): List<DownloadEntity>

    @Query("SELECT * FROM downloads WHERE libraryItemId = :itemId ORDER BY trackIndex")
    fun watchTracksFor(itemId: String): Flow<List<DownloadEntity>>

    @Query("SELECT * FROM downloads ORDER BY libraryItemId, trackIndex")
    fun watchAll(): Flow<List<DownloadEntity>>

    @Query("SELECT DISTINCT libraryItemId FROM downloads")
    suspend fun itemIds(): List<String>

    @Query("UPDATE downloads SET status = :status, updatedAt = :now WHERE libraryItemId = :itemId AND trackIndex = :index")
    suspend fun setStatus(itemId: String, index: Int, status: DownloadStatus, now: Long = System.currentTimeMillis())

    @Query(
        """UPDATE downloads SET bytesDownloaded = :bytes, totalBytes = :total, status = :status, updatedAt = :now
           WHERE libraryItemId = :itemId AND trackIndex = :index"""
    )
    suspend fun setProgress(
        itemId: String,
        index: Int,
        bytes: Long,
        total: Long,
        status: DownloadStatus,
        now: Long = System.currentTimeMillis(),
    )

    @Query("DELETE FROM downloads WHERE libraryItemId = :itemId")
    suspend fun deleteItem(itemId: String)

    @Query("DELETE FROM downloads")
    suspend fun deleteAll()
}
