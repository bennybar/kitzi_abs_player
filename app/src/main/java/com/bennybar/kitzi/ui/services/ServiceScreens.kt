package com.bennybar.kitzi.ui.services

import android.annotation.SuppressLint
import android.webkit.HttpAuthHandler
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.LibraryBooks
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Inbox
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import coil.compose.AsyncImage
import com.bennybar.kitzi.LocalMiniPlayerInset
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.audible.LibraryMatcher
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.data.services.Achew
import com.bennybar.kitzi.data.services.Shelfarr
import com.bennybar.kitzi.data.services.ShelfarrBook
import com.bennybar.kitzi.data.services.ShelfarrBookInfo
import com.bennybar.kitzi.data.services.ShelfarrRequest
import com.bennybar.kitzi.ui.UiPrefsState
import com.bennybar.kitzi.ui.audible.AudibleImage
import com.bennybar.kitzi.ui.audible.AudibleTopBar
import com.bennybar.kitzi.ui.audible.Card
import com.bennybar.kitzi.ui.audible.LocalKitziNav
import com.bennybar.kitzi.ui.common.KitziLoading
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.Snackbars
import com.bennybar.kitzi.ui.common.decodeHtml
import com.bennybar.kitzi.ui.common.formatHm
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.text.DateFormat
import java.util.Date

/** The whole library, for showing a request's book from it. */
@Composable
private fun rememberLibrary(): List<Book> {
    var all by remember { mutableStateOf<List<Book>>(emptyList()) }
    LaunchedEffect(Unit) { all = LibraryMatcher.all() }
    return all
}

@Composable
private fun Cover(book: Book?, url: String?, size: Dp) {
    val m = Modifier.size(size).clip(RoundedCornerShape(size * 0.16f))
    // Library covers go through the app's (signed) loader; anything else through the plain one.
    if (book != null) AsyncImage(book.coverUrl, null, contentScale = ContentScale.Crop, modifier = m)
    else AudibleImage(url, m)
}

@Composable
fun StatusBadge(r: ShelfarrRequest) {
    val color = when {
        r.isCompleted -> Color(0xFF4CAF50)
        r.isWorking -> MaterialTheme.colorScheme.primary
        else -> Color(0xFFF59E0B)
    }
    Text(
        r.statusLabel,
        style = MaterialTheme.typography.labelMedium,
        fontWeight = FontWeight.SemiBold,
        color = color,
        maxLines = 1,
        modifier = Modifier.clip(RoundedCornerShape(50)).background(color.copy(alpha = 0.15f)).padding(horizontal = 10.dp, vertical = 5.dp),
    )
}

// MARK: the Shelfarr tab

