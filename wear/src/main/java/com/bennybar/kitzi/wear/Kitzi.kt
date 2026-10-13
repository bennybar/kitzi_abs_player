package com.bennybar.kitzi.wear

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

/** The watch app's state and services, one per process. */
class Kitzi private constructor(context: Context) {
    val app: Context = context.applicationContext
    val store = Store(app)
    val api = Api(store)
    val downloads = Downloads(app, store)
    val player = WearPlayer(app, this)

    val signedIn = MutableStateFlow(store.signedIn)
    /** Continue Listening, as last fetched (shown at once, offline too). */
    val shelf = MutableStateFlow(store.shelf)
    val refreshing = MutableStateFlow(false)
    /** Whether the last refresh reached the server; null before the first. */
    val online = MutableStateFlow<Boolean?>(null)

    /** Re-fetches Continue Listening. Positions saved on the watch since win over older server ones. */
    suspend fun refreshShelf(): Boolean {
        if (!store.signedIn) return false
        refreshing.value = true
        try {
            val books = withContext(Dispatchers.IO) { api.continueListening() }
            online.value = books != null
            if (books == null) return false
            val merged = books.map { b ->
                val local = store.position(b.id)
                if (local != null && local.savedAt > b.lastUpdate) b.copy(currentTimeSec = local.sec) else b
            }
            shelf.value = merged
            store.shelf = merged
            return true
        } finally {
            refreshing.value = false
        }
    }

    /** The watch's own newer position for a book on the shelf (after listening here). */
    fun updateShelfPosition(itemId: String, sec: Double) {
        val now = System.currentTimeMillis()
        val updated = shelf.value.map { if (it.id == itemId) it.copy(currentTimeSec = sec, lastUpdate = now) else it }
            .sortedByDescending { it.lastUpdate }
        shelf.value = updated
        store.shelf = updated
    }

    /**
     * Sends positions saved while offline. A newer position on the server (listened
     * on another device since) wins and is kept. Skips the book that's playing: its
     * own reports carry it. True when nothing is left pending.
     */
    suspend fun flushPending(): Boolean = withContext(Dispatchers.IO) {
        val playing = player.playingItemId()
        var clean = true
        for (id in store.pendingIds()) {
            if (id == playing) continue
            val local = store.position(id) ?: continue
            val server = runCatching { api.progress(id) }.getOrNull()
            if (server != null && server.second > local.savedAt) {
                store.savePosition(id, local.copy(pending = false))
                continue
            }
            val duration = shelf.value.firstOrNull { it.id == id }?.durationSec
                ?: downloads.downloaded(id)?.book?.durationSec
            if (api.saveProgress(Report(id, local.sec, duration, local.finished, true, null))) {
                if (store.position(id)?.savedAt == local.savedAt) store.savePosition(id, local.copy(pending = false))
            } else clean = false
        }
        clean
    }

    /** Everything the "Sync" button does: report the playing book, push what's pending, re-fetch the shelf. */
    suspend fun syncNow(): Boolean {
        val reported = player.reportNow()
        val flushed = flushPending()
        val fetched = refreshShelf()
        return reported != false && flushed && fetched
    }

    suspend fun signOut() {
        player.stop()
        runCatching { flushPending() }
        store.signOut()
        shelf.value = emptyList()
        signedIn.value = false
    }

    companion object {
        @Volatile private var instance: Kitzi? = null

        fun init(context: Context): Kitzi = instance ?: synchronized(this) {
            instance ?: Kitzi(context).also { instance = it }
        }

        val get: Kitzi get() = instance ?: error("Kitzi.init not called")
    }
}

/** Pushes positions saved offline once there's a network. */
class SyncWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        val k = Kitzi.init(applicationContext)
        if (!k.store.signedIn) return Result.success()
        return if (runCatching { k.flushPending() }.getOrDefault(false)) Result.success() else Result.retry()
    }

    companion object {
        fun enqueue(context: Context) {
            val request = OneTimeWorkRequestBuilder<SyncWorker>()
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 1, TimeUnit.MINUTES)
                .build()
            runCatching {
                WorkManager.getInstance(context).enqueueUniqueWork("sync", ExistingWorkPolicy.KEEP, request)
            }.onFailure { Log.w("SyncWorker", "couldn't schedule", it) }
        }
    }
}
