package com.bennybar.kitzi.data.legacy

import android.content.Context
import java.io.File

/**
 * Where downloaded audio lives — which is exactly where the Flutter app already
 * put it, so existing downloads are adopted in place with no copying and no
 * re-download. Users have gigabytes here; moving it would be slow, and a failed
 * move would be catastrophic.
 *
 * The Flutter app used `getApplicationDocumentsDirectory()`, which path_provider
 * implements on Android as `context.getDir("flutter", MODE_PRIVATE)` — i.e.
 * `/data/user/0/<pkg>/app_flutter`. The call below is that same call, so it
 * resolves to the same directory.
 *
 * Layout (lib/core/download_storage.dart):
 *   <documents>/<subfolder>/lib_<libraryId>/<libraryItemId>/track_000.<ext>
 *
 * `subfolder` is user-configurable (default `abs`) and `libraryId` namespaces
 * per library, so both come from the Flutter-era prefs.
 */
class DownloadPaths(
    private val context: Context,
    private val prefs: FlutterPrefs,
) {
    /** `/data/user/0/com.bennybar.kitzi/app_flutter` — the Flutter documents dir. */
    fun documentsDir(): File = context.getDir("flutter", Context.MODE_PRIVATE)

    fun baseSubfolder(): String =
        prefs.getString(FlutterPrefs.KEY_DOWNLOADS_SUBFOLDER)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_SUBFOLDER

    fun currentLibraryId(): String =
        prefs.getString(FlutterPrefs.KEY_LIBRARY_ID)
            ?.trim()
            ?.takeIf { it.isNotEmpty() }
            ?: DEFAULT_LIBRARY_ID

    /** `<documents>/<subfolder>/lib_<libraryId>` for the active library. */
    fun libraryDir(libraryId: String = currentLibraryId()): File =
        File(File(documentsDir(), baseSubfolder()), "lib_$libraryId")

    fun itemDir(libraryItemId: String, libraryId: String = currentLibraryId()): File =
        File(libraryDir(libraryId), libraryItemId)

    /** Item ids with at least one downloaded file, as the Flutter app determined it. */
    fun downloadedItemIds(libraryId: String = currentLibraryId()): List<String> {
        val base = libraryDir(libraryId)
        if (!base.isDirectory) return emptyList()
        return base.listFiles()
            .orEmpty()
            .filter { it.isDirectory && !it.listFiles().isNullOrEmpty() }
            .map { it.name }
            .sorted()
    }

    fun bytesForItem(libraryItemId: String, libraryId: String = currentLibraryId()): Long =
        itemDir(libraryItemId, libraryId).walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    fun totalBytes(libraryId: String = currentLibraryId()): Long =
        libraryDir(libraryId).walkBottomUp().filter { it.isFile }.sumOf { it.length() }

    companion object {
        const val DEFAULT_SUBFOLDER = "abs"
        const val DEFAULT_LIBRARY_ID = "default"
    }
}
