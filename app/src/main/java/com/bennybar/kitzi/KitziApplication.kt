package com.bennybar.kitzi

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import com.bennybar.kitzi.data.Analytics

class KitziApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createAudioNotificationChannel()
        // Anonymous daily-active-user ping, as the Flutter app does on startup.
        Analytics.init(this)
        Analytics.logAppOpen()
        // Periodic background library refresh (~3h).
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
