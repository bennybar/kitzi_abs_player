package com.bennybar.kitzi.downloads

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.bennybar.kitzi.KitziApplication
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.DownloadStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * Downloads one whole book.
 *
 * One worker per book — not one per track — so a single foreground service, and
 * therefore a single, stable progress notification, spans the entire download.
 * The earlier design gave every track its own worker sharing one notification id:
 * WorkManager tore that notification down and rebuilt it between every track, and
 * once the app went to the background Android 12+ refused to restart the
 * foreground service, so the notification simply vanished mid-download. Looping
 * the tracks inside one worker keeps the notification up the whole time and lets
 * it show real progress.
 *
 * The track plan (file ids, filenames, durations) is written to the database
 * before this is enqueued, so the worker reads what to fetch from there. Skipping
 * tracks already on disk makes a retry resume exactly where it left off.
 */
class BookDownloadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    private enum class Outcome { OK, PERMANENT, TRANSIENT, STOPPED }

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        Services.init(applicationContext)

        val itemId = inputData.getString(KEY_ITEM_ID) ?: return@withContext Result.failure()
        val title = inputData.getString(KEY_TITLE).orEmpty().ifBlank { "your book" }
        // Which library this download was queued FOR (older queued work may lack it).
        val libraryId = inputData.getString(KEY_LIBRARY_ID) ?: Services.currentLibraryId()

        // If the user switched libraries while this was queued, don't write into the
        // now-active library's database (only one library DB is open at a time —
        // forcing this one open would evict the one the app is using). Defer until
        // that library is active again.
        if (libraryId != Services.currentLibraryId()) return@withContext Result.retry()

        val dao = Services.downloadsDao()
        val dir = Services.downloadPaths.itemDir(itemId, libraryId).apply { mkdirs() }

        val tracks = dao.tracksFor(itemId).sortedBy { it.trackIndex }
        if (tracks.isEmpty()) return@withContext Result.success()
        val total = tracks.size

        // Tracks already on disk (a resumed or re-queued book) count as done up front.
        var done = tracks.count { File(dir, it.filename).let { f -> f.exists() && f.length() > 0 } }
        runCatching { setForeground(foregroundInfo(itemId, title, done, total, 0.0)) }

        var transientFailure = false

        for (t in tracks) {
            if (isStopped) return@withContext Result.failure()

            val target = File(dir, t.filename)
            if (target.exists() && target.length() > 0) {
                dao.setStatus(itemId, t.trackIndex, DownloadStatus.COMPLETE)
                continue
            }

            dao.setStatus(itemId, t.trackIndex, DownloadStatus.RUNNING)
            runCatching { setForeground(foregroundInfo(itemId, title, done, total, 0.0)) }

            when (fetchTrack(itemId, t.fileId, dir, t.filename, dao, t.trackIndex, title, done, total)) {
                Outcome.OK -> done++
                Outcome.STOPPED -> {
                    dao.setStatus(itemId, t.trackIndex, DownloadStatus.CANCELED)
                    return@withContext Result.failure()
                }
                // A 4xx won't fix itself: mark this track failed and move on to the
                // rest, rather than blocking the whole book on one bad file.
                Outcome.PERMANENT -> dao.setStatus(itemId, t.trackIndex, DownloadStatus.FAILED)
                // A network blip: stop here and let WorkManager retry with backoff.
                // The retry skips everything already on disk and picks up this track.
                Outcome.TRANSIENT -> {
                    dao.setStatus(itemId, t.trackIndex, DownloadStatus.FAILED)
                    transientFailure = true
                    break
                }
            }
        }

        when {
            transientFailure && runAttemptCount < MAX_ATTEMPTS -> Result.retry()
            done == total -> Result.success()
            else -> Result.failure()
        }
    }

    private suspend fun fetchTrack(
        itemId: String,
        fileId: String,
        dir: File,
        filename: String,
        dao: com.bennybar.kitzi.data.db.DownloadsDao,
        trackIndex: Int,
        title: String,
        done: Int,
        total: Int,
    ): Outcome {
        val url = "${Services.session.baseUrl}/api/items/$itemId/file/$fileId/download"
        val partial = File(dir, "$filename.part")
        val target = File(dir, filename)

        return try {
            // The token is fetched now, not baked in at enqueue time; the auth
            // interceptor on this client refreshes and retries on 401.
            Services.httpClient.newCall(Request.Builder().url(url).get().build()).execute().use { resp ->
                if (!resp.isSuccessful) {
                    return if (resp.code in 400..499) Outcome.PERMANENT else Outcome.TRANSIENT
                }
                val body = resp.body ?: return Outcome.TRANSIENT
                val len = body.contentLength()
                var written = 0L
                var lastNotify = 0L

                body.byteStream().use { input ->
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            if (isStopped) {
                                partial.delete()
                                return Outcome.STOPPED
                            }
                            val read = input.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                            written += read
                            if (written - lastNotify >= PROGRESS_EVERY) {
                                lastNotify = written
                                dao.setProgress(itemId, trackIndex, written, len, DownloadStatus.RUNNING)
                                val frac = if (len > 0) written.toDouble() / len else 0.0
                                runCatching { setForeground(foregroundInfo(itemId, title, done, total, frac)) }
                            }
                        }
                    }
                }

                // Only publish under the real name once the bytes are all there, so a
                // half-written file can never be mistaken for a finished track.
                if (!partial.renameTo(target) || !target.exists() || target.length() <= 0) {
                    partial.delete()
                    Outcome.TRANSIENT
                } else {
                    dao.setProgress(itemId, trackIndex, target.length(), target.length(), DownloadStatus.COMPLETE)
                    Outcome.OK
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "download failed: $itemId/$filename", e)
            partial.delete()
            Outcome.TRANSIENT
        }
    }

    /**
     * One ongoing notification for the whole book. A multi-track book shows a
     * determinate bar by completed tracks (which advances regardless of whether
     * the server reports a content length); a single-file book whose length is
     * unknown shows an animated indeterminate bar so it still reads as active
     * rather than stuck at 0%. setOnlyAlertOnce keeps the frequent updates silent.
     */
    private fun foregroundInfo(itemId: String, title: String, done: Int, total: Int, trackFraction: Double): ForegroundInfo {
        val indeterminate = total <= 1 && trackFraction <= 0.0
        val overall = if (total > 0) ((done + trackFraction.coerceIn(0.0, 1.0)) / total).coerceIn(0.0, 1.0) else 0.0

        // A Cancel action that stops the download straight from the shade.
        val cancelIntent = Intent(applicationContext, DownloadActionReceiver::class.java).apply {
            action = DownloadActionReceiver.ACTION_CANCEL
            putExtra(DownloadActionReceiver.EXTRA_ITEM_ID, itemId)
        }
        val cancelPending = PendingIntent.getBroadcast(
            applicationContext,
            itemId.hashCode(),
            cancelIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val notification = NotificationCompat.Builder(applicationContext, KitziApplication.AUDIO_CHANNEL_ID)
            .setContentTitle("Downloading")
            .setContentText(if (total > 1) "$title · ${(done + 1).coerceAtMost(total)} of $total" else title)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setProgress(100, (overall * 100).toInt(), indeterminate)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Cancel", cancelPending)
            .build()

        // Per-book id: books download independently now, so a shared id would let
        // two concurrent downloads overwrite each other's progress notification.
        val notificationId = NOTIFICATION_ID_BASE + (itemId.hashCode().mod(1000))

        return if (android.os.Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(
                notificationId, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(notificationId, notification)
        }
    }

    companion object {
        private const val TAG = "BookDownloadWorker"
        private const val NOTIFICATION_ID_BASE = 4242
        private const val PROGRESS_EVERY = 512 * 1024L
        private const val MAX_ATTEMPTS = 3

        const val KEY_ITEM_ID = "itemId"
        const val KEY_TITLE = "title"
        const val KEY_LIBRARY_ID = "libraryId"
    }
}
