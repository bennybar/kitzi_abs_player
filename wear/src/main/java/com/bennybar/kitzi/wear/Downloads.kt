package com.bennybar.kitzi.wear

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import okhttp3.Request
import java.io.File
import kotlin.coroutines.resume

/** A book saved on the watch: what's needed to play it with no network. */
@Serializable
data class DownloadedBook(val book: Book, val tracks: List<TrackFile>, val chapters: List<Chapter>)

sealed interface DownloadState {
    data object None : DownloadState
    /** Waiting for a network (Wi-Fi, if downloads are Wi-Fi only). */
    data object Waiting : DownloadState
    data class Running(val fraction: Float) : DownloadState
    data object Failed : DownloadState
    data object Done : DownloadState
}

class Downloads(private val context: Context, private val store: Store) {

    private val root = File(context.filesDir, "books")
    private val _states = MutableStateFlow<Map<String, DownloadState>>(emptyMap())
    val states: StateFlow<Map<String, DownloadState>> = _states.asStateFlow()

    init {
        // What's already on the watch.
        _states.value = root.listFiles().orEmpty()
            .filter { File(it, MANIFEST).exists() }
            .associate { it.name to DownloadState.Done }
        // Downloads still queued from before the app was last closed.
        runCatching {
            WorkManager.getInstance(context).getWorkInfosByTag(TAG).get()
                .filter { !it.state.isFinished }
                .forEach { info ->
                    info.tags.firstOrNull { it.startsWith("item:") }?.removePrefix("item:")
                        ?.let { set(it, DownloadState.Waiting) }
                }
        }
    }

    fun state(itemId: String): DownloadState = _states.value[itemId] ?: DownloadState.None

    internal fun set(itemId: String, state: DownloadState) {
        _states.value = _states.value + (itemId to state)
    }

    fun dir(itemId: String) = File(root, itemId)

    fun downloaded(itemId: String): DownloadedBook? = File(dir(itemId), MANIFEST).takeIf { it.exists() }
        ?.let { runCatching { Store.json.decodeFromString(DownloadedBook.serializer(), it.readText()) }.getOrNull() }

    fun coverFile(itemId: String): File? = File(dir(itemId), COVER).takeIf { it.exists() }

    fun start(itemId: String) {
        val request = OneTimeWorkRequestBuilder<DownloadWorker>()
            .setInputData(workDataOf(KEY_ITEM to itemId))
            .addTag(TAG).addTag("item:$itemId")
            .setConstraints(
                Constraints.Builder()
                    .setRequiredNetworkType(if (store.wifiOnly) NetworkType.UNMETERED else NetworkType.CONNECTED)
                    .setRequiresStorageNotLow(true)
                    .build()
            )
            .build()
        WorkManager.getInstance(context).enqueueUniqueWork("download:$itemId", ExistingWorkPolicy.KEEP, request)
        set(itemId, DownloadState.Waiting)
    }

    fun cancel(itemId: String) {
        WorkManager.getInstance(context).cancelUniqueWork("download:$itemId")
        dir(itemId).deleteRecursively()
        set(itemId, DownloadState.None)
    }

    fun delete(itemId: String) = cancel(itemId)

    fun usedBytes(): Long = root.walkTopDown().filter { it.isFile }.sumOf { it.length() }

    companion object {
        const val TAG = "download"
        const val KEY_ITEM = "item"
        const val MANIFEST = "book.json"
        const val COVER = "cover.jpg"
    }
}

/**
 * Downloads one book. Wear OS sends app traffic over the Bluetooth link to the
 * phone when it can, which is far too slow for audiobooks, so this asks for Wi-Fi
 * (or cellular, unless downloads are Wi-Fi only), pins the transfer to it, and
 * waits rather than falling back to Bluetooth.
 */
class DownloadWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val k = Kitzi.init(applicationContext)
        val itemId = inputData.getString(Downloads.KEY_ITEM) ?: return Result.failure()
        if (!k.store.signedIn) return Result.failure()
        runCatching { setForeground(foregroundInfo("Downloading…", 0f)) }

        val fast = FastNetwork(applicationContext)
        // Wi-Fi or LTE only, never the Bluetooth link through the phone (far too slow
        // for audiobooks). None available: wait and try again later.
        val network = fast.acquire(wifiOnly = k.store.wifiOnly) ?: run {
            fast.release()
            k.downloads.set(itemId, DownloadState.Waiting)
            return Result.retry()
        }
        val http = k.api.clientOn(network)
        try {
            k.downloads.set(itemId, DownloadState.Running(0f))
            val item = k.api.item(itemId, http) ?: return retryOrFail(k, itemId)
            val media = item["media"] as? JsonObject ?: return fail(k, itemId)
            val meta = media["metadata"] as? JsonObject
            val book = Book(
                id = itemId,
                title = meta?.str("title") ?: "Audiobook",
                author = meta?.str("authorName"),
                durationSec = media.num("duration") ?: 0.0,
            )
            val tracks = (media["tracks"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                .sortedBy { it.num("index") ?: 0.0 }
            if (tracks.isEmpty()) return fail(k, itemId)
            // Bytes, for the progress: the audio files carry their sizes.
            val sizes = (media["audioFiles"] as? JsonArray).orEmpty().mapNotNull { it as? JsonObject }
                .associate { (it.num("index")?.toInt() ?: -1) to ((it["metadata"] as? JsonObject)?.num("size") ?: 0.0) }
            val totalBytes = sizes.values.sum().coerceAtLeast(1.0)
            var doneBytes = 0.0

            val dir = k.downloads.dir(itemId).apply { mkdirs() }
            val base = k.store.baseUrl!!
            val files = tracks.mapIndexed { i, t ->
                val ext = (t["metadata"] as? JsonObject)?.str("ext")?.trimStart('.') ?: "mp3"
                val target = File(dir, "track$i.$ext")
                val contentUrl = t.str("contentUrl") ?: return fail(k, itemId)
                val size = sizes[t.num("index")?.toInt() ?: -1] ?: 0.0
                if (!target.exists()) {
                    val part = File(dir, "track$i.$ext.part")
                    val url = (if (contentUrl.startsWith("http")) contentUrl else base + contentUrl)
                    http.newCall(Request.Builder().url(url).build()).execute().use { resp ->
                        if (!resp.isSuccessful) return retryOrFail(k, itemId)
                        val body = resp.body ?: return retryOrFail(k, itemId)
                        body.byteStream().use { input ->
                            part.outputStream().use { out ->
                                val buf = ByteArray(64 * 1024)
                                var copied = 0L
                                var lastReport = 0L
                                while (true) {
                                    if (isStopped) return Result.failure()
                                    val n = input.read(buf)
                                    if (n < 0) break
                                    out.write(buf, 0, n)
                                    copied += n
                                    if (copied - lastReport > 512 * 1024) {
                                        lastReport = copied
                                        val f = ((doneBytes + copied) / totalBytes).toFloat().coerceIn(0f, 1f)
                                        k.downloads.set(itemId, DownloadState.Running(f))
                                        runCatching { setForeground(foregroundInfo(book.title, f)) }
                                    }
                                }
                            }
                        }
                    }
                    part.renameTo(target)
                }
                doneBytes += size
                TrackFile(
                    index = i,
                    url = target.toURI().toString(),
                    mimeType = t.str("mimeType") ?: "audio/mpeg",
                    durationSec = t.num("duration") ?: 0.0,
                )
            }
            // The cover, for the player and the media controls offline.
            runCatching {
                http.newCall(Request.Builder().url(k.api.coverUrl(itemId)).build()).execute().use { resp ->
                    if (resp.isSuccessful) resp.body?.bytes()?.let { File(dir, Downloads.COVER).writeBytes(it) }
                }
            }
            val manifest = DownloadedBook(book, files, Api.chapters(media["chapters"]))
            File(dir, Downloads.MANIFEST).writeText(Store.json.encodeToString(DownloadedBook.serializer(), manifest))
            k.downloads.set(itemId, DownloadState.Done)
            return Result.success()
        } catch (e: java.io.IOException) {
            Log.w("DownloadWorker", "download $itemId interrupted", e)
            return retryOrFail(k, itemId)
        } finally {
            fast.release()
        }
    }

    private fun fail(k: Kitzi, itemId: String): Result {
        k.downloads.set(itemId, DownloadState.Failed)
        return Result.failure()
    }

    /** A network problem: try again (resuming at the first missing track), a few times. */
    private fun retryOrFail(k: Kitzi, itemId: String): Result =
        if (runAttemptCount < 4) {
            k.downloads.set(itemId, DownloadState.Waiting)
            Result.retry()
        } else fail(k, itemId)

    private fun foregroundInfo(title: String, fraction: Float): ForegroundInfo {
        val nm = applicationContext.getSystemService(NotificationManager::class.java)
        if (nm.getNotificationChannel(CHANNEL) == null) {
            nm.createNotificationChannel(NotificationChannel(CHANNEL, "Downloads", NotificationManager.IMPORTANCE_LOW))
        }
        val n = NotificationCompat.Builder(applicationContext, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setProgress(100, (fraction * 100).toInt(), fraction == 0f)
            .setOngoing(true)
            .build()
        return ForegroundInfo(id.hashCode(), n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
    }

    private companion object {
        const val CHANNEL = "downloads"
    }
}

/** Holds a Wi-Fi / cellular network for the duration of a transfer. */
class FastNetwork(context: Context) {
    private val cm = context.getSystemService(ConnectivityManager::class.java)
    private var callback: ConnectivityManager.NetworkCallback? = null

    /** A Wi-Fi (or cellular) network, or null if none came up in time. */
    suspend fun acquire(wifiOnly: Boolean): Network? = withTimeoutOrNull(15_000) {
        suspendCancellableCoroutine { cont ->
            val cb = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (cont.isActive) cont.resume(network)
                }
            }
            callback = cb
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
                .apply { if (!wifiOnly) addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR) }
                .build()
            runCatching { cm.requestNetwork(request, cb) }.onFailure { if (cont.isActive) cont.resume(null) }
        }
    }

    fun release() {
        callback?.let { runCatching { cm.unregisterNetworkCallback(it) } }
        callback = null
    }
}
