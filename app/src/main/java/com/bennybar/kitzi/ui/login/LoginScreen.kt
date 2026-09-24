package com.bennybar.kitzi.ui.login

import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.filled.Visibility
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
    var showPassword by remember { mutableStateOf(false) }

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
            val result = try {
                withContext(Dispatchers.IO) {
                    Services.auth.loginResult(server, username.trim(), password)
                }
            } catch (e: Exception) {
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.UNREACHABLE
            }
            busy = false
            // Say which part is wrong: every failure used to read the same.
            error = when (result) {
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.OK -> { onSignedIn(); null }
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.WRONG_CREDENTIALS -> "Wrong username or password."
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.UNREACHABLE -> "Can't reach the server. Check the address and your connection."
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.INSECURE -> "Couldn't make a secure connection to this server (certificate problem). If it's on your home network, try http:// instead."
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.NOT_ABS -> "This doesn't look like an Audiobookshelf server. Check the address."
                com.bennybar.kitzi.data.net.AuthApi.LoginResult.SERVER_ERROR -> "The server had a problem. Try again in a moment."
            }
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
                // "Sign in" throughout (the title said "Login", the button "Sign in").
                Text("Sign in", style = MaterialTheme.typography.headlineSmall)
                Text(
                    "Connect to your Audiobookshelf server.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                val canSignIn = server.isNotBlank() && username.isNotBlank()
                OutlinedTextField(
                    value = server,
                    onValueChange = { server = it },
                    label = { Text("Server URL") },
                    placeholder = { Text("https://abs.example.com") },
                    singleLine = true,
                    enabled = !busy,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.Uri,
                        autoCorrectEnabled = false,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Next,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = username,
                    onValueChange = { username = it },
                    label = { Text("Username") },
                    singleLine = true,
                    enabled = !busy,
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        autoCorrectEnabled = false,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Next,
                    ),
                    modifier = Modifier.fillMaxWidth(),
                )
                OutlinedTextField(
                    value = password,
                    onValueChange = { password = it },
                    label = { Text("Password") },
                    singleLine = true,
                    enabled = !busy,
                    visualTransformation = if (showPassword) androidx.compose.ui.text.input.VisualTransformation.None else PasswordVisualTransformation(),
                    trailingIcon = {
                        androidx.compose.material3.IconButton(onClick = { showPassword = !showPassword }) {
                            androidx.compose.material3.Icon(
                                if (showPassword) androidx.compose.material.icons.Icons.Default.VisibilityOff
                                else androidx.compose.material.icons.Icons.Default.Visibility,
                                if (showPassword) "Hide password" else "Show password",
                            )
                        }
                    },
                    // Done on the keyboard signs in.
                    keyboardOptions = androidx.compose.foundation.text.KeyboardOptions(
                        keyboardType = androidx.compose.ui.text.input.KeyboardType.Password,
                        imeAction = androidx.compose.ui.text.input.ImeAction.Done,
                    ),
                    keyboardActions = androidx.compose.foundation.text.KeyboardActions(
                        onDone = { if (canSignIn && !busy) signIn() },
                    ),
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
                        enabled = canSignIn,
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
