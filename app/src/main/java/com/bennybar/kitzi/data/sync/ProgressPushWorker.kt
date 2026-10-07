package com.bennybar.kitzi.data.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.bennybar.kitzi.data.Services

/**
 * Pushes positions (and bookmark edits) saved while the server couldn't be reached,
 * once there's a network again — offline listening used to reach the server only
 * the next time that book was played online. Enqueued when a report fails.
 */
class ProgressPushWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        Services.init(applicationContext)
        if (Services.session.baseUrl == null || !Services.auth.hasValidSession()) return Result.success()
        return runCatching {
            Services.books.ensureLibrary()
            Services.playback.flushPendingProgress()
            Services.books.flushPendingBookmarks()
            Result.success()
        }.getOrElse { e -> if (e is java.io.IOException) Result.retry() else Result.failure() }
    }

    companion object {
        private const val NAME = "progress_push"

        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<ProgressPushWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            // KEEP: one waiting push covers every failed report until it runs.
            WorkManager.getInstance(context).enqueueUniqueWork(NAME, ExistingWorkPolicy.KEEP, request)
        }
    }
}
