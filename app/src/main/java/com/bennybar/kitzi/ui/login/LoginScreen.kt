package com.bennybar.kitzi.ui.login

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import com.bennybar.kitzi.data.Services
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@Composable
fun LoginScreen(onSignedIn: () -> Unit) {
    var server by remember { mutableStateOf(Services.session.baseUrl.orEmpty()) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var ssoAvailable by remember { mutableStateOf(false) }

    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current

    // SSO returns via OidcCallbackActivity, which parks the redirect URL and brings
    // us back to the foreground. On resume, pick it up and complete the exchange.
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) {
                val callbackUrl = OidcCallback.consume() ?: return@LifecycleEventObserver
                busy = true
                error = null
                scope.launch {
                    val ok = withContext(Dispatchers.IO) {
                        runCatching { Services.auth.oidc.finish(server, callbackUrl) }.getOrDefault(false)
                    }
                    busy = false
                    if (ok) onSignedIn() else error = "SSO sign in failed. Please try again."
                }
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }

    fun startSso() {
        if (server.isBlank()) return
        busy = true
        error = null
        scope.launch {
            val authorizeUrl = withContext(Dispatchers.IO) {
                runCatching { Services.auth.oidc.begin(server) }.getOrNull()
            }
            busy = false
            if (authorizeUrl == null) {
                error = "Couldn't start SSO for this server."
                return@launch
            }
            runCatching {
                androidx.browser.customtabs.CustomTabsIntent.Builder().build()
                    .launchUrl(context, android.net.Uri.parse(authorizeUrl))
            }.onFailure { error = "Couldn't open the sign-in page." }
        }
    }

    fun signIn() {
        busy = true
        error = null
        scope.launch {
            val ok = try {
                withContext(Dispatchers.IO) {
                    Services.auth.login(server, username.trim(), password)
                }
            } catch (e: Exception) {
                false
            }
            busy = false
            if (ok) onSignedIn() else error = "Sign in failed. Check the server and your credentials."
        }
    }

    // Offer SSO only when the server actually advertises it — probed whenever the
    // typed URL settles. It used to be probed only from the Sign in button, which
    // requires a username and tries a password login at the same time, so someone
    // whose server is SSO-only had no way to make the SSO button appear at all.
    LaunchedEffect(server) {
        ssoAvailable = false
        if (server.isBlank()) return@LaunchedEffect
        delay(600)   // don't probe on every keystroke
        ssoAvailable = withContext(Dispatchers.IO) {
            runCatching { Services.auth.serverAuthMethods(server).contains("openid") }.getOrDefault(false)
        }
    }

    Box(Modifier.fillMaxSize().padding(24.dp), contentAlignment = Alignment.Center) {
        Card(Modifier.fillMaxWidth()) {
            Column(
                Modifier.padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text("Login", style = MaterialTheme.typography.headlineSmall)

                OutlinedTextField(
                    value = server,
                    onValueChange = { server = it },
                    label = { Text("Server URL") },
                    singleLine = true,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username") },
                    singleLine = true,
                    enabled = !busy,
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password") },
                    singleLine = true,
                    enabled = !busy,
                    visualTransformation = PasswordVisualTransformation(),
                    modifier = Modifier.fillMaxWidth(),
                )

                error?.let { Text(it, color = MaterialTheme.colorScheme.error) }

                if (busy) {
                    Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                        CircularProgressIndicator(Modifier.size(28.dp))
                    }
                } else {
                    Button(
                        onClick = { signIn() },
                        enabled = server.isNotBlank() && username.isNotBlank(),
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Sign in") }

                    if (ssoAvailable) {
                        OutlinedButton(
                            onClick = { startSso() },
                            enabled = server.isNotBlank(),
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Sign in with SSO") }
                    }
                }
            }
        }
    }
}
