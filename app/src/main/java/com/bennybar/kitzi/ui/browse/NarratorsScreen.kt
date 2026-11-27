package com.bennybar.kitzi.ui.browse

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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsNone
import androidx.compose.material.icons.filled.TravelExplore
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.model.Book
import com.bennybar.kitzi.ui.audible.AudibleListRoute
import com.bennybar.kitzi.ui.audible.LocalKitziNav
import com.bennybar.kitzi.ui.common.KitziSearchField
import com.bennybar.kitzi.ui.common.ScreenHeader
import com.bennybar.kitzi.ui.common.Snackbars
import com.bennybar.kitzi.ui.library.BookCard

/** The library's narrators, most books first; each opens the books they read. */
@Composable
fun NarratorsScreen(onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var narrators by remember { mutableStateOf<List<Pair<String, Int>>?>(null) }
    var search by remember { mutableStateOf("") }
    LaunchedEffect(Unit) { narrators = Services.books.narrators() }

    val all = narrators
    val shown = all.orEmpty().filter { it.first.contains(search.trim(), ignoreCase = true) }
    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.Mic, title = "Narrators", onBack = onBack)
        KitziSearchField(search, { search = it }, "Search narrators", Modifier.padding(bottom = 8.dp))
        when {
            all == null -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                com.bennybar.kitzi.ui.common.KitziLoading()
            }
            shown.isEmpty() -> BrowseEmptyState(
                icon = Icons.Default.Mic,
                title = if (all.isEmpty()) "No narrators yet" else "No matches",
                message = if (all.isEmpty()) "Narrators appear once your library has synced." else "Try a different name.",
            )
            else -> LazyColumn(
                contentPadding = PaddingValues(
                    start = 16.dp, top = 16.dp, end = 16.dp,
                    bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
                ),
                verticalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                items(shown, key = { it.first }) { (name, count) ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainer,
                        shape = RoundedCornerShape(18.dp),
                        modifier = Modifier.fillMaxWidth().clickable { nav.openNarrator(name) },
                    ) {
                        Row(Modifier.padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                name,
                                style = MaterialTheme.typography.titleMedium,
                                fontWeight = FontWeight.SemiBold,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f),
                            )
                            Text("$count", style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            Icon(Icons.AutoMirrored.Filled.KeyboardArrowRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
        }
    }
}

/** A narrator's books in the library, and theirs on Audible; the bell follows them. */
@Composable
fun NarratorScreen(name: String, onBack: () -> Unit) {
    val nav = LocalKitziNav.current
    var books by remember(name) { mutableStateOf<List<Book>?>(null) }
    // Followed narrators, for New Releases.
    var following by remember(name) { mutableStateOf(name in Services.prefs.getStringSet(KEY_FOLLOWED)) }
    val progress by remember { Services.books.watchProgress() }.collectAsStateWithLifecycle(emptyMap())
    LaunchedEffect(name) { books = Services.books.booksByNarrator(name) }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(
            icon = Icons.Default.Mic,
            title = name,
            subtitle = books?.let { "${it.size} in Your Library" },
            onBack = onBack,
            trailing = {
                IconButton(onClick = {
                    val set = Services.prefs.getStringSet(KEY_FOLLOWED)
                    following = !following
                    Services.prefs.putStringSet(KEY_FOLLOWED, if (following) set + name else set - name)
                    if (following) Snackbars.show(
                        if (Services.prefs.getBoolean(com.bennybar.kitzi.data.Radar.KEY_ON, false)) "Following $name: new books show in New Releases"
                        else "Following $name. Turn on New Releases in Settings to be notified"
                    )
                }) {
                    Icon(
                        if (following) Icons.Default.Notifications else Icons.Default.NotificationsNone,
                        if (following) "Following" else "Follow",
                        tint = if (following) MaterialTheme.colorScheme.primary else MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            },
        )
        LazyColumn(
            contentPadding = PaddingValues(
                start = 16.dp, top = 8.dp, end = 16.dp,
                bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current,
            ),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            items(books.orEmpty(), key = { it.id }) { b ->
                BookCard(b, progress = progress[b.id]) { nav.openBook(b.id) }
            }
            item {
                Row(
                    Modifier.fillMaxWidth().clickable { nav.openList(AudibleListRoute.Narrator(name)) }.padding(vertical = 14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.TravelExplore, null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                    Text(
                        "More Narrated by $name on Audible",
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.primary,
                        modifier = Modifier.weight(1f).padding(start = 12.dp),
                    )
                }
            }
        }
    }
}

private const val KEY_FOLLOWED = com.bennybar.kitzi.data.Radar.KEY_NARRATORS
