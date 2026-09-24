package com.bennybar.kitzi.playback

import android.content.ContentProvider
import android.content.ContentValues
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Log
import com.bennybar.kitzi.BuildConfig
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.BookMapper
import okhttp3.Request
import java.io.File
import java.io.FileNotFoundException

/**
 * Book covers for everything outside the app: the media notification, the lock
 * screen, Samsung's Now Bar, Android Auto.
 *
 * The media session used to hand those the server's cover URL with the access
 * token in its query string — and since the playback service is exported (Auto
 * needs that), any installed app could connect as a controller, read the artwork
 * URI, and walk away with a working token for the user's server. A content URI
 * carries no credential: this provider fetches the cover with the app's own
 * authenticated client and serves the bytes. Covers themselves aren't sensitive,
 * so the provider is readable by anyone, which is also what Auto requires.
 */
class CoverProvider : ContentProvider() {

    override fun onCreate(): Boolean = true

    override fun getType(uri: Uri): String = "image/jpeg"

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("read-only")
        val ctx = context ?: throw FileNotFoundException(uri.toString())
        // A library item id, and nothing that could walk out of the covers directory.
        val itemId = uri.lastPathSegment?.takeIf { ID.matches(it) }
            ?: throw FileNotFoundException(uri.toString())
        Services.init(ctx)

        // A downloaded book already has a crisp cover on disk, and works offline.
        val downloaded = File(Services.downloadPaths.itemDir(itemId), "cover.jpg")
        if (downloaded.isFile) return open(downloaded)

        val cached = File(File(ctx.cacheDir, "covers"), "$itemId.jpg")
        if (!cached.isFile || System.currentTimeMillis() - cached.lastModified() > MAX_AGE_MS) {
            fetch(itemId, cached)
        }
        if (cached.isFile) return open(cached)
        throw FileNotFoundException(uri.toString())
    }

    private fun fetch(itemId: String, into: File) {
        val base = Services.session.baseUrl ?: return
        runCatching {
            val request = Request.Builder().url(BookMapper.coverUrl(itemId, base)).build()
            Services.httpClient.newCall(request).execute().use { resp ->
                val bytes = resp.body?.bytes()?.takeIf { resp.isSuccessful && it.isNotEmpty() } ?: return
                into.parentFile?.mkdirs()
                val tmp = File(into.path + ".tmp")
                tmp.writeBytes(bytes)
                if (!tmp.renameTo(into)) tmp.delete()
            }
        }.onFailure { Log.w(TAG, "cover fetch failed for $itemId", it) }
    }

    private fun open(file: File) = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)

    override fun query(uri: Uri, p: Array<out String>?, s: String?, a: Array<out String>?, o: String?): Cursor? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = null
    override fun delete(uri: Uri, s: String?, a: Array<out String>?): Int = 0
    override fun update(uri: Uri, v: ContentValues?, s: String?, a: Array<out String>?): Int = 0

    companion object {
        private const val TAG = "CoverProvider"
        private const val AUTHORITY = "${BuildConfig.APPLICATION_ID}.covers"
        private val ID = Regex("[A-Za-z0-9_-]+")
        /** Re-fetched after this, so a cover changed on the server shows up eventually. */
        private const val MAX_AGE_MS = 7L * 24 * 3600 * 1000

        fun uriFor(itemId: String): Uri = Uri.parse("content://$AUTHORITY/cover/$itemId")
    }
}
