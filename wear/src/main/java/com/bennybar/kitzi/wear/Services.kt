package com.bennybar.kitzi.wear

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.util.Log
import androidx.media3.session.MediaSession
import androidx.media3.session.MediaSessionService
import com.bennybar.kitzi.wear.ui.MainActivity
import com.google.android.gms.wearable.CapabilityClient
import com.google.android.gms.wearable.MessageEvent
import com.google.android.gms.wearable.Wearable
import com.google.android.gms.wearable.WearableListenerService
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.tasks.await
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull

/** The media session: system media controls, headphone buttons, the ongoing-media chip. */
class PlaybackService : MediaSessionService() {
    private var session: MediaSession? = null
    private val scope = kotlinx.coroutines.MainScope()

    @androidx.annotation.OptIn(markerClass = [androidx.media3.common.util.UnstableApi::class])
    override fun onCreate() {
        super.onCreate()
        val k = Kitzi.init(this)
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        // Play from headphones or the system controls resumes through the same
        // server check as the app's play button.
        val player = object : androidx.media3.common.ForwardingPlayer(k.player.exo) {
            override fun play() {
                scope.launch { k.player.resumeLoaded() }
            }
        }
        session = MediaSession.Builder(this, player).setSessionActivity(open).build()
    }

    override fun onGetSession(controllerInfo: MediaSession.ControllerInfo): MediaSession? = session

    override fun onTaskRemoved(rootIntent: Intent?) {
        if (session?.player?.isPlaying != true) stopSelf()
    }

    override fun onDestroy() {
        scope.cancel()
        session?.release() // the player lives on in Kitzi
        session = null
        super.onDestroy()
    }
}

/** Signing in through the phone app (see the phone's WatchLoginService). */
object PhoneLogin {
    /** The phone's answer: null = signed in, else why not. */
    val replies = MutableSharedFlow<String?>(extraBufferCapacity = 1)

    /** Asks the phone. False when no phone with Kitzi is reachable. */
    suspend fun request(context: Context): Boolean {
        val nodes = runCatching {
            Wearable.getCapabilityClient(context)
                .getCapability("kitzi_phone", CapabilityClient.FILTER_REACHABLE).await().nodes
        }.onFailure { Log.w("PhoneLogin", "capability lookup failed", it) }.getOrNull().orEmpty()
        if (nodes.isEmpty()) return false
        val client = Wearable.getMessageClient(context)
        return nodes.any { node ->
            runCatching { client.sendMessage(node.id, "/kitzi/login-request", ByteArray(0)).await() }.isSuccess
        }
    }
}

class PhoneLoginListener : WearableListenerService() {
    override fun onMessageReceived(event: MessageEvent) {
        if (event.path != "/kitzi/login") return
        val k = Kitzi.init(this)
        val reply = Api.parse(String(event.data)) as? JsonObject
        val error = reply?.str("error")
        val base = reply?.str("baseUrl")
        val token = reply?.str("token")
        if (error != null || base == null || token == null) {
            PhoneLogin.replies.tryEmit(
                when (error) {
                    "signed_out" -> "Sign in to Kitzi on your phone first"
                    else -> "Your server didn't allow this. Sign in on the watch instead."
                }
            )
            return
        }
        val headers = (reply["headers"] as? JsonObject).orEmpty()
            .mapNotNull { (key, v) -> (v as? JsonPrimitive)?.contentOrNull?.let { key to it } }.toMap()
        k.store.signIn(base, token, null, reply.str("username"), headers)
        k.signedIn.value = true
        PhoneLogin.replies.tryEmit(null)
    }
}
