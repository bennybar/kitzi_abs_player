package com.bennybar.kitzi.data.net

import android.content.Context
import android.util.Log
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.bennybar.kitzi.data.AuthRepository
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Talks to a real Audiobookshelf server. Credentials are passed in as
 * instrumentation arguments so they never enter the repo:
 *
 *   -e absUrl https://host -e absUser name -e absPass secret
 *
 * Skips (rather than fails) when they are absent, so a plain test run stays green.
 */
@RunWith(AndroidJUnit4::class)
class AuthLiveTest {

    private val context: Context = ApplicationProvider.getApplicationContext()
    private val args = InstrumentationRegistry.getArguments()

    private val url get() = args.getString("absUrl")
    private val user get() = args.getString("absUser")
    private val pass get() = args.getString("absPass")

    private lateinit var session: SessionStore
    private lateinit var authApi: AuthApi
    private lateinit var refresher: TokenRefresher
    private lateinit var auth: AuthRepository

    @Before
    fun setUp() {
        assumeTrue("no server credentials supplied", url != null && user != null && pass != null)
        session = SessionStore(context)
        authApi = AuthApi(Http.authClient(), session)
        refresher = TokenRefresher(session, authApi)
        auth = AuthRepository(session, authApi, refresher, OidcClient(session, authApi))
        session.clearTokens()
    }

    @Test
    fun logsInAndKeepsAValidSession() {
        assertTrue("login failed", auth.login(url!!, user!!, pass!!))

        Log.i(TAG, "logged in; access len=${session.accessToken?.length} expiry=${session.accessExpiry}")
        assertNotNull(session.accessToken)
        assertNotNull("no refresh token issued", session.refreshToken)
        assertTrue(session.hasFreshAccessToken())
        assertTrue(auth.hasValidSession())
        assertEquals(SessionStore.normalizeBaseUrl(url!!), session.baseUrl)
    }

    @Test
    fun reportsTheServersAuthMethods() {
        val methods = auth.serverAuthMethods(url!!)
        Log.i(TAG, "authMethods=$methods")
        assertTrue("expected at least 'local'", methods.contains("local"))
    }

    @Test
    fun refreshRotatesTheAccessToken() {
        assertTrue(auth.login(url!!, user!!, pass!!))
        val before = session.accessToken

        assertTrue("refresh failed", authApi.refresh())

        assertNotNull(session.accessToken)
        assertTrue(session.hasFreshAccessToken())
        Log.i(TAG, "token changed on refresh: ${before != session.accessToken}")
    }

    /**
     * The regression this guards: ABS rotates the refresh token on every
     * /auth/refresh. If N concurrent 401s each refresh, they invalidate each
     * other's tokens and the user is silently logged out. Only ONE rotation must
     * happen; the rest must reuse it. Ten threads race here.
     */
    @Test
    fun concurrentRefreshesDoNotStampede() {
        assertTrue(auth.login(url!!, user!!, pass!!))
        val staleToken = session.accessToken

        val threads = 10
        val start = CountDownLatch(1)
        val done = CountDownLatch(threads)
        val pool = Executors.newFixedThreadPool(threads)
        val results = java.util.Collections.synchronizedList(mutableListOf<Boolean>())

        repeat(threads) {
            pool.submit {
                start.await()
                results.add(refresher.refreshAfterUnauthorized(staleToken))
                done.countDown()
            }
        }
        start.countDown()
        assertTrue("threads did not finish", done.await(60, TimeUnit.SECONDS))
        pool.shutdown()

        Log.i(TAG, "concurrent refreshes: ${results.count { it }}/$threads succeeded")

        // Every caller must end up with a usable token...
        assertTrue("some callers were left without a token", results.all { it })
        // ...and the session must still actually work afterwards. If the refresh
        // token had been rotated N times, it would now be dead.
        assertTrue("session is dead after a refresh storm — the token was rotated more than once",
            auth.hasValidSession())
        assertTrue(session.accessToken != staleToken)
    }

    private companion object {
        const val TAG = "AuthLiveTest"
    }
}
