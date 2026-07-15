package com.bennybar.kitzi.playback

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.bennybar.kitzi.MainActivity

/**
 * An OPTIONAL, promotable "now playing" notification, separate from the Media3
 * media notification.
 *
 * Media notifications use MediaStyle, which Android 16 refuses to promote to a
 * "Live Update" — the Samsung Now Bar status-bar/AOD pill shown while using other
 * apps. A plain ongoing notification WITH setRequestPromotedOngoing CAN be
 * promoted, so this posts one purely to surface the pill. The cost is a second
 * notification in the shade, so it's gated behind a setting and off by default.
 */
class NowPlayingLiveUpdate(private val context: Context) {

    private val nm = NotificationManagerCompat.from(context)

    private fun ensureChannel() {
        if (nm.getNotificationChannel(CHANNEL) != null) return
        // IMPORTANCE_LOW — never MIN, which would disqualify the notification from
        // being promoted — and silent.
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL, "Now playing", NotificationManager.IMPORTANCE_LOW).apply {
                description = "A live \"now playing\" capsule (Samsung Now Bar)"
                setSound(null, null)
                enableVibration(false)
            }
        )
    }

    fun update(title: String, text: String?, totalSec: Int, positionSec: Int) {
        if (context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) return
        ensureChannel()

        val open = PendingIntent.getActivity(
            context, 0,
            Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Standard style (no MediaStyle/custom view), ongoing, promotion requested —
        // the exact shape Android 16 allows to become a Live Update.
        val builder = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setRequestPromotedOngoing(true)
        if (totalSec > 0) builder.setProgress(totalSec, positionSec.coerceIn(0, totalSec), false)

        runCatching { nm.notify(NOTIF_ID, builder.build()) }
    }

    fun clear() = nm.cancel(NOTIF_ID)

    private companion object {
        const val CHANNEL = "com.bennybar.kitzi.channel.liveupdate"
        const val NOTIF_ID = 4210
    }
}
