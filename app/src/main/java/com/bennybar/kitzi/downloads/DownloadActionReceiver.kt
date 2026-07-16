package com.bennybar.kitzi.downloads

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.bennybar.kitzi.data.Services
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Handles the "Cancel" action on the download notification. Runs the same
 * cancel() the in-app buttons use — cancels the work, deletes half-written
 * files, and marks the not-yet-finished tracks canceled — so the download
 * stops cleanly and the UI stops showing it as in progress.
 */
class DownloadActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_CANCEL) return
        val itemId = intent.getStringExtra(EXTRA_ITEM_ID) ?: return
        val pending = goAsync()
        CoroutineScope(Dispatchers.IO).launch {
            try {
                Services.init(context.applicationContext)
                Services.downloads.cancel(itemId)
            } finally {
                pending.finish()
            }
        }
    }

    companion object {
        const val ACTION_CANCEL = "com.bennybar.kitzi.action.CANCEL_DOWNLOAD"
        const val EXTRA_ITEM_ID = "itemId"
    }
}
