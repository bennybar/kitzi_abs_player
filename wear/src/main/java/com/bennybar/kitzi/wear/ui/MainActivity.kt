package com.bennybar.kitzi.wear.ui

import android.Manifest
import android.content.ComponentName
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.media3.session.MediaController
import androidx.media3.session.SessionToken
import androidx.wear.compose.material3.AppScaffold
import androidx.wear.compose.material3.MaterialTheme
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import coil.Coil
import coil.ImageLoader
import com.bennybar.kitzi.wear.Kitzi
import com.bennybar.kitzi.wear.PlaybackService
import com.google.common.util.concurrent.ListenableFuture

class MainActivity : ComponentActivity() {

    private var controller: ListenableFuture<MediaController>? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val k = Kitzi.init(this)
        // Covers through the signed-in client (the cover endpoint needs the token).
        Coil.setImageLoader(ImageLoader.Builder(this).okHttpClient(k.api.client).crossfade(true).build())
        if (Build.VERSION.SDK_INT >= 33) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 0)
        }
        setContent { MaterialTheme { KitziApp(k) } }
    }

    // Connecting a controller starts the media service, which keeps playback going
    // (and shows the media controls) once the app is closed.
    override fun onStart() {
        super.onStart()
        controller = MediaController.Builder(this, SessionToken(this, ComponentName(this, PlaybackService::class.java))).buildAsync()
    }

    override fun onStop() {
        controller?.let { MediaController.releaseFuture(it) }
        controller = null
        super.onStop()
    }
}

@Composable
private fun KitziApp(k: Kitzi) {
    val signedIn by k.signedIn.collectAsState()
    val nav = rememberSwipeDismissableNavController()
    AppScaffold {
        if (!signedIn) {
            LoginScreen(k)
            return@AppScaffold
        }
        LaunchedEffect(Unit) {
            k.flushPending()
            k.refreshShelf()
        }
        SwipeDismissableNavHost(navController = nav, startDestination = "home") {
            composable("home") {
                HomeScreen(
                    k,
                    onOpenBook = { nav.navigate("book/$it") },
                    onOpenPlayer = { nav.navigate("player") },
                    onOpenSettings = { nav.navigate("settings") },
                )
            }
            composable("book/{id}") { entry ->
                BookScreen(k, entry.arguments?.getString("id").orEmpty(), onPlaying = {
                    nav.navigate("player") { popUpTo("home") }
                })
            }
            composable("player") { PlayerScreen(k) }
            composable("settings") { SettingsScreen(k) }
        }
    }
}
