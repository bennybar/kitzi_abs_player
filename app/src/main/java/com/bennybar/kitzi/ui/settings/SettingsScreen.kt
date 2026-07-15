package com.bennybar.kitzi.ui.settings

import android.content.Intent
import android.net.Uri
import android.provider.Settings as AndroidSettings
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.QueueMusic
import androidx.compose.material.icons.filled.Backup
import androidx.compose.material.icons.filled.BatteryStd
import androidx.compose.material.icons.filled.Bedtime
import androidx.compose.material.icons.filled.BugReport
import androidx.compose.material.icons.filled.CleaningServices
import androidx.compose.material.icons.filled.CloudSync
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExitToApp
import androidx.compose.material.icons.filled.FastForward
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.filled.Gradient
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.LibraryBooks
import androidx.compose.material.icons.filled.Logout
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Replay
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.SortByAlpha
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Timer
import androidx.compose.material.icons.filled.VpnKey
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Library
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.ui.UiPrefsState
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.theme.ThemeMode
import com.bennybar.kitzi.ui.theme.ThemeState
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.roundToInt

@Composable
fun SettingsScreen(onSignedOut: () -> Unit) {
    val scope = rememberCoroutineScope()
    val context = LocalContext.current
    val prefs = Services.prefs

    var search by remember { mutableStateOf("") }
    var libraries by remember { mutableStateOf<List<Library>>(emptyList()) }
    var currentLibrary by remember { mutableStateOf(Services.books.libraryId) }
    var dialog by remember { mutableStateOf<SettingsDialog?>(null) }

    LaunchedEffect(Unit) {
        libraries = withContext(Dispatchers.IO) {
            runCatching { Services.books.listLibraries() }.getOrDefault(emptyList())
        }
    }

    fun matches(vararg terms: String) = search.isBlank() || terms.any { it.contains(search, true) }

    Column(
        Modifier.fillMaxSize().verticalScroll(rememberScrollState())
            .padding(bottom = com.bennybar.kitzi.LocalMiniPlayerInset.current),
    ) {
        ScreenHeader(
            icon = Icons.Default.Settings,
            title = "Settings",
            trailing = { Icon(Icons.Default.Person, "Profile") },
        )
        KitziSearchField(search, { search = it }, "Search settings", Modifier.padding(bottom = 12.dp))

        // ---------- Library ----------
        if (matches("library", "active library", "cleanup", "resync", "deleted")) {
            Section("Library")
            if (libraries.size > 1) {
                DropdownRow(
                    icon = Icons.Default.LibraryBooks,
                    title = "Active library",
                    selectedLabel = libraries.firstOrNull { it.id == currentLibrary }?.name ?: "—",
                    options = libraries.map { it.id to it.name },
                    onSelect = { id ->
                        currentLibrary = id
                        scope.launch { Services.books.switchLibrary(id) }
                    },
                )
            }
            ActionRow(Icons.Default.CleaningServices, "Clear deleted and broken items",
                "Check each cached book against server and remove deleted ones") { dialog = SettingsDialog.Cleanup }
            ActionRow(Icons.Default.CloudSync, "Resync book metadata",
                "Refresh all book metadata from server (including added date)") { dialog = SettingsDialog.Resync }
            ActionRow(Icons.Default.History, "Cleanup log", "View recent download cleanup activity") {
                dialog = SettingsDialog.CleanupLog
            }
            HorizontalDivider()
        }

        // ---------- Server access ----------
        if (matches("server access", "custom http headers", "header")) {
            Section("Server access")
            val headerCount = Services.session.customHeaders.size
            ActionRow(
                Icons.Default.VpnKey, "Custom HTTP headers",
                "Attach service-token headers (e.g. CF-Access-Client-Id). Tap to configure.",
                trailing = { Text(if (headerCount == 0) "Off" else "$headerCount active") },
            ) { dialog = SettingsDialog.Headers }
            HorizontalDivider()
        }

        // ---------- Appearance ----------
        if (matches("appearance", "theme", "dark", "series", "author", "player", "font", "tint", "letter")) {
            Section("Appearance")
            TogglePref("ui_show_series_tab", false, "Show Series tab", "Enable the Series view")
            TogglePref("ui_author_view_enabled", true, "Authors tab", "Show a dedicated Authors tab in the main navigation")
            TogglePref("ui_full_player_as_tab", true, "Full player as tab", "Show the full player as a bottom navigation tab instead of a popup card")
            TogglePref("ui_hide_series_when_same_as_author", true, "Hide duplicate series names", "Hide series name in books list when it matches the author name")
            TogglePref("ui_player_gradient_background", true, "Gradient background in player", "Apply a gradient surface to the full screen player", Icons.Default.Gradient)
            TogglePref("ui_player_scrolling_single_line_title", false, "Single-line scrolling player title", "Show one title line that continuously scrolls left in full player")
            TogglePref("ui_letter_scroll_enabled", false, "Add Letter Scrolling", "Show an alphabetical scrollbar in long lists", Icons.Default.SortByAlpha)
            TogglePref("ui_letter_scroll_books_alpha", false, "Books tab alphabetical order", "Required for letter scrolling in the Books tab", indent = true)

            // Theme mode reflected as two toggles, exactly like Flutter.
            val mode by ThemeState.mode
            ToggleRow(Icons.Default.Palette, "Dark mode", mode.name.lowercase().replaceFirstChar { it.uppercase() }, checked = mode == ThemeMode.DARK) {
                ThemeState.set(if (it) ThemeMode.DARK else ThemeMode.LIGHT, prefs)
            }
            ToggleRow(Icons.Default.Palette, "Use system theme", "Follow the device light/dark setting", checked = mode == ThemeMode.SYSTEM) {
                ThemeState.set(if (it) ThemeMode.SYSTEM else ThemeMode.LIGHT, prefs)
            }

            // Font size slider (80..120, step 5).
            val fontPct by ThemeState.fontScalePercent
            SliderRow(Icons.Default.FormatSize, "Font size", "$fontPct%", fontPct.toFloat(), 80f..120f, 8) {
                ThemeState.setFontScale(it.roundToInt(), prefs)
            }
            // Surface tint dropdown.
            val tint by ThemeState.surfaceTintLevel
            DropdownRow(
                icon = Icons.Default.Palette,
                title = "Surface tint (Light mode)",
                selectedLabel = TINT_LABELS[tint],
                options = TINT_LABELS.mapIndexed { i, l -> i.toString() to l },
                onSelect = { ThemeState.setSurfaceTint(it.toInt(), prefs) },
            )
            HorizontalDivider()
        }

        // ---------- Downloads ----------
        if (matches("downloads", "wi-fi", "wifi", "delete", "battery", "streaming", "storage", "cache")) {
            Section("Downloads")
            ToggleRow(Icons.Default.Wifi, "Wi-Fi only downloads", "Disable to allow downloads on cellular data",
                checked = Services.downloads.wifiOnly) { Services.downloads.wifiOnly = it }
            ToggleRow(Icons.Default.Download, "Auto-delete on finish", "Remove the local download when a book is marked as finished",
                checked = Services.downloads.autoDeleteOnFinish) { Services.downloads.autoDeleteOnFinish = it }
            ActionRow(Icons.Default.BatteryStd, "Disable battery optimization", "Disconnection issues? Disable battery optimization") {
                runCatching {
                    context.startActivity(Intent(AndroidSettings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
                }
            }
            SliderRow(
                Icons.Default.Storage, "Streaming cache",
                "Max ${prefs.getInt("streaming_cache_max_bytes_mb", 512)} MB",
                prefs.getInt("streaming_cache_max_bytes_mb", 512).toFloat(),
                200f..2000f, 36,
            ) { prefs.putInt("streaming_cache_max_bytes_mb", it.roundToInt()) }
            ActionRow(Icons.Default.Storage, "Storage", "See download + streaming cache usage, and clean per book") {
                dialog = SettingsDialog.Storage
            }
            HorizontalDivider()
        }

        // ---------- Playback ----------
        if (matches("playback", "rewind", "sync", "sleep", "chapter", "resume", "history", "progress", "seek", "bluetooth")) {
            Section("Playback")
            TogglePref("smart_rewind_enabled", false, "Smart rewind on resume", "Rewind a few seconds based on pause duration", Icons.Default.Replay)
            TogglePref("sync_progress_before_play", true, "Sync progress before play", "Fetch latest progress from server before starting playback")
            TogglePref("pause_cancels_sleep_timer", true, "Pause to cancel timer", "Stop the sleep timer when pausing playback", Icons.Default.Bedtime)
            TogglePref("ui_dual_progress_enabled", true, "Book + chapter progress in player", "Show global book progress and chapter progress")
            TogglePref("ui_resume_from_history_enabled", true, "Resume previous position button", "Show \"Resume previous play position\" under the cover")
            TogglePref("detailed_play_history_enabled", false, "Detailed listening history (local)", "Record play sessions for stats (top books/authors/narrators)")
            var progressPrimary by remember { mutableStateOf(prefs.getString("ui_progress_primary") ?: "book") }
            DropdownRow(
                icon = Icons.Default.FastForward,
                title = "Primary progress display",
                selectedLabel = if (progressPrimary == "chapter") "Current chapter" else "Full book",
                options = listOf("book" to "Full book", "chapter" to "Current chapter"),
                onSelect = { progressPrimary = it; prefs.putString("ui_progress_primary", it) },
            )
            var backSec by remember { mutableStateOf(prefs.getInt("ui_seek_backward_seconds", 30)) }
            SliderRow(Icons.Default.Replay, "Seek backward duration", "$backSec seconds", backSec.toFloat(), 5f..60f, 11) {
                backSec = it.roundToInt(); prefs.putInt("ui_seek_backward_seconds", backSec)
            }
            var fwdSec by remember { mutableStateOf(prefs.getInt("ui_seek_forward_seconds", 30)) }
            SliderRow(Icons.Default.FastForward, "Seek forward duration", "$fwdSec seconds", fwdSec.toFloat(), 5f..60f, 11) {
                fwdSec = it.roundToInt(); prefs.putInt("ui_seek_forward_seconds", fwdSec)
            }
            HorizontalDivider()
        }

        // ---------- Backup & restore ----------
        if (matches("backup", "restore", "export", "import")) {
            Section("Backup & restore")
            ActionRow(Icons.Default.Backup, "Settings backup", "Export or restore your preferences") {
                dialog = SettingsDialog.Backup
            }
            HorizontalDivider()
        }

        // ---------- Debug & logging ----------
        if (matches("debug", "logging", "log")) {
            Section("Debug & logging")
            val logCtx = androidx.compose.ui.platform.LocalContext.current
            var logging by remember { mutableStateOf(com.bennybar.kitzi.data.SessionLogger.isRunning) }
            ToggleRow(
                Icons.Default.BugReport,
                "Logging session",
                "Capture logs to a file for up to 15 minutes",
                logging,
            ) {
                logging = it
                Services.prefs.putBoolean("logging_session_active", it)
                if (it) com.bennybar.kitzi.data.SessionLogger.start(logCtx)
                else com.bennybar.kitzi.data.SessionLogger.stop()
            }
            if (com.bennybar.kitzi.data.SessionLogger.logFiles(logCtx).isNotEmpty()) {
                ActionRow(Icons.Default.History, "Clear session logs", "Delete captured log files") {
                    com.bennybar.kitzi.data.SessionLogger.clearLogs(logCtx)
                }
            }
            TogglePref(
                "debug_plain_media_session",
                false,
                "Plain media session (pill test)",
                "Diagnostic: expose the raw player so Samsung may show the Now Bar. Loses chapter-skip + book position on the lock screen. Exit and reopen the app after changing.",
            )
            HorizontalDivider()
        }

        // ---------- Account ----------
        Section("Account")
        ActionRow(Icons.Default.Logout, "Log out", Services.session.baseUrl.orEmpty()) {
            dialog = SettingsDialog.Logout
        }
        ActionRow(Icons.Default.ExitToApp, "Exit App", "Stop playback and close the app") {
            val activity = context as? android.app.Activity
            scope.launch {
                // Flush the final progress/close (bounded), THEN finish normally —
                // killProcess() used to fire before those coroutines could run.
                runCatching { kotlinx.coroutines.withTimeout(2500) { Services.playback.stopAndAwait() } }
                activity?.finishAndRemoveTask()
            }
        }
        Box(Modifier.size(24.dp))
    }

    when (dialog) {
        SettingsDialog.Headers -> HeadersDialog { dialog = null }
        SettingsDialog.Backup -> BackupDialog { dialog = null }
        SettingsDialog.Storage -> StorageDialog { dialog = null }
        SettingsDialog.CleanupLog -> InfoDialog("Cleanup Log", "No cleanup activity yet.") { dialog = null }
        SettingsDialog.Cleanup -> ConfirmDialog(
            "Clear deleted and broken items",
            "Check each cached book against the server and remove any that were deleted?",
        ) {
            scope.launch { runCatching { Services.books.reconcile() } }
            dialog = null
        }
        SettingsDialog.Resync -> ConfirmDialog(
            "Resync book metadata",
            "Refresh all book metadata from the server? This may take a moment.",
        ) {
            scope.launch { runCatching { Services.books.syncAll() } }
            dialog = null
        }
        SettingsDialog.Logout -> ConfirmDialog(
            "Log out?",
            // Truthful copy: logout clears the saved session only. Downloads and
            // cached books stay on the device (use \"Delete all downloads\" in
            // Storage to remove those).
            "This signs you out and clears your saved login. Your downloads and cached books stay on this device.",
        ) {
            scope.launch {
                withContext(Dispatchers.IO) { Services.auth.logout() }
                onSignedOut()
            }
            dialog = null
        }
        null -> {}
    }
}

private enum class SettingsDialog { Headers, Backup, Storage, CleanupLog, Cleanup, Resync, Logout }

private val TINT_LABELS = listOf("Pure White", "Light Tint", "Medium Tint", "Strong Tint", "Very Strong Tint")

// ---------- row framework ----------

@Composable
private fun Section(title: String) {
    Text(
        title,
        style = MaterialTheme.typography.titleMedium,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 20.dp, top = 20.dp, bottom = 8.dp),
    )
}

/**
 * A toggle bound to a boolean pref. Keys that change the live UI (nav tabs,
 * player affordances, list rows) are routed through UiPrefsState so the rest of
 * the app updates immediately; the rest just persist.
 */
@Composable
private fun TogglePref(
    key: String,
    default: Boolean,
    title: String,
    subtitle: String,
    icon: ImageVector? = null,
    indent: Boolean = false,
) {
    var checked by remember { mutableStateOf(Services.prefs.getBoolean(key, default)) }
    ToggleRow(icon, title, subtitle, checked, indent) {
        checked = it
        if (key in UiPrefsState.ownedKeys) UiPrefsState.set(Services.prefs, key, it)
        else Services.prefs.putBoolean(key, it)
    }
}

@Composable
private fun ToggleRow(
    icon: ImageVector?,
    title: String,
    subtitle: String?,
    checked: Boolean,
    indent: Boolean = false,
    onChange: (Boolean) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable { onChange(!checked) }
            .padding(start = if (indent) 40.dp else 20.dp, end = 20.dp, top = 12.dp, bottom = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (icon != null) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp).padding(end = 0.dp))
        }
        Column(Modifier.weight(1f).padding(start = if (icon != null) 16.dp else 0.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Switch(checked = checked, onCheckedChange = onChange)
    }
}