/** Shelfarr: your requests and their status; search to request another audiobook. */
@Composable
fun ShelfarrScreen(onOpenRequest: (Int) -> Unit) {
    val requests by Shelfarr.requests.collectAsState()
    val library = rememberLibrary()
    var query by rememberSaveable { mutableStateOf("") }
    var results by remember { mutableStateOf<List<ShelfarrBook>?>(null) }
    var searching by remember { mutableStateOf(false) }
    var loaded by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var refreshing by remember { mutableStateOf(false) }
    var requesting by remember { mutableStateOf<ShelfarrBook?>(null) }
    var deleting by remember { mutableStateOf<ShelfarrRequest?>(null) }
    val scope = rememberCoroutineScope()

    suspend fun load() {
        loadError = runCatching { Shelfarr.refresh() }.exceptionOrNull()?.message
        loaded = true
    }
    fun search() {
        val q = query.trim()
        if (q.isEmpty()) return
        scope.launch {
            searching = true
            // The badges on the results come from the requests list: it may have changed.
            runCatching { Shelfarr.refresh() }
            runCatching { Shelfarr.search(q) }.onSuccess { results = it }.onFailure { Snackbars.show(it.message ?: "Search failed") }
            searching = false
        }
    }
    LaunchedEffect(Unit) { load() }
    // While something is in progress and this screen is open, keep its status current.
    val working = requests.any { it.isWorking }
    val lifecycle = LocalLifecycleOwner.current
    LaunchedEffect(working, lifecycle) {
        lifecycle.repeatOnLifecycle(androidx.lifecycle.Lifecycle.State.RESUMED) {
            while (working) { delay(20_000); runCatching { Shelfarr.refresh() } }
        }
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(Icons.Default.Inbox, "Shelfarr")
        KitziSearchField(
            query,
            { query = it; if (it.isEmpty()) results = null },
            "Search for a book",
            Modifier.padding(bottom = 8.dp),
        )
        // Searches once typing pauses.
        LaunchedEffect(query) { if (query.isNotBlank()) { delay(700); search() } }
        when {
            searching -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { KitziLoading() }
            results != null -> {
                val r = results!!
                if (r.isEmpty()) Text("Nothing found for “${query.trim()}”.", color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(24.dp))
                else LazyColumn(contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current)) {
                    items(r, key = { it.workId }) { b ->
                        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Cover(null, b.coverUrl, 60.dp)
                            Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
                                Text(b.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
                                b.author?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
                                b.year?.let { Text("$it", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                            }
                            val existing = requests.firstOrNull { it.workId == b.workId && it.bookType == "audiobook" }
                            when {
                                existing != null -> StatusBadge(existing)
                                Shelfarr.matching(library, b.title, b.author) != null ->
                                    Text("In Library", style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                else -> FilledTonalButton(onClick = { requesting = b }) { Text("Request") }
                            }
                        }
                    }
                }
            }
            requests.isNotEmpty() -> PullToRefreshBox(
                isRefreshing = refreshing,
                onRefresh = { scope.launch { refreshing = true; load(); refreshing = false } },
                modifier = Modifier.fillMaxSize(),
            ) {
                val open = requests.filter { !it.isCompleted }
                val done = requests.filter { it.isCompleted }
                LazyColumn(contentPadding = PaddingValues(bottom = 16.dp + LocalMiniPlayerInset.current)) {
                    if (open.isNotEmpty()) {
                        item { Header("In Progress") }
                        items(open, key = { it.id }) { r -> RequestRow(r, library, { onOpenRequest(r.id) }) { deleting = r } }
                    }
                    if (done.isNotEmpty()) {
                        item { Header("Completed") }
                        items(done, key = { it.id }) { r -> RequestRow(r, library, { onOpenRequest(r.id) }) { deleting = r } }
                    }
                }
            }
            loadError != null -> Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Text("Couldn't load requests", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Text(loadError!!, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center, modifier = Modifier.padding(top = 6.dp))
                TextButton(onClick = { scope.launch { load() } }) { Text("Try again") }
            }
            loaded -> Column(Modifier.fillMaxWidth().padding(32.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                Icon(Icons.Default.Inbox, null, Modifier.size(40.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Text("No requests yet", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
                Text("Search for a book to request its audiobook.", color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { KitziLoading() }
        }
    }

    requesting?.let { b ->
        AlertDialog(
            onDismissRequest = { requesting = null },
            title = { Text("Request this audiobook?") },
            text = { Text("Shelfarr will search for ${b.title} and download it.") },
            confirmButton = {
                TextButton(onClick = {
                    requesting = null
                    scope.launch {
                        runCatching { Shelfarr.request(b) }
                            .onSuccess { Snackbars.show("Requested ${b.title}") }
                            .onFailure { Snackbars.show(it.message ?: "Couldn't request it") }
                    }
                }) { Text("Request audiobook") }
            },
            dismissButton = { TextButton(onClick = { requesting = null }) { Text("Cancel") } },
        )
    }
    deleting?.let { r -> DeleteDialog(r, onDone = { deleting = null }) }
}

@Composable
private fun Header(text: String) {
    Text(text, style = MaterialTheme.typography.labelLarge, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(start = 16.dp, top = 12.dp, bottom = 4.dp))
}

@Composable
private fun RequestRow(r: ShelfarrRequest, library: List<Book>, onOpen: () -> Unit, onDelete: () -> Unit) {
    // Your library's cover when the book is there: most requests' ids have no Open Library cover.
    val mine = remember(r.id, library) { Shelfarr.matching(library, r.title, r.author) }
    Row(Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(start = 16.dp, end = 4.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Cover(mine, r.coverUrl, 60.dp)
        Column(Modifier.weight(1f).padding(horizontal = 14.dp)) {
            Text(r.title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, maxLines = 2, overflow = TextOverflow.Ellipsis)
            r.author?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1) }
            r.issue?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Color(0xFFF59E0B), maxLines = 2) }
            if (r.bookType == "ebook") Text("Ebook", style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        StatusBadge(r)
        IconButton(onClick = onDelete) { Icon(Icons.Default.Delete, "Delete request", tint = MaterialTheme.colorScheme.onSurfaceVariant) }
    }
}

@Composable
private fun DeleteDialog(r: ShelfarrRequest, onDone: () -> Unit, onDeleted: () -> Unit = {}) {
    val scope = rememberCoroutineScope()
    AlertDialog(
        onDismissRequest = onDone,
        title = { Text("Delete this request?") },
        text = { Text("${r.title} will be removed from Shelfarr. Files in your library are kept.") },
        confirmButton = {
            TextButton(onClick = {
                onDone()
                scope.launch {
                    runCatching { Shelfarr.delete(r) }
                        .onSuccess { Snackbars.show("Request deleted"); onDeleted() }
                        .onFailure { Snackbars.show(it.message ?: "Couldn't delete it") }
                }
            }) { Text("Delete request", color = MaterialTheme.colorScheme.error) }
        },
        dismissButton = { TextButton(onClick = onDone) { Text("Cancel") } },
    )
}

// MARK: one request

/** One request: the book (from your library when it's there, else Open Library) and the request itself. */
@Composable
fun ShelfarrRequestScreen(id: Int, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    val requests by Shelfarr.requests.collectAsState()
    val r = requests.firstOrNull { it.id == id }
    val library = rememberLibrary()
    val book = remember(r?.id, library) { r?.let { Shelfarr.matching(library, it.title, it.author) } }
    var info by remember { mutableStateOf<ShelfarrBookInfo?>(null) }
    var confirmDelete by remember { mutableStateOf(false) }
    var expanded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) { runCatching { Shelfarr.refresh() } }
    LaunchedEffect(r?.id, book?.id) {
        if (r != null && book?.description.isNullOrBlank()) info = Shelfarr.bookInfo(r)
    }
    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Request", onBack)
        if (r == null) { Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { KitziLoading() }; return@Column }
        val about = book?.description?.takeIf { it.isNotBlank() }?.let(::decodeHtml) ?: info?.description
        val subjects = book?.genres?.takeIf { it.isNotEmpty() } ?: info?.subjects.orEmpty()
        val published = book?.publishYear?.toString() ?: info?.firstPublished
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp).padding(bottom = 16.dp + LocalMiniPlayerInset.current),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Cover(book, info?.coverUrl ?: r.coverUrl, 180.dp)
                Text(r.title, style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center)
                r.author?.let { Text(it, color = MaterialTheme.colorScheme.onSurfaceVariant) }
                StatusBadge(r)
            }
            book?.let { b ->
                Button(onClick = { nav.openBook(b.id) }, modifier = Modifier.fillMaxWidth()) {
                    Icon(Icons.AutoMirrored.Filled.LibraryBooks, null)
                    Text("Open in Library", modifier = Modifier.padding(start = 8.dp))
                }
            }
            about?.takeIf { it.isNotBlank() }?.let { text ->
                Card {
                    Text("About", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(text, style = MaterialTheme.typography.bodyMedium, maxLines = if (expanded) Int.MAX_VALUE else 6,
                        overflow = TextOverflow.Ellipsis, modifier = Modifier.clickable { expanded = !expanded })
                }
            }
            Card {
                Text("Request", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                Line("Status", r.statusLabel)
                r.issue?.let { Text(it, color = Color(0xFFF59E0B), style = MaterialTheme.typography.bodyMedium) }
                Line("Type", if (r.bookType == "ebook") "Ebook" else "Audiobook")
                r.createdMs?.let { Line("Requested", date(it)) }
                r.updatedMs?.let { Line("Last updated", date(it)) }
                r.requestedBy?.let { Line("Requested by", it) }
                r.source?.let { Line("Requested from", it) }
                if (r.statusDetail.isNotEmpty()) Text(r.statusDetail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            if (book != null || published != null || subjects.isNotEmpty()) {
                Card {
                    Text("Book", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    book?.narrators?.takeIf { it.isNotEmpty() }?.let { Line("Narrator", it.joinToString(", ")) }
                    book?.durationMs?.let { Line("Length", formatHm(it / 1000)) }
                    published?.let { Line("Published", it) }
                    book?.publisher?.let { Line("Publisher", it) }
                    if (subjects.isNotEmpty()) Line("Subjects", subjects.joinToString(", "))
                }
            }
            OutlinedButton(onClick = { confirmDelete = true }, modifier = Modifier.fillMaxWidth()) {
                Text("Delete request", color = MaterialTheme.colorScheme.error)
            }
        }
        if (confirmDelete) DeleteDialog(r, onDone = { confirmDelete = false }, onDeleted = onBack)
    }
}

@Composable
private fun Line(label: String, value: String) {
    Row {
        Text(label, color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.width(120.dp))
        Text(value, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
    }
}

private fun date(ms: Long): String = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date(ms))

// MARK: Send to Shelfarr (on an Audible book's page)

/**
 * On an Audible book's page, when Shelfarr is set up and the book isn't in the
 * library: Send to Shelfarr (or the request's status, once there's one).
 */
@Composable
fun SendToShelfarr(title: String, author: String?) {
    if (!Shelfarr.configured) return
    val requests by Shelfarr.requests.collectAsState()
    var busy by remember { mutableStateOf(false) }
    var matches by remember { mutableStateOf<List<ShelfarrBook>?>(null) }
    val scope = rememberCoroutineScope()
    LaunchedEffect(Unit) { runCatching { Shelfarr.refresh() } }
    val norm = remember(title) { com.bennybar.kitzi.data.audible.AudibleMatch.norm(title) }
    val existing = requests.firstOrNull { com.bennybar.kitzi.data.audible.AudibleMatch.similar(com.bennybar.kitzi.data.audible.AudibleMatch.norm(it.title), norm) }
    if (existing != null) {
        Text("Requested on Shelfarr · ${existing.statusLabel}", color = MaterialTheme.colorScheme.onSurfaceVariant, style = MaterialTheme.typography.bodyMedium)
        return
    }
    Button(
        enabled = !busy,
        modifier = Modifier.fillMaxWidth(),
        onClick = {
            scope.launch {
                busy = true
                val t = com.bennybar.kitzi.data.audible.AudibleMatch.titleVariants(title).firstOrNull() ?: title
                runCatching {
                    var found = Shelfarr.search(listOfNotNull(t, author).joinToString(" "))
                    if (found.isEmpty() && author != null) found = Shelfarr.search(t)
                    found
                }.onSuccess { found ->
                    if (found.isEmpty()) Snackbars.show("Shelfarr didn't find $title")
                    else {
                        // The likeliest first: same title, then same author.
                        val nt = com.bennybar.kitzi.data.audible.AudibleMatch.norm(t)
                        val na = author?.let(com.bennybar.kitzi.data.audible.AudibleMatch::norm)
                        fun score(m: ShelfarrBook): Int {
                            var s = if (com.bennybar.kitzi.data.audible.AudibleMatch.similar(com.bennybar.kitzi.data.audible.AudibleMatch.norm(m.title), nt)) 2 else 0
                            val ma = m.author?.let(com.bennybar.kitzi.data.audible.AudibleMatch::norm)
                            if (na != null && ma != null && (ma.contains(na) || na.contains(ma))) s += 1
                            return s
                        }
                        matches = found.sortedByDescending(::score)
                    }
                }.onFailure { Snackbars.show(it.message ?: "Couldn't reach Shelfarr") }
                busy = false
            }
        },
    ) {
        if (busy) KitziLoading(Modifier.size(22.dp), color = androidx.compose.material3.LocalContentColor.current)
        else Icon(Icons.Default.Inbox, null)
        Text("Send to Shelfarr", modifier = Modifier.padding(start = 8.dp))
    }
    matches?.let { list ->
        AlertDialog(
            onDismissRequest = { matches = null },
            title = { Text("Which book should Shelfarr get?") },
            text = {
                Column {
                    Text("Shelfarr will search for the audiobook and download it to your library.", style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.padding(bottom = 8.dp))
                    list.take(6).forEach { m ->
                        Text(
                            listOfNotNull(m.title, m.author, m.year?.toString()).joinToString(" · "),
                            style = MaterialTheme.typography.bodyLarge,
                            color = MaterialTheme.colorScheme.primary,
                            modifier = Modifier.fillMaxWidth().clickable {
                                matches = null
                                scope.launch {
                                    runCatching { Shelfarr.request(m) }
                                        .onSuccess { Snackbars.show("Sent ${m.title} to Shelfarr") }
                                        .onFailure { Snackbars.show(it.message ?: "Couldn't request it") }
                                }
                            }.padding(vertical = 10.dp),
                        )
                    }
                }
            },
            confirmButton = {},
            dismissButton = { TextButton(onClick = { matches = null }) { Text("Cancel") } },
        )
    }
}

// MARK: settings

@Composable
private fun Field(value: String, onChange: (String) -> Unit, label: String, password: Boolean = false, url: Boolean = false) {
    OutlinedTextField(
        value, onChange, label = { Text(label) }, singleLine = true,
        visualTransformation = if (password) PasswordVisualTransformation() else androidx.compose.ui.text.input.VisualTransformation.None,
        keyboardOptions = KeyboardOptions(
            keyboardType = when { password -> KeyboardType.Password; url -> KeyboardType.Uri; else -> KeyboardType.Text },
            autoCorrectEnabled = false, imeAction = ImeAction.Next,
        ),
        modifier = Modifier.fillMaxWidth(),
    )
}

@Composable
private fun ToggleLine(title: String, subtitle: String?, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
        Column(Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyLarge)
            subtitle?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }
        }
        Switch(checked, onChange)
    }
}

/** Connect to a Shelfarr server, and show or hide its tab. */
@Composable
fun ShelfarrSettingsScreen(onBack: () -> Unit) {
    var url by remember { mutableStateOf(Shelfarr.baseUrl.orEmpty()) }
    var token by remember { mutableStateOf(Shelfarr.token.orEmpty()) }
    var username by remember { mutableStateOf(Shelfarr.username.orEmpty()) }
    var password by remember { mutableStateOf(Shelfarr.password.orEmpty()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var connected by remember { mutableStateOf(false) }
    var configured by remember { mutableStateOf(Shelfarr.configured) }
    val showTab by UiPrefsState.showShelfarrTab
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Shelfarr", onBack)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp).padding(bottom = LocalMiniPlayerInset.current), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Field(url, { url = it }, "Server URL", url = true)
            Field(token, { token = it }, "API token", password = true)
            Note("In Shelfarr, open Profile → API tokens and create a token with search:read, requests:read and requests:write.")
            Text("To delete requests", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            Field(username, { username = it }, "Username")
            Field(password, { password = it }, "Password", password = true)
            Note("Optional. Shelfarr's API can't delete requests, so Kitzi signs in to its website for that. Kept encrypted on this device. Doesn't work with two-factor sign-in.")
            ConnectButton(busy, connected, enabled = url.isNotBlank() && token.isNotBlank()) {
                scope.launch {
                    busy = true; error = null; connected = false
                    runCatching { Shelfarr.connect(url, token, username, password) }
                        .onSuccess { connected = true; configured = true; UiPrefsState.set(Services.prefs, UiPrefsState.K_SHELFARR_TAB, true) }
                        .onFailure { error = it.message }
                    busy = false
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (configured) {
                HorizontalDivider()
                ToggleLine("Shelfarr tab", null, showTab) { UiPrefsState.set(Services.prefs, UiPrefsState.K_SHELFARR_TAB, it) }
                TextButton(onClick = {
                    Shelfarr.clear()
                    UiPrefsState.set(Services.prefs, UiPrefsState.K_SHELFARR_TAB, false)
                    url = ""; token = ""; username = ""; password = ""; connected = false; configured = false
                }) { Text("Disconnect", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
}

/** Connect to an Achew server, and show or hide its action on book pages. */
@Composable
fun AchewSettingsScreen(onBack: () -> Unit) {
    var url by remember { mutableStateOf(Achew.baseUrl.orEmpty()) }
    var username by remember { mutableStateOf(Achew.username.orEmpty()) }
    var password by remember { mutableStateOf(Achew.password.orEmpty()) }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    var connected by remember { mutableStateOf(false) }
    var configured by remember { mutableStateOf(Achew.configured) }
    val enabled by UiPrefsState.achewEnabled
    val scope = rememberCoroutineScope()
    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Achew", onBack)
        Column(Modifier.verticalScroll(rememberScrollState()).padding(16.dp).padding(bottom = LocalMiniPlayerInset.current), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Field(url, { url = it }, "Server URL", url = true)
            Field(username, { username = it }, "Username")
            Field(password, { password = it }, "Password", password = true)
            Note("Achew repairs a book's chapters on Audiobookshelf. Leave the username and password empty if your server doesn't ask for them. They're kept encrypted on this device.")
            ConnectButton(busy, connected, enabled = url.isNotBlank()) {
                scope.launch {
                    busy = true; error = null; connected = false
                    runCatching { Achew.connect(url, username, password) }
                        .onSuccess { connected = true; configured = true; UiPrefsState.set(Services.prefs, UiPrefsState.K_ACHEW, true) }
                        .onFailure { error = it.message }
                    busy = false
                }
            }
            error?.let { Text(it, color = MaterialTheme.colorScheme.error) }
            if (configured) {
                HorizontalDivider()
                ToggleLine("Fix Chapters on book pages", "Adds it to the ⋮ menu on each book", enabled) {
                    UiPrefsState.set(Services.prefs, UiPrefsState.K_ACHEW, it)
                }
                TextButton(onClick = {
                    Achew.clear()
                    UiPrefsState.set(Services.prefs, UiPrefsState.K_ACHEW, false)
                    url = ""; username = ""; password = ""; connected = false; configured = false
                }) { Text("Disconnect", color = MaterialTheme.colorScheme.error) }
            }
        }
    }
}

@Composable
private fun Note(text: String) = Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)

@Composable
private fun ConnectButton(busy: Boolean, connected: Boolean, enabled: Boolean, onClick: () -> Unit) {
    Button(onClick = onClick, enabled = enabled && !busy, modifier = Modifier.fillMaxWidth()) {
        when {
            busy -> KitziLoading(Modifier.size(22.dp), color = androidx.compose.material3.LocalContentColor.current)
            connected -> Icon(Icons.Default.CheckCircle, null)
        }
        Text("Connect", modifier = Modifier.padding(start = 8.dp))
    }
}

// MARK: Achew's website

/** Achew's website, already signed in (only for Achew's own address). */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun AchewWebScreen(onBack: () -> Unit) {
    var loading by remember { mutableStateOf(true) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(Modifier.fillMaxSize()) {
        AudibleTopBar("Achew", onBack)
        Box(Modifier.fillMaxSize().padding(bottom = LocalMiniPlayerInset.current)) {
            AndroidView(
                factory = { ctx ->
                    WebView(ctx).apply {
                        settings.javaScriptEnabled = true
                        settings.domStorageEnabled = true
                        webViewClient = object : WebViewClient() {
                            private var tries = 0
                            override fun onReceivedHttpAuthRequest(view: WebView, handler: HttpAuthHandler, host: String, realm: String?) {
                                val achewHost = Achew.baseUrl?.let { runCatching { java.net.URI(it).host }.getOrNull() }
                                val u = Achew.username; val p = Achew.password
                                if (host != achewHost || u == null || p == null) { handler.cancel(); return }
                                // A rejected login isn't retried: a wrong password shows an error instead of looping.
                                if (tries++ > 0) {
                                    error = "Achew rejected the saved username or password. Check them in Settings."
                                    handler.cancel(); return
                                }
                                handler.proceed(u, p)
                            }
                            override fun onPageFinished(view: WebView?, url: String?) { loading = false }
                            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, err: WebResourceError?) {
                                if (request?.isForMainFrame == true) { loading = false; error = err?.description?.toString() ?: "Couldn't open Achew." }
                            }
                        }
                        Achew.baseUrl?.let { loadUrl(it) }
                    }
                },
                onRelease = { it.destroy() },
                modifier = Modifier.fillMaxSize(),
            )
            when {
                error != null -> Column(Modifier.fillMaxSize().background(MaterialTheme.colorScheme.surface).padding(32.dp),
                    horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.Center) {
                    Icon(Icons.Default.Warning, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text("Couldn't open Achew", style = MaterialTheme.typography.titleMedium, modifier = Modifier.padding(top = 8.dp))
                    Text(error!!, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
                }
                loading -> KitziLoading(Modifier.align(Alignment.Center))
            }
        }
    }
}
