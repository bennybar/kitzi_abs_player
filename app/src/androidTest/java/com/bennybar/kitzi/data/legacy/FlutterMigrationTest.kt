package com.bennybar.kitzi.data.legacy

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * Proves the Flutter-era state is actually readable from the Kotlin app on a
 * real device, which is the one thing unit tests cannot establish: decrypting
 * the refresh token depends on the AndroidKeyStore entry the Flutter app
 * created, and that only exists on a device where the Flutter app ran.
 *
 * PRECONDITION: run on a device/emulator where the Flutter build of Kitzi has
 * been installed and logged in, then updated to this build (same applicationId
 * and signing key, so the data dir and keystore carry over). Without that this
 * test is expected to fail — that is the point.
 */
@RunWith(AndroidJUnit4::class)
class FlutterMigrationTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val prefs = FlutterPrefs(context)

    @Test
    fun carriesOverTheServerAndSession() {
        val baseUrl = prefs.getString(FlutterPrefs.KEY_BASE_URL)
        val access = prefs.getString(FlutterPrefs.KEY_ACCESS_TOKEN)
        val expiry = prefs.getString(FlutterPrefs.KEY_ACCESS_EXPIRY)

        Log.i(TAG, "baseUrl=$baseUrl accessLen=${access?.length} expiry=$expiry")

        assertNotNull("no server URL carried over", baseUrl)
        assertTrue("server URL looks wrong: $baseUrl", baseUrl!!.startsWith("http"))
        assertNotNull("no access token carried over", access)
        assertTrue("access token is empty", access!!.isNotEmpty())
    }

    @Test
    fun decryptsTheRefreshTokenFromFlutterSecureStorage() {
        val secure = FlutterSecureStorage(context)

        val refresh = secure.read(FlutterSecureStorage.KEY_REFRESH_TOKEN)

        // Don't log the token itself; its shape is enough to prove decryption.
        Log.i(TAG, "refresh token decrypted: len=${refresh?.length} dots=${refresh?.count { it == '.' }}")

        assertNotNull("refresh token did not decrypt — users would be logged out", refresh)
        assertTrue("refresh token decrypted to empty", refresh!!.isNotEmpty())
        // ABS issues JWTs; a successful AES-CBC decrypt of the wrong key would
        // not produce three dot-separated segments.
        assertTrue("decrypted value is not a JWT, so the decrypt is suspect", refresh.count { it == '.' } == 2)
    }

    @Test
    fun findsTheExistingDownloadsInPlace() {
        val paths = DownloadPaths(context, prefs)

        val libraryId = paths.currentLibraryId()
        val items = paths.downloadedItemIds()
        val totalMb = paths.totalBytes() / (1024 * 1024)

        Log.i(TAG, "documents=${paths.documentsDir()}")
        Log.i(TAG, "library=$libraryId subfolder=${paths.baseSubfolder()}")
        Log.i(TAG, "downloaded items=${items.size} total=${totalMb}MB")

        assertTrue(
            "documents dir must be the Flutter one (app_flutter), was ${paths.documentsDir()}",
            paths.documentsDir().name == "app_flutter",
        )
        assertTrue("found no downloaded books — users would have to re-download", items.isNotEmpty())
        assertTrue("downloads are empty on disk", paths.totalBytes() > 0)
    }

    private companion object {
        const val TAG = "FlutterMigrationTest"
    }
}
