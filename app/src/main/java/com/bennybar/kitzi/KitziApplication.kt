package com.bennybar.kitzi

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import coil.ImageLoader
import coil.ImageLoaderFactory
import com.bennybar.kitzi.data.Analytics
import com.bennybar.kitzi.data.Services

class KitziApplication : Application(), ImageLoaderFactory {

    /**
     * Covers and author portraits load through the app's own HTTP client, which
     * adds the Bearer token and any custom headers (Cloudflare Access and similar).
     * Coil's default client sent neither: covers needed the token in their URL, and
     * with a Zero-Trust proxy in front of the server they didn't load at all.
     */
    override fun newImageLoader(): ImageLoader {
        Services.init(this)
        return ImageLoader.Builder(this)
            .okHttpClient { Services.httpClient }
            .build()
    }

    override fun onCreate() {
        super.onCreate()
        createAudioNotificationChannel()
        Analytics.init(this)
        // The "app open" ping is sent from MainActivity: this runs on every process
        // start, including background ones (the sync worker, media buttons, Android
        // Auto), which cost a request each and inflated the daily-user count.
        // Periodic background library refresh (twice a day).
        com.bennybar.kitzi.data.sync.LibrarySyncWorker.schedule(this)
    }

    /**
     * Reuses the Flutter app's channel id verbatim. Users who muted or otherwise
     * configured this channel keep that setting across the update — a new id
     * would silently reset it for everyone.
     */
    private fun createAudioNotificationChannel() {
        val channel = NotificationChannel(
            AUDIO_CHANNEL_ID,
            getString(R.string.app_name),
            NotificationManager.IMPORTANCE_LOW,
        )
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    companion object {
        const val AUDIO_CHANNEL_ID = "com.bennybar.kitzi.channel.audio"
    }
}
