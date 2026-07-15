package com.bennybar.kitzi.downloads

import android.app.NotificationManager
import android.content.Context
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ForegroundInfo
import androidx.work.WorkerParameters
import com.bennybar.kitzi.KitziApplication
import com.bennybar.kitzi.R
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.DownloadStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File

/**
 * Downloads exactly one track.
 *
 * One track per worker, run through a single serial chain, is the whole queue.
 * There is deliberately no app-level queue on top: a second queue layered over
 * the platform's is what made a queued book never start.
 */
class TrackDownloadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        Services.init(applicationContext)

        val itemId = inputData.getString(KEY_ITEM_ID) ?: return@withContext Result.failure()
        val trackIndex = inputData.getInt(KEY_TRACK_INDEX, -1)
        val fileId = inputData.getString(KEY_FILE_ID) ?: return@withContext Result.failure()
        val filename = inputData.getString(KEY_FILENAME) ?: return@withContext Result.failure()
        val title = inputData.getString(KEY_TITLE).orEmpty()

        val dao = Services.downloadsDao()
        val dir = Services.downloadPaths.itemDir(itemId).apply { mkdirs() }
        val target = File(dir, filename)

        if (target.exists() && target.length() > 0) {
            dao.setStatus(itemId, trackIndex, DownloadStatus.COMPLETE)
            return@withContext Result.success()
        }

        runCatching { setForeground(foregroundInfo(title)) }

        dao.setStatus(itemId, trackIndex, DownloadStatus.RUNNING)

        val url = "${Services.session.baseUrl}/api/items/$itemId/file/$fileId/download"
        val partial = File(dir, "$filename.part")

        return@withContext try {
            // The token is fetched now, not baked in at enqueue time. A long queue
            // outliving its access token is otherwise a wall of 401s; the auth
            // interceptor on this client also refreshes and retries on 401.
            val request = Request.Builder().url(url).get().build()

            Services.httpClient.newCall(request).execute().use { resp ->
                if (!resp.isSuccessful) {
                    dao.setStatus(itemId, trackIndex, DownloadStatus.FAILED)
                    // 4xx won't fix itself; 5xx and network errors might.
                    return@withContext if (resp.code in 400..499) Result.failure() else Result.retry()
                }

                val body = resp.body ?: return@withContext Result.retry()
                val total = body.contentLength()
                var written = 0L

                body.byteStream().use { input ->
                    partial.outputStream().use { output ->
                        val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                        while (true) {
                            if (isStopped) {
                                partial.delete()
                                dao.setStatus(itemId, trackIndex, DownloadStatus.CANCELED)
                                return@withContext Result.failure()
                            }
                            val read = input.read(buffer)
                            if (read == -1) break
                            output.write(buffer, 0, read)
                            written += read
                            if (written % PROGRESS_EVERY < read) {
                                dao.setProgress(itemId, trackIndex, written, total, DownloadStatus.RUNNING)
                            }
                        }
                    }
                }

                // Only publish under the real name once the bytes are all there, so a
                // half-written file can never be mistaken for a finished track. If the
                // rename fails, the track is NOT complete — recording it as COMPLETE
                // would leave a book that plays a missing file.
                if (!partial.renameTo(target) || !target.exists() || target.length() <= 0) {
                    partial.delete()
                    dao.setStatus(itemId, trackIndex, DownloadStatus.FAILED)
                    return@withContext if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
                }
                dao.setProgress(itemId, trackIndex, target.length(), target.length(), DownloadStatus.COMPLETE)
                Result.success()
            }
        } catch (e: Exception) {
            Log.w(TAG, "download failed: $itemId/$filename", e)
            partial.delete()
            dao.setStatus(itemId, trackIndex, DownloadStatus.FAILED)
            if (runAttemptCount < MAX_ATTEMPTS) Result.retry() else Result.failure()
        }
    }

    private fun foregroundInfo(title: String): ForegroundInfo {
        val notification = NotificationCompat.Builder(applicationContext, KitziApplication.AUDIO_CHANNEL_ID)
            .setContentTitle("Downloading")
            .setContentText(title)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .build()

        return if (android.os.Build.VERSION.SDK_INT >= 29) {
            ForegroundInfo(
                NOTIFICATION_ID, notification,
                android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "TrackDownloadWorker"
        private const val NOTIFICATION_ID = 4242
        private const val PROGRESS_EVERY = 512 * 1024L
        private const val MAX_ATTEMPTS = 3

        const val KEY_ITEM_ID = "itemId"
        const val KEY_TRACK_INDEX = "trackIndex"
        const val KEY_FILE_ID = "fileId"
        const val KEY_FILENAME = "filename"
        const val KEY_TITLE = "title"
    }
}