@Composable
private fun ActionRow(
    icon: ImageVector,
    title: String,
    subtitle: String,
    trailing: @Composable (() -> Unit)? = null,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().clickable(onClick = onClick).padding(horizontal = 20.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
        Column(Modifier.weight(1f).padding(start = 16.dp)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle.takeIf { it.isNotBlank() }?.let {
                Text(it, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        trailing?.invoke()
    }
}

@Composable
private fun SliderRow(
    icon: ImageVector,
    title: String,
    valueLabel: String,
    value: Float,
    range: ClosedFloatingPointRange<Float>,
    steps: Int,
    onChange: (Float) -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp, vertical = 8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
            Column(Modifier.padding(start = 16.dp)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                Text(valueLabel, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
        Slider(value = value, onValueChange = onChange, valueRange = range, steps = steps)
    }
}

@Composable
private fun DropdownRow(
    icon: ImageVector,
    title: String,
    selectedLabel: String,
    options: List<Pair<String, String>>,
    onSelect: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    Box {
        Row(
            Modifier.fillMaxWidth().clickable { open = true }.padding(horizontal = 20.dp, vertical = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(icon, null, tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(24.dp))
            Column(Modifier.weight(1f).padding(start = 16.dp)) {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                Text(selectedLabel, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.primary)
            }
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            options.forEach { (value, label) ->
                DropdownMenuItem(text = { Text(label) }, onClick = { onSelect(value); open = false })
            }
        }
    }
}

// ---------- dialogs ----------

@Composable
private fun ConfirmDialog(title: String, message: String, onConfirm: () -> Unit) {
    var dismissed by remember { mutableStateOf(false) }
    if (dismissed) return
    AlertDialog(
        onDismissRequest = { dismissed = true },
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onConfirm) { Text("Confirm") } },
        dismissButton = { TextButton(onClick = { dismissed = true }) { Text("Cancel") } },
    )
}

@Composable
private fun InfoDialog(title: String, message: String, onDismiss: () -> Unit) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text(title) },
        text = { Text(message) },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}

@Composable
private fun HeadersDialog(onDismiss: () -> Unit) {
    var text by remember {
        mutableStateOf(Services.session.customHeaders.entries.joinToString("\n") { "${it.key}: ${it.value}" })
    }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Custom HTTP headers") },
        text = {
            Column {
                Text("One per line, as Name: value. Sent on every request.",
                    style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                OutlinedTextField(
                    value = text, onValueChange = { text = it },
                    placeholder = { Text("CF-Access-Client-Id: abc") },
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp), minLines = 3,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = {
                Services.session.customHeaders = text.lines().mapNotNull { line ->
                    val name = line.substringBefore(':', "").trim()
                    val value = line.substringAfter(':', "").trim()
                    if (name.isEmpty() || value.isEmpty()) null else name to value
                }.toMap()
                onDismiss()
            }) { Text("Save") }
        },
        dismissButton = { TextButton(onClick = onDismiss) { Text("Cancel") } },
    )
}

@Composable
private fun BackupDialog(onDismiss: () -> Unit) {
    val prefs = Services.prefs
    var json by remember { mutableStateOf("") }
    var restored by remember { mutableStateOf(false) }
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Settings backup") },
        text = {
            Column {
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedButton(onClick = { json = SettingsBackup.export(prefs) }, modifier = Modifier.weight(1f)) { Text("Export") }
                    OutlinedButton(
                        onClick = {
                            restored = SettingsBackup.import(prefs, json)
                            // Reload BOTH state holders — otherwise restored tab/player
                            // preferences don't take effect until the next launch.
                            if (restored) {
                                ThemeState.load(prefs)
                                com.bennybar.kitzi.ui.UiPrefsState.load(prefs)
                            }
                        },
                        enabled = json.isNotBlank(), modifier = Modifier.weight(1f),
                    ) { Text(if (restored) "Restored" else "Restore") }
                }
                OutlinedTextField(json, { json = it; restored = false }, label = { Text("Settings JSON") },
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp), minLines = 4)
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Done") } },
    )
}

@Composable
private fun StorageDialog(onDismiss: () -> Unit) {
    var totalBytes by remember { mutableStateOf(0L) }
    LaunchedEffect(Unit) { totalBytes = withContext(Dispatchers.IO) { Services.downloads.totalBytes() } }
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Storage") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Text("Downloads: ${com.bennybar.kitzi.ui.common.formatSize(totalBytes)}", style = MaterialTheme.typography.bodyLarge)
                OutlinedButton(
                    onClick = {
                        // Goes through the repository so active workers are cancelled
                        // and awaited before files/rows are removed.
                        scope.launch { Services.downloads.deleteAll() }
                        onDismiss()
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) { Text("Delete all downloads") }
            }
        },
        confirmButton = { TextButton(onClick = onDismiss) { Text("Close") } },
    )
}
