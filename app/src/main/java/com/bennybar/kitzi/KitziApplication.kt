package com.bennybar.kitzi

import android.app.Application
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context

class KitziApplication : Application() {

    override fun onCreate() {
        super.onCreate()
        createAudioNotificationChannel()
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
