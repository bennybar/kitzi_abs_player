package com.bennybar.kitzi.playback

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import java.io.File

/**
 * A process-wide on-disk cache for streamed (non-downloaded) audio, so replaying
 * or re-seeking a streamed book doesn't re-download bytes. Size is the
 * `streaming_cache_max_bytes_mb` setting (200MB–2GB, default 512MB), LRU-evicted
 * — matching the Flutter streaming_cache_service.
 *
 * SimpleCache must be a singleton per directory per process, so it lives here.
 */
@androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
object StreamCache {
    @Volatile private var instance: SimpleCache? = null

    fun get(context: Context, prefs: FlutterPrefs): SimpleCache =
        instance ?: synchronized(this) {
            instance ?: build(context, prefs).also { instance = it }
        }

    private fun build(context: Context, prefs: FlutterPrefs): SimpleCache {
        val maxMb = prefs.getInt("streaming_cache_max_bytes_mb", 512).coerceIn(200, 2048)
        val dir = File(context.cacheDir, "media_stream_cache")
        val evictor = LeastRecentlyUsedCacheEvictor(maxMb * 1024L * 1024L)
        return SimpleCache(dir, evictor, StandaloneDatabaseProvider(context))
    }
}
