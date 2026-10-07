package com.bennybar.kitzi.ui.login

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Catches the `kitzi://oauth?code=...&state=...` redirect (or the legacy
 * `audiobookshelf://oauth` one, see OidcClient) the IdP sends back at the end of
 * SSO, hands it to whoever started the flow, and gets out of the way.
 */
class OidcCallbackActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        OidcCallback.deliver(intent?.data?.toString())

        // Bring the app's task back to the front; the custom tab sits on top of it.
        startActivity(
            Intent(this, com.bennybar.kitzi.MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            }
        )
        finish()
    }
}

/** Where the redirect URL is parked between the browser returning and the login screen collecting it. */
object OidcCallback {
    @Volatile private var pending: String? = null

    fun deliver(url: String?) {
        if (url != null) pending = url
    }

    /** Returns the callback URL exactly once. */
    fun consume(): String? {
        val url = pending
        pending = null
        return url
    }
}
