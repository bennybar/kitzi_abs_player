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
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Services
import kotlinx.coroutines.Dispatchers
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

    fun signIn() {
        busy = true
        error = null
        scope.launch {
            val ok = withContext(Dispatchers.IO) {
                Services.auth.login(server, username.trim(), password)
            }
            busy = false
            if (ok) onSignedIn() else error = "Sign in failed. Check the server and your credentials."
        }
    }

    // Offer SSO only when the server actually advertises it.
    fun probeServer() {
        if (server.isBlank()) return
        scope.launch {
            ssoAvailable = withContext(Dispatchers.IO) {
                runCatching { Services.auth.serverAuthMethods(server).contains("openid") }.getOrDefault(false)
            }
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
                        onClick = { probeServer(); signIn() },
                        enabled = server.isNotBlank() && username.isNotBlank(),
                        modifier = Modifier.fillMaxWidth(),
                    ) { Text("Sign in") }

                    if (ssoAvailable) {
                        OutlinedButton(
                            onClick = { /* SSO: opens the IdP in a custom tab */ },
                            modifier = Modifier.fillMaxWidth(),
                        ) { Text("Sign in with SSO") }
                    }
                }
            }
        }
    }
}
