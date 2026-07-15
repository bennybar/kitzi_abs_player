package com.bennybar.kitzi.data.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.db.BookSort
import java.util.concurrent.TimeUnit

/**
 * Periodic background library refresh (every ~3h, connectivity-gated), matching
 * the Flutter background_sync_service. Pulls the first couple of "recently
 * updated" pages so new/edited books show up without a manual refresh.
 */
class LibrarySyncWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        Services.init(applicationContext)
        if (Services.session.baseUrl == null || !Services.session.hasFreshAccessToken(0)) {
            return Result.success() // not signed in / no valid token: nothing to do
        }
        return runCatching {
            Services.books.fetchPage(1, 50, BookSort.UPDATED_DESC)
            Services.books.fetchPage(2, 50, BookSort.UPDATED_DESC)
            Result.success()
        }.getOrElse { Result.retry() }
    }

    companion object {
        private const val NAME = "library_sync"

        fun schedule(context: Context) {
            val request = PeriodicWorkRequestBuilder<LibrarySyncWorker>(3, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()
                )
                .build()
            WorkManager.getInstance(context)
                .enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
