package com.bennybar.kitzi.data.sync

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.bennybar.kitzi.data.Radar
import com.bennybar.kitzi.data.Services
import java.util.concurrent.TimeUnit

/** New releases and Shelfarr arrivals, checked in the background twice a day while either is on. */
class RadarWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        Services.init(applicationContext)
        if (Services.session.baseUrl == null || !Services.auth.hasValidSession()) return Result.success()
        Radar.checkAll(background = true)
        return Result.success()
    }

    companion object {
        private const val NAME = "radar"

        /** Scheduled while either notification is on, cancelled when both are off. */
        fun schedule(context: Context) {
            val wm = WorkManager.getInstance(context)
            val prefs = com.bennybar.kitzi.data.legacy.FlutterPrefs(context)
            if (!prefs.getBoolean(Radar.KEY_ON, false) && !prefs.getBoolean(Radar.KEY_SHELFARR, false)) {
                wm.cancelUniqueWork(NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<RadarWorker>(12, TimeUnit.HOURS)
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .setRequiresBatteryNotLow(true)
                        .build()
                )
                .build()
            wm.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
        }
    }
}
