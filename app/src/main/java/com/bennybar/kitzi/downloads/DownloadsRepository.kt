package com.bennybar.kitzi.downloads

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import com.bennybar.kitzi.data.BooksRepository
import com.bennybar.kitzi.data.db.DownloadEntity
import com.bennybar.kitzi.data.db.DownloadStatus
import com.bennybar.kitzi.data.db.DownloadsDao
import com.bennybar.kitzi.data.legacy.DownloadPaths
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

data class ItemDownload(
    val itemId: String,
    val status: DownloadStatus,
    /** 0..1 across the whole book. */
    val progress: Double,
    val completedTracks: Int,
    val totalTracks: Int,
) {
    val isComplete: Boolean get() = totalTracks > 0 && completedTracks == totalTracks
}

class DownloadsRepository(
    private val context: Context,
    private val daoProvider: () -> DownloadsDao,
    private val planner: DownloadPlanResolver,
    private val paths: DownloadPaths,
    private val prefs: FlutterPrefs,
    private val books: BooksRepository,
) {
    // Resolved per access so it always points at the CURRENT library's database,
    // never a stale one captured before a library was chosen or switched.
    private val dao: DownloadsDao get() = daoProvider()

    private val workManager get() = WorkManager.getInstance(context)

    var wifiOnly: Boolean
        get() = prefs.getBoolean(KEY_WIFI_ONLY, false)
        set(value) = prefs.putBoolean(KEY_WIFI_ONLY, value)

    var autoDeleteOnFinish: Boolean
        get() = prefs.getBoolean(KEY_AUTO_DELETE, false)
        set(value) = prefs.putBoolean(KEY_AUTO_DELETE, value)

    /**
     * Queues a book.
     *
     * Every missing track is enqueued up front onto ONE global serial chain.
     * WorkManager is the queue — there is no second, app-level queue deciding
     * what runs next, because that is precisely what used to strand books in
     * "queued" forever.
     */
    suspend fun download(itemId: String) = withContext(Dispatchers.IO) {
        val plan = planner.resolve(itemId)
        if (plan.isEmpty()) return@withContext

        // Bind this download to the library active NOW, so a worker that runs after
        // the user switches libraries still writes files and rows to the right one.
        val libraryId = currentLib()
        val dir = paths.itemDir(itemId, libraryId)
        val title = books.getBook(itemId)?.title.orEmpty()

        // Record the plan (durations included) before any bytes move, so the book's
        // shape is known offline even if the download is interrupted.
        dao.upsert(
            plan.map { t ->
                val onDisk = java.io.File(dir, t.filename).takeIf { it.exists() && it.length() > 0 }
                DownloadEntity(
                    libraryItemId = itemId,
                    trackIndex = t.index,
                    fileId = t.fileId,
                    mimeType = t.mimeType,
                    filename = t.filename,
                    durationSec = t.durationSec,
                    status = if (onDisk != null) DownloadStatus.COMPLETE else DownloadStatus.QUEUED,
                    bytesDownloaded = onDisk?.length() ?: 0,
                    totalBytes = onDisk?.length() ?: 0,
                    updatedAt = System.currentTimeMillis(),
                )
            }
        )

        val missing = plan.filter { !java.io.File(dir, it.filename).let { f -> f.exists() && f.length() > 0 } }
        if (missing.isEmpty()) return@withContext

        // One worker for the whole book (it reads the track plan from the DB rows
        // just written above). A single worker means a single foreground service and
        // therefore one stable progress notification for the entire download.
        val request = OneTimeWorkRequestBuilder<BookDownloadWorker>()
            .setConstraints(constraints())
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(tagFor(itemId, libraryId))
            .setInputData(
                Data.Builder()
                    .putString(BookDownloadWorker.KEY_ITEM_ID, itemId)
                    .putString(BookDownloadWorker.KEY_TITLE, title)
                    .putString(BookDownloadWorker.KEY_LIBRARY_ID, libraryId)
                    .build()
            )
            .build()

        // APPEND_OR_REPLACE, not APPEND: a queue whose tail previously failed or was
        // cancelled would otherwise poison every future enqueue. Books still run one
        // after another on the single unique queue — the platform queue is the queue.
        workManager.enqueueUniqueWork(QUEUE, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
    }

    private fun constraints() = Constraints.Builder()
        .setRequiredNetworkType(if (wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
        .build()

    /** Stops the download but KEEPS completed tracks, so the user can resume. */
    suspend fun cancel(itemId: String) = withContext(Dispatchers.IO) {
        workManager.cancelAllWorkByTag(tagFor(itemId))
        paths.itemDir(itemId).listFiles().orEmpty()
            .filter { it.name.endsWith(".part") }
            .forEach { it.delete() }
        dao.tracksFor(itemId)
            .filter { it.status != DownloadStatus.COMPLETE }
            .forEach { dao.setStatus(itemId, it.trackIndex, DownloadStatus.CANCELED) }
    }

    /** Removes the download entirely: files and bookkeeping. */
    suspend fun delete(itemId: String) = withContext(Dispatchers.IO) {
        workManager.cancelAllWorkByTag(tagFor(itemId))
        paths.itemDir(itemId).deleteRecursively()
        dao.deleteItem(itemId)
    }

    /**
     * Removes every download. Cancels in-flight work FIRST and waits for the
     * cancellation to be applied, so a running track worker can't finish and
     * re-create files or rows immediately after the wipe.
     */
    suspend fun deleteAll() = withContext(Dispatchers.IO) {
        runCatching { workManager.cancelUniqueWork(QUEUE).result.get() }
        paths.libraryDir().deleteRecursively()
        dao.deleteAll()
    }

    fun watch(itemId: String): Flow<ItemDownload> =
        dao.watchTracksFor(itemId).map { rows -> aggregate(itemId, rows) }

    fun watchAll(): Flow<List<ItemDownload>> =
        dao.watchAll().map { rows ->
            rows.groupBy { it.libraryItemId }.map { (id, tracks) -> aggregate(id, tracks) }
        }

    suspend fun downloadedItemIds(): List<String> = withContext(Dispatchers.IO) {
        dao.itemIds().filter { id ->
            val tracks = dao.tracksFor(id)
            aggregate(id, tracks).isComplete && allTrackFilesPresent(id, tracks)
        }
    }

    /**
     * The DB says every track is COMPLETE — but a file can vanish underneath us
     * (deleted by a file manager, cleared by the OS, or an interrupted Flutter
     * download adopted as "done"). Confirm each track's bytes are actually on disk
     * before we let a book play locally; otherwise it plays only the files that
     * survive and can hit "finished" early.
     */
    private fun allTrackFilesPresent(itemId: String, tracks: List<DownloadEntity>): Boolean {
        if (tracks.isEmpty()) return false
        val dir = paths.itemDir(itemId)
        return tracks.all { t ->
            val f = java.io.File(dir, t.filename)
            f.exists() && f.length() > 0
        }
    }

    /**
     * Adopts downloads that are already on disk but have no bookkeeping — i.e.
     * everything the Flutter app downloaded before the update.
     *
     * The files themselves migrate for free (same directory), but the Downloads
     * screen and "is this downloaded?" both read the database, so without this the
     * user's existing downloads are invisible and the app would happily stream a
     * book it already has on disk.
     */
    suspend fun adoptExistingDownloads() = withContext(Dispatchers.IO) {
        val known = dao.itemIds().toSet()

        paths.downloadedItemIds()
            .filter { it !in known }
            .forEach { itemId ->
                val files = paths.itemDir(itemId).listFiles().orEmpty()
                    .filter { it.isFile && it.length() > 0 && !it.name.endsWith(".part") }
                    .sortedBy { it.name }
                if (files.isEmpty()) return@forEach

                dao.upsert(
                    files.map { file ->
                        // track_007.m4a -> 7
                        val index = file.nameWithoutExtension.substringAfterLast('_').toIntOrNull() ?: 0
                        DownloadEntity(
                            libraryItemId = itemId,
                            trackIndex = index,
                            fileId = "",
                            mimeType = mimeFor(file.extension),
                            filename = file.name,
                            // Unknown; the player hydrates durations as it prepares each file.
                            durationSec = null,
                            status = DownloadStatus.COMPLETE,
                            bytesDownloaded = file.length(),
                            totalBytes = file.length(),
                            updatedAt = file.lastModified(),
                        )
                    }
                )
            }
    }

    private fun mimeFor(ext: String) = when (ext.lowercase()) {
        "mp3" -> "audio/mpeg"
        "m4a", "m4b", "aac", "mp4" -> "audio/mp4"
        "flac" -> "audio/flac"
        "ogg", "oga" -> "audio/ogg"
        "opus" -> "audio/opus"
        else -> "audio/mpeg"
    }

    suspend fun isDownloaded(itemId: String): Boolean = withContext(Dispatchers.IO) {
        val tracks = dao.tracksFor(itemId)
        aggregate(itemId, tracks).isComplete && allTrackFilesPresent(itemId, tracks)
    }

    /** Track durations captured at download time — this is what keeps progress sync alive offline. */
    suspend fun trackDurations(itemId: String): Map<Int, Double> = withContext(Dispatchers.IO) {
        dao.tracksFor(itemId).mapNotNull { row -> row.durationSec?.let { row.trackIndex to it } }.toMap()
    }

    suspend fun totalBytes(): Long = withContext(Dispatchers.IO) { paths.totalBytes() }

    /**
     * Completeness is the plan versus what actually landed, not "does any file
     * exist" — otherwise a book with one of twelve tracks reads as downloaded.
     */
    private fun aggregate(itemId: String, tracks: List<DownloadEntity>): ItemDownload {
        if (tracks.isEmpty()) {
            return ItemDownload(itemId, DownloadStatus.CANCELED, 0.0, 0, 0)
        }

        val complete = tracks.count { it.status == DownloadStatus.COMPLETE }
        val running = tracks.filter { it.status == DownloadStatus.RUNNING }
        val runningFraction = running.sumOf { r ->
            if (r.totalBytes > 0) r.bytesDownloaded.toDouble() / r.totalBytes else 0.0
        }

        val status = when {
            complete == tracks.size -> DownloadStatus.COMPLETE
            running.isNotEmpty() -> DownloadStatus.RUNNING
            tracks.any { it.status == DownloadStatus.QUEUED } -> DownloadStatus.QUEUED
            tracks.any { it.status == DownloadStatus.FAILED } -> DownloadStatus.FAILED
            else -> DownloadStatus.CANCELED
        }

        return ItemDownload(
            itemId = itemId,
            status = status,
            progress = ((complete + runningFraction) / tracks.size).coerceIn(0.0, 1.0),
            completedTracks = complete,
            totalTracks = tracks.size,
        )
    }

    private fun currentLib(): String =
        books.libraryId.takeIf { it.isNotBlank() } ?: DownloadPaths.DEFAULT_LIBRARY_ID

    // The tag carries the library so cancel/delete only touch the intended
    // library's work, never a same-item-id download in another library.
    private fun tagFor(itemId: String, libraryId: String = currentLib()) = "book:$libraryId:$itemId"

    private companion object {
        /** ONE queue for the whole app — the platform queue is the queue. */
        const val QUEUE = "kitzi-downloads"
        const val KEY_WIFI_ONLY = "downloads_wifi_only"
        const val KEY_AUTO_DELETE = "downloads_auto_delete_on_finish"
    }
}
